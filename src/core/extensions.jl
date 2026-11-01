abstract type AbstractEventListener end
abstract type AbstractToolEntry end
abstract type AbstractToolGuard end

struct ToolSpec{S,F,O,P,R,A}
    name::Symbol
    schema::S
    call::F
    description::String
    output_schema::O
    concurrency_policy::P
    output_renderer::R
    activation::A
end

"""Describe a tool independently of its executor, provider schema, or presentation protocol."""
ToolSpec(name, schema, callback; description="", output_schema=nothing, concurrency_safe=false,
        render_output=nothing, when=nothing) =
    ToolSpec(Symbol(name), schema, callback, String(description), output_schema, concurrency_safe, render_output, when)
ToolSpec(name::Symbol, schema, callback, description::AbstractString) =
    ToolSpec(name, schema, callback, String(description), nothing, false, nothing, nothing)
ToolSpec(name::Symbol, schema, callback, description::String, output_schema) =
    ToolSpec(name, schema, callback, description, output_schema, false, nothing, nothing)
ToolSpec(name::Symbol, schema, callback, description::String, output_schema, concurrency_policy) =
    ToolSpec(name, schema, callback, description, output_schema, concurrency_policy, nothing, nothing)
ToolSpec(name::Symbol, schema, callback, description::String, output_schema, concurrency_policy, renderer) =
    ToolSpec(name, schema, callback, description, output_schema, concurrency_policy, renderer, nothing)
ToolSpec(name, callback; schema=(type="object",), description="", output_schema=nothing, concurrency_safe=false, render_output=nothing) =
    ToolSpec(name, schema, callback; description, output_schema, concurrency_safe, render_output)
ToolSpec(callback::Function, name::Union{Symbol,AbstractString}, schema; kwargs...) = ToolSpec(name, schema, callback; kwargs...)
ToolSpec(callback::Function, name::Union{Symbol,AbstractString}; kwargs...) = ToolSpec(name, callback; kwargs...)

"""A tool declares parallel safety explicitly; plugins can dispatch on their policy type."""
tool_concurrency_safe(policy::Bool, arguments) = policy
tool_concurrency_safe(policy, arguments) = Base.invokelatest(policy, arguments)
tool_concurrency_safe(spec::ToolSpec, arguments) =
    tool_concurrency_safe(spec.concurrency_policy, arguments)

"""Approval requests are values returned by tool guards; the authority remains a replaceable Julia service."""
abstract type AbstractToolApprovalRequest end

struct ToolApprovalRequest <: AbstractToolApprovalRequest
    reason::Union{Nothing,String}
end

ToolApprovalRequest() = ToolApprovalRequest(nothing)

struct ToolRestriction
    allow::Union{Nothing,Set{Symbol}}
    deny::Union{Nothing,Set{Symbol}}
end

mutable struct ExtensionScope
    parent::Union{Nothing,ExtensionScope}
    lock::ReentrantLock
    children::Vector{ExtensionScope}
    listeners::Dict{Symbol,Vector{AbstractEventListener}}
    tools::Dict{Symbol,AbstractToolEntry}
    tool_order::Vector{Symbol}
    restrictions::Vector{ToolRestriction}
    guards::Vector{AbstractToolGuard}
    resources::Vector{ResourceRegistration}
    users::Int
    closed::Bool
end

"""Create an independently disposable lexical scope for extension registrations."""
function ExtensionScope(parent::Union{Nothing,ExtensionScope}=nothing)
    scope = ExtensionScope(parent, isnothing(parent) ? ReentrantLock() : parent.lock,
        ExtensionScope[], Dict{Symbol,Vector{AbstractEventListener}}(), Dict{Symbol,AbstractToolEntry}(),
        Symbol[], ToolRestriction[], AbstractToolGuard[], ResourceRegistration[], 0, false)
    if !isnothing(parent)
        lock(parent.lock) do
            if !isopen(parent)
                scope.closed = true
            else
                push!(parent.children, scope)
            end
        end
    end
    return scope
end

function extension_root(scope::ExtensionScope)
    parent = scope.parent
    return isnothing(parent) ? scope : extension_root(parent)
end
function extension_chain(scope::ExtensionScope)
    chain = ExtensionScope[]
    current = scope
    while !isnothing(current)
        push!(chain, current)
        current = current.parent
    end
    return chain
end
function Base.isopen(scope::ExtensionScope)
    return lock(scope.lock) do
        current = scope
        while !isnothing(current)
            current.closed && return false
            current = current.parent
        end
        return true
    end
end

function scope_admits(scope::ExtensionScope, listener_scope::ExtensionScope)
    isnothing(listener_scope.parent) && return true
    current = scope
    while !isnothing(current)
        current === listener_scope && return true
        current = current.parent
    end
    return false
end

"""Own a scope registration or resource through its disposal and outstanding callback uses."""
function own_resource!(scope::ExtensionScope, value; cleanup=close)
    owned = Ref{ResourceRegistration}()
    registration = ResourceRegistration(value, value -> begin
        lock(scope.lock) do
            filter!(resource -> resource !== owned[], scope.resources)
        end
        event_value(Base.invokelatest(cleanup, value))
    end)
    owned[] = registration
    accepted = lock(scope.lock) do
        if !isopen(scope)
            false
        else
            push!(scope.resources, registration)
            true
        end
    end
    accepted || release!(registration)
    return registration
end

function extension_resources!(scope::ExtensionScope)
    if scope.closed && scope.users == 0
        resources = reverse(copy(scope.resources))
        empty!(scope.resources)
        return resources
    end
    return ResourceRegistration[]
end

function dispose_extension_resources!(resources)
    failures = Task[]
    for registration in resources
        worker = spawn_cleanup(() -> release!(registration))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

"""Retire a scope and its descendants; running callbacks retain their resources until completion."""
function Base.close(scope::ExtensionScope)
    retired = lock(scope.lock) do
        scope.closed = true
        children = reverse(copy(scope.children))
        empty!(scope.children)
        if !isnothing(scope.parent)
            filter!(child -> child !== scope, scope.parent.children)
        end
        (children, resources=extension_resources!(scope))
    end
    # Empty scopes are common during streaming. No children or owned resources
    # means there is nothing for a cleanup task to execute.
    isempty(retired.children) && isempty(retired.resources) && return nothing
    failures = Task[]
    for child in retired.children
        worker = spawn_cleanup(() -> close(child))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    if !isempty(retired.resources)
        worker = spawn_cleanup(() -> dispose_extension_resources!(retired.resources))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

mutable struct EventListener{F,O} <: AbstractEventListener
    scope::ExtensionScope
    name::Symbol
    callback::F
    owner::O
    registration::Union{Nothing,ResourceRegistration}
    global_listener::Bool
    once::Bool
    claimed::Bool
    active::Bool
end

function remove_listener!(root::ExtensionScope, name::Symbol, listener::EventListener)
    lock(root.lock) do
        listener.active = false
        listeners = get(root.listeners, name, nothing)
        if !isnothing(listeners)
            filter!(entry -> entry !== listener, listeners)
            isempty(listeners) && delete!(root.listeners, name)
        end
    end
    return nothing
end

"""Register a scoped listener with reversible ownership, optional priority, and optional single use."""
function on!(callback, scope::ExtensionScope, name::Symbol;
        prepend=false, global_listener=false, once=false, owner=nothing)
    root = extension_root(scope)
    listener = EventListener(scope, name, callback, owner, nothing, global_listener, once, false, true)
    registration = own_resource!(scope, listener; cleanup=entry -> remove_listener!(root, name, entry))
    listener.registration = registration
    lock(root.lock) do
        if isopen(scope)
            listeners = get!(Vector{AbstractEventListener}, root.listeners, name)
            prepend ? pushfirst!(listeners, listener) : push!(listeners, listener)
        end
    end
    isnothing(owner) || own_resource!(owner, registration; cleanup=release!)
    return registration
end

mutable struct EventInvocation{L,R}
    listener::L
    retention::R
    scopes::Vector{ExtensionScope}
    pending::Union{Nothing,Task}
end

function event_invocations(scope::ExtensionScope, name::Symbol)
    root = extension_root(scope)
    return lock(root.lock) do
        invocations = EventInvocation[]
        for listener in get(root.listeners, name, AbstractEventListener[])
            listener.active && isopen(listener.scope) || continue
            listener.global_listener || scope_admits(scope, listener.scope) || continue
            retention = isnothing(listener.owner) ? nothing : acquire_plugin!(listener.owner)
            !isnothing(listener.owner) && isnothing(retention) && continue
            scopes = ExtensionScope[]
            current = listener.scope
            while !isnothing(current)
                current.users += 1
                push!(scopes, current)
                current = current.parent
            end
            push!(invocations, EventInvocation(listener, retention, scopes, nothing))
        end
        return invocations
    end
end

function release!(invocation::EventInvocation)
    pending = invocation.pending
    while !isnothing(pending) && istaskdone(pending)
        value = istaskfailed(pending) ? nothing : fetch(pending)
        pending = value isa Task ? value : nothing
    end
    invocation.pending = pending
    if !isnothing(pending)
        spawn_scoped() do
            wait(pending; throw=false)
            value = istaskfailed(pending) ? nothing : fetch(pending)
            invocation.pending = value isa Task ? value : nothing
            release!(invocation)
        end
        return nothing
    end
    scope = invocation.listener.scope
    resources = lock(scope.lock) do
        pending = ResourceRegistration[]
        for retained in invocation.scopes
            retained.users -= 1
            append!(pending, extension_resources!(retained))
        end
        empty!(invocation.scopes)
        pending
    end
    isempty(resources) && isnothing(invocation.retention) && return nothing
    failures = Task[]
    if !isempty(resources)
        worker = spawn_cleanup(() -> dispose_extension_resources!(resources))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    if !isnothing(invocation.retention)
        worker = spawn_cleanup(() -> release!(invocation.retention))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

function claim_listener!(listener::EventListener)
    return lock(listener.scope.lock) do
        if listener.once
            listener.claimed && return false
            listener.claimed = true
            listener.active = false
            isnothing(listener.registration) || release!(listener.registration)
        end
        return true
    end
end

event_value(value) = value
event_value(value::Task) = event_value(fetch(value))
event_bailed(value) = value !== nothing && value !== false

function invoke_listener(invocation::EventInvocation, arguments; awaited=false)
    listener = invocation.listener
    claim_listener!(listener) || return nothing
    value = Base.invokelatest(listener.callback, arguments...)
    value isa Task && (invocation.pending = value)
    return awaited ? event_value(value) : value
end

function dispatch_listeners(::Val{:emit}, invocations, arguments)
    for invocation in invocations
        invoke_listener(invocation, arguments)
    end
    return nothing
end

function dispatch_listeners(::Val{:bail}, invocations, arguments)
    for invocation in invocations
        value = invoke_listener(invocation, arguments)
        event_bailed(value) && return value
    end
    return nothing
end

function dispatch_listeners(::Val{:serial}, invocations, arguments)
    for invocation in invocations
        value = invoke_listener(invocation, arguments; awaited=true)
        event_bailed(value) && return value
    end
    return nothing
end

function dispatch_listeners(::Val{:parallel}, invocations, arguments)
    workers = Task[]
    for invocation in invocations
        worker = @async event_value(invoke_listener(invocation, arguments))
        push!(workers, worker)
    end
    foreach(worker -> wait(worker; throw=false), workers)
    failed = findfirst(istaskfailed, workers)
    isnothing(failed) || fetch(workers[failed])
    return nothing
end

function event_waterfall(invocations, index, arguments, inner)
    index > length(invocations) && return Base.invokelatest(inner)
    invocation = invocations[index]
    claim_listener!(invocation.listener) || return event_waterfall(invocations, index + 1, arguments, inner)
    called = Threads.Atomic{Bool}(false)
    next = () -> begin
        Threads.atomic_xchg!(called, true) && error("next() called multiple times")
        event_waterfall(invocations, index + 1, arguments, inner)
    end
    value = Base.invokelatest(invocation.listener.callback, arguments..., next)
    if value isa Task
        lock(invocation.listener.scope.lock) do
            invocation.pending = value
        end
    end
    return value
end

dispatch_listeners(::Val{:waterfall}, invocations, arguments) =
    event_waterfall(invocations, 1, Base.front(arguments), last(arguments))

function release_event_invocations!(invocations)
    failures = Task[]
    for invocation in reverse(invocations)
        release_worker = spawn_cleanup(() -> release!(invocation))
        wait(release_worker; throw=false)
        istaskfailed(release_worker) && push!(failures, release_worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

function waterfall_tasks(invocations)
    tasks = Task[]
    for invocation in invocations
        pending = lock(() -> invocation.pending, invocation.listener.scope.lock)
        isnothing(pending) || push!(tasks, pending)
    end
    return tasks
end

function settle_waterfall!(invocations, returned)
    pending = Task[]
    seen = IdDict{Task,Nothing}()
    returned isa Task && push!(pending, returned)
    while true
        append!(pending, waterfall_tasks(invocations))
        filter!(task -> !haskey(seen, task), pending)
        isempty(pending) && return nothing
        worker = popfirst!(pending)
        seen[worker] = nothing
        wait(worker; throw=false)
        if !istaskfailed(worker)
            value = fetch(worker)
            value isa Task && push!(pending, value)
        end
    end
end

function release_waterfall!(invocations, returned)
    if returned isa Task || !isempty(waterfall_tasks(invocations))
        spawn_scoped() do
            settle_waterfall!(invocations, returned)
            release_event_invocations!(invocations)
        end
    else
        release_event_invocations!(invocations)
    end
    return nothing
end

"""Dispatch scoped callbacks with synchronous, bail, serial, parallel, or continuation composition."""
function dispatch_event!(scope::ExtensionScope, name::Symbol, arguments...; mode::Symbol=:emit)
    invocations = event_invocations(scope, name)
    # The empty dispatch is common during streaming and needs no worker or cleanup.
    # Preserve waterfall's terminal continuation and unsupported mode errors.
    if isempty(invocations) && mode in (:emit, :bail, :serial, :parallel)
        return nothing
    end
    worker = spawn_scoped(() -> dispatch_listeners(Val(mode), invocations, arguments))
    wait(worker; throw=false)
    cleanup = spawn_cleanup() do
        if mode === :waterfall
            returned = istaskfailed(worker) ? nothing : fetch(worker)
            release_waterfall!(invocations, returned)
        else
            release_event_invocations!(invocations)
        end
        nothing
    end
    wait(cleanup; throw=false)
    istaskfailed(worker) && return fetch(worker)
    fetch(cleanup)
    return fetch(worker)
end

mutable struct ToolEntry{T,O,F} <: AbstractToolEntry
    scope::ExtensionScope
    spec::T
    owner::O
    cleanup::F
    active::Bool
    users::Int
    cleaned::Bool
end

function retire_tool!(entry::ToolEntry)
    scope = entry.scope
    clean = lock(scope.lock) do
        entry.active = false
        if get(scope.tools, entry.spec.name, nothing) === entry
            delete!(scope.tools, entry.spec.name)
            filter!(!=(entry.spec.name), scope.tool_order)
        end
        if entry.users == 0 && !entry.cleaned
            entry.cleaned = true
            true
        else
            false
        end
    end
    clean && event_value(Base.invokelatest(entry.cleanup, entry.spec))
    return nothing
end

"""Register a tool in one lexical layer; exact-entry disposal cannot remove a later replacement."""
function register_tool!(scope::ExtensionScope, spec::ToolSpec; owner=nothing, cleanup=Returns(nothing))
    entry = ToolEntry(scope, spec, owner, cleanup, true, 0, false)
    accepted = lock(scope.lock) do
        isopen(scope) || return (ok=false, reason="Extension scope is closed")
        haskey(scope.tools, spec.name) && return (ok=false, reason="Tool $(spec.name) is already registered in this scope")
        scope.tools[spec.name] = entry
        push!(scope.tool_order, spec.name)
        return (ok=true, reason="")
    end
    accepted.ok || return (ok=false, reason=accepted.reason, registration=nothing)
    registration = own_resource!(scope, entry; cleanup=retire_tool!)
    isnothing(owner) || own_resource!(owner, registration; cleanup=release!)
    return (ok=true, reason="", registration)
end

function overlay_tools!(names, entries, scope::ExtensionScope)
    isopen(scope) || return nothing
    for name in scope.tool_order
        entry = scope.tools[name]
        entry.active || continue
        !isnothing(entry.owner) && !plugin_available(entry.owner) && continue
        haskey(entries, name) || push!(names, name)
        entries[name] = entry
    end
    return nothing
end

function tool_admitted(scope::ExtensionScope, name::Symbol)
    isopen(scope) || return true
    return all(scope.restrictions) do restriction
        (isnothing(restriction.allow) || name in restriction.allow) &&
            (isnothing(restriction.deny) || !(name in restriction.deny))
    end
end

function tool_view(scope::ExtensionScope)
    isopen(scope) || return (names=Symbol[], entries=Dict{Symbol,AbstractToolEntry}(),
        restrictable=Set{Symbol}())
    chain = reverse(extension_chain(scope))
    inherited_names = Symbol[]
    inherited = Dict{Symbol,AbstractToolEntry}()
    for ancestor in chain[1:end-1]
        overlay_tools!(inherited_names, inherited, ancestor)
    end
    names = filter(name -> all(layer -> tool_admitted(layer, name), chain), inherited_names)
    entries = Dict{Symbol,AbstractToolEntry}(name => inherited[name] for name in names)
    overlay_tools!(names, entries, scope)
    return (names, entries, restrictable=Set(inherited_names))
end

"""Read a visible tool admission generation without assuming it remains registered."""
mutable struct ToolSet
    scope::ExtensionScope
    entries::Dict{Symbol,AbstractToolEntry}
    closed::Bool
end

"""Each activation decision sees one native scope, model selection and cancellation owner."""
struct ToolActivationContext{M,C}
    scope::ExtensionScope
    model_selection::M
    execution::C
end

"""Third-party policy objects may provide a specialized activation method."""
tool_activation(::Nothing, ::ToolActivationContext) = true
tool_activation(predicate, context::ToolActivationContext) = Base.invokelatest(predicate, context)

"""Invalidate an admitted set without changing global registrations."""
function Base.close(selection::ToolSet)
    lock(selection.scope.lock) do
        selection.closed = true
    end
    return nothing
end

"""Evaluate tool conditions once for one step without holding the registry lock."""
function resolve_tool_set(scope::ExtensionScope; model_selection=nothing, context=current_context())
    visible = lock(scope.lock) do
        isopen(scope) ? tool_view(scope) : nothing
    end
    isnothing(visible) && return (ok=false, reason="Tool scope is closed", tool_set=nothing)
    activation = ToolActivationContext(scope, model_selection, context)
    entries = Dict{Symbol,AbstractToolEntry}()
    for name in visible.names
        cancelled(context) && return (ok=false, reason="Tool selection was cancelled", tool_set=nothing)
        entry = visible.entries[name]
        worker = spawn_scoped(() -> event_value(tool_activation(entry.spec.activation, activation)))
        wait(worker; throw=false)
        cancelled(context) && return (ok=false, reason="Tool selection was cancelled", tool_set=nothing)
        istaskfailed(worker) &&
            return (ok=false, reason="Cannot resolve tool $(name) availability", tool_set=nothing)
        fetch(worker) === true && (entries[name] = entry)
    end
    cancelled(context) && return (ok=false, reason="Tool selection was cancelled", tool_set=nothing)
    return (ok=true, reason="", tool_set=ToolSet(scope, entries, false))
end

"""Restrict an admission to its original scope and still-live registration identities."""
function selected_tool_names(scope::ExtensionScope, visible, selection::ToolSet)
    selection.scope === scope && !selection.closed || return Symbol[]
    return filter(name -> get(selection.entries, name, nothing) === visible.entries[name], visible.names)
end
selected_tool_names(scope::ExtensionScope, visible, ::Nothing) = visible.names

"""Conditionally registered tools are never executable outside an explicitly admitted set."""
function admitted_tool_entry(scope::ExtensionScope, name::Symbol, ::Nothing)
    entry = visible_tool_entry(scope, name)
    return isnothing(entry) || !isnothing(entry.spec.activation) ? nothing : entry
end

function admitted_tool_entry(scope::ExtensionScope, name::Symbol, selection::ToolSet)
    selection.scope === scope && !selection.closed || return nothing
    entry = visible_tool_entry(scope, name)
    return !isnothing(entry) && get(selection.entries, name, nothing) === entry ? entry : nothing
end

"""Select a single visible tool without materializing the catalog used by snapshots.

The caller holds the scope lock. A local tool overrides inherited restrictions,
while an inherited match must satisfy restrictions from every visible layer.
"""
function visible_tool_entry(scope::ExtensionScope, name::Symbol)
    isopen(scope) || return nothing
    current = scope
    while !isnothing(current)
        entry = get(current.tools, name, nothing)
        if !isnothing(entry) && entry.active && isopen(current) &&
                (isnothing(entry.owner) || plugin_available(entry.owner))
            current === scope && return entry
            layer = scope
            while !isnothing(layer)
                tool_admitted(layer, name) || return nothing
                layer = layer.parent
            end
            return entry
        end
        current = current.parent
    end
    return nothing
end

"""Resolve a tool after nearest-scope shadowing and all inherited restrictions."""
function tool(scope::ExtensionScope, name::Symbol)
    return lock(scope.lock) do
        entry = visible_tool_entry(scope, name)
        isnothing(entry) ? nothing : entry.spec
    end
end

"""Copy the visible tool schema surface without exposing live executors or registration handles."""
function tools_snapshot(scope::ExtensionScope; tool_set=nothing)
    return lock(scope.lock) do
        view = tool_view(scope)
        return [(name=name, schema=deepcopy(tool_schema_definition(view.entries[name].spec.schema)),
            description=view.entries[name].spec.description) for name in selected_tool_names(scope, view, tool_set)]
    end
end

function remove_restriction!(scope::ExtensionScope, restriction::ToolRestriction)
    lock(scope.lock) do
        index = findfirst(item -> item === restriction, scope.restrictions)
        isnothing(index) || deleteat!(scope.restrictions, index)
    end
    return nothing
end

"""Intersect inherited tool visibility while preserving the viewing scope's own implementations."""
function restrict_tools!(scope::ExtensionScope; allow=nothing, deny=nothing, owner=nothing)
    isnothing(scope.parent) && return (ok=false, reason="Tool restrictions require a scoped context", registration=nothing)
    isnothing(allow) && isnothing(deny) && return (ok=false, reason="A tool restriction needs allow or deny", registration=nothing)
    restriction = ToolRestriction(isnothing(allow) ? nothing : Set(Symbol.(allow)),
        isnothing(deny) ? nothing : Set(Symbol.(deny)))
    accepted = lock(scope.lock) do
        isopen(scope) || return (ok=false, reason="Extension scope is closed")
        known = tool_view(scope).restrictable
        specified = union(isnothing(restriction.allow) ? Set{Symbol}() : restriction.allow,
            isnothing(restriction.deny) ? Set{Symbol}() : restriction.deny)
        unknown = setdiff(specified, known)
        isempty(unknown) || return (ok=false, reason="Unknown inherited tools: $(join(sort!(collect(unknown)), ", "))")
        push!(scope.restrictions, restriction)
        return (ok=true, reason="")
    end
    accepted.ok || return (ok=false, reason=accepted.reason, registration=nothing)
    registration = own_resource!(scope, restriction; cleanup=value -> remove_restriction!(scope, value))
    isnothing(owner) || own_resource!(owner, registration; cleanup=release!)
    return (ok=true, reason="", registration)
end


mutable struct ToolGuardEntry{F,O} <: AbstractToolGuard
    scope::ExtensionScope
    callback::F
    owner::O
    active::Bool
end

function retire_tool_guard!(entry::ToolGuardEntry)
    lock(entry.scope.lock) do
        entry.active = false
        filter!(guard -> guard !== entry, entry.scope.guards)
    end
    return nothing
end

"""Register a reversible, scope-inherited tool denial or approval policy owned by a plugin."""
function register_tool_guard!(scope::ExtensionScope, callback; owner=nothing)
    entry = ToolGuardEntry(scope, callback, owner, true)
    accepted = lock(scope.lock) do
        isopen(scope) || return false
        push!(scope.guards, entry)
        return true
    end
    accepted || return (ok=false, reason="Extension scope is closed", registration=nothing)
    registration = own_resource!(scope, entry; cleanup=retire_tool_guard!)
    isnothing(owner) || own_resource!(owner, registration; cleanup=release!)
    return (ok=true, reason="", registration)
end

"""Retain the exact guard generations and scopes while a tool call is being admitted."""
function acquire_tool_guards(scope::ExtensionScope)
    return lock(scope.lock) do
        invocations = EventInvocation[]
        for layer in reverse(extension_chain(scope)), guard in layer.guards
            guard.active && isopen(layer) || continue
            retention = isnothing(guard.owner) ? nothing : acquire_plugin!(guard.owner)
            !isnothing(guard.owner) && isnothing(retention) && continue
            scopes = extension_chain(layer)
            for retained in scopes
                retained.users += 1
            end
            push!(invocations, EventInvocation(guard, retention, scopes, nothing))
        end
        return invocations
    end
end

"""The approval protocol is independently replaceable by dispatch on the request type."""
tool_approval_reason(::AbstractToolApprovalRequest) = nothing
tool_approval_reason(request::ToolApprovalRequest) = request.reason

"""Resolve a request through Julia-owned scoped event listeners, never an external runtime."""
tool_approval_outcome(scope::ExtensionScope, call, request::AbstractToolApprovalRequest) =
    dispatch_event!(scope, :tool_approval, call, request; mode=:serial)

"""Fail closed for missing, rejected, cancelled, or unsupported approval outcomes."""
function tool_approval_denial(scope::ExtensionScope, call, request::AbstractToolApprovalRequest)
    outcome = Base.invokelatest(tool_approval_outcome, scope, call, request)
    outcome === :allowed_once && return nothing
    outcome === :rejected && return "the user rejected tool \"$(call.name)\""
    outcome === :cancelled && return "approval for tool \"$(call.name)\" was cancelled"
    outcome === :unavailable && return "tool \"$(call.name)\" requires approval, but no approval channel is available"
    if isnothing(outcome)
        reason = Base.invokelatest(tool_approval_reason, request)
        return isnothing(reason) ? "tool \"$(call.name)\" requires approval (not yet supported)" : String(reason)
    end
    return "Unsupported approval outcome for tool \"$(call.name)\""
end

"""Evaluate root-to-leaf tool guards; approval never grants an exemption from later guards."""
function first_tool_denial(invocations, call, scope::ExtensionScope)
    for invocation in invocations
        decision = Base.invokelatest(invocation.listener.callback, call)
        denial = decision isa AbstractToolApprovalRequest ?
            tool_approval_denial(scope, call, decision) : decision
        isnothing(denial) && continue
        return denial isa AbstractString ? String(denial) :
            "Tool guard must return a string, an approval request, or nothing"
    end
    return nothing
end

function acquire_tool!(scope::ExtensionScope, name::Symbol; tool_set=nothing)
    return lock(scope.lock) do
        entry = admitted_tool_entry(scope, name, tool_set)
        isnothing(entry) && return nothing
        retention = isnothing(entry.owner) ? nothing : acquire_plugin!(entry.owner)
        !isnothing(entry.owner) && isnothing(retention) && return nothing
        scopes = extension_chain(entry.scope)
        for retained in scopes
            retained.users += 1
        end
        entry.users += 1
        return EventInvocation(entry, retention, scopes, nothing)
    end
end

function release_tool!(invocation::EventInvocation)
    entry = invocation.listener
    lock(entry.scope.lock) do
        entry.users -= 1
    end
    failures = Task[]
    worker = spawn_cleanup(() -> entry.active || retire_tool!(entry))
    wait(worker; throw=false)
    istaskfailed(worker) && push!(failures, worker)
    worker = spawn_cleanup(() -> release!(invocation))
    wait(worker; throw=false)
    istaskfailed(worker) && push!(failures, worker)
    isempty(failures) || fetch(first(failures))
    return nothing
end

tool_result(value::ExecutionResult) = value
tool_result(value) = ExecutionResult(true, value isa AbstractString ? value : repr(value), value)

"""Request a fail-closed rejection of one completed tool call, withholding its value."""
struct ToolResultBlock
    reason::String
end
ToolResultBlock(reason::AbstractString) = ToolResultBlock(String(reason))

"""Change the text shown for a completed call without modifying its successful value."""
struct ToolResultText
    text::String
end
ToolResultText(text::AbstractString) = ToolResultText(String(text))

"""Replace a successful canonical value through the owning tool's validation and renderer."""
struct ToolResultValue{T}
    value::T
end

"""Select a post-execution policy through scoped events or independent multiple dispatch."""
tool_completion_decision(scope::ExtensionScope, call, result::ExecutionResult) =
    dispatch_event!(scope, :tool_completion, call, result; mode=:serial)

apply_tool_completion(::Nothing, result::ExecutionResult) = result
apply_tool_completion(decision::ToolResultBlock, result::ExecutionResult) =
    ExecutionResult(false, decision.reason)
apply_tool_completion(decision::ToolResultText, result::ExecutionResult) =
    ExecutionResult(result.ok, decision.text, result.ok ? result.value : nothing)
apply_tool_completion(decision, result::ExecutionResult) =
    ExecutionResult(false, "Unsupported tool completion decision")

"""Keep the existing two-argument policy extension point for non-value decisions."""
apply_tool_completion(decision, result::ExecutionResult, spec::ToolSpec, arguments) =
    apply_tool_completion(decision, result)

"""Reject attempts to revive a failure; validate and rerender substituted values."""
function apply_tool_completion(decision::ToolResultValue, result::ExecutionResult,
        spec::ToolSpec, arguments)
    result.ok || return ExecutionResult(false, "Cannot replace a failed tool result")
    value = decision.value
    candidate = ExecutionResult(true, value isa AbstractString ? value : repr(value), value)
    return checked_tool_result(spec, arguments, candidate)
end

"""Render model-visible tool text independently of the validated canonical value."""
tool_output_text(renderer, arguments, value) = Base.invokelatest(renderer, arguments, value)

"""A renderer is opt-in; its failure must not expose an otherwise valid tool value."""
function present_tool_result(spec::ToolSpec, arguments, result::ExecutionResult)
    isnothing(spec.output_renderer) && return result
    worker = spawn_scoped(() -> Base.invokelatest(tool_output_text,
        spec.output_renderer, arguments, result.value))
    wait(worker; throw=false)
    istaskfailed(worker) && return ExecutionResult(false, "Tool output renderer failed")
    text = fetch(worker)
    text isa AbstractString || return ExecutionResult(false, "Tool output renderer must return text")
    return ExecutionResult(true, String(text), result.value)
end

"""Validate successful canonical values before rendering them for the model."""
function checked_tool_result(spec::ToolSpec, arguments, returned)
    result = tool_result(returned)
    result.ok || return result
    violations = tool_output_violations(spec.output_schema, result.value)
    isempty(violations) || return ExecutionResult(false,
        string("Invalid tool result: ", join(violations, "; ")))
    return present_tool_result(spec, arguments, result)
end

"""Evaluate admission and argument checks before starting the Julia-owned tool callback."""
function admitted_tool_result(invocation, guards, scope::ExtensionScope, call, arguments, context)
    denial = first_tool_denial(guards, call, scope)
    isnothing(denial) || return ExecutionResult(false, denial)
    cancelled(context) && return ExecutionResult(false, "Tool call aborted before dispatch")
    violations = tool_argument_violations(invocation.listener.spec.schema, call.arguments)
    isempty(violations) || return ExecutionResult(false, string(join(violations, "; ")))
    cancelled(context) && return ExecutionResult(false, "Tool call aborted before dispatch")
    returned = event_value(Base.invokelatest(invocation.listener.spec.call, arguments...))
    return checked_tool_result(invocation.listener.spec, call.arguments, returned)
end

"""Complete an admitted tool result using an independently replaceable Julia policy."""
function complete_tool_result(scope::ExtensionScope, call, raw::ExecutionResult,
        context, spec::ToolSpec, arguments)
    decision = Base.invokelatest(tool_completion_decision, scope, call, raw)
    settled = Base.invokelatest(apply_tool_completion, decision, raw, spec, arguments)
    return cancelled(context) && settled.ok ?
        ExecutionResult(false, "Tool call aborted") : settled
end

"""Invoke a tool only after inherited guards permit it; post-policy cannot revive a failure."""
function invoke_tool!(scope::ExtensionScope, name::Symbol, arguments...;
        context=current_context(), tool_set=nothing)
    invocation = acquire_tool!(scope, name; tool_set)
    isnothing(invocation) && return ExecutionResult(false, "Unknown tool: $name")
    guards = acquire_tool_guards(scope)
    worker = spawn_scoped() do
        call = ToolCall(name, length(arguments) == 1 ? first(arguments) : arguments)
        if cancelled(context)
            ExecutionResult(false, "Tool call aborted before dispatch")
        else
            raw = admitted_tool_result(invocation, guards, scope, call, arguments, context)
            complete_tool_result(scope, call, raw, context, invocation.listener.spec, call.arguments)
        end
    end
    wait(worker; throw=false)
    guard_cleanup = spawn_cleanup(() -> release_event_invocations!(guards))
    tool_cleanup = spawn_cleanup(() -> release_tool!(invocation))
    wait(guard_cleanup; throw=false)
    wait(tool_cleanup; throw=false)
    istaskfailed(worker) && return ExecutionResult(false, sprint(showerror, TaskFailedException(worker)))
    istaskfailed(guard_cleanup) && return ExecutionResult(false, sprint(showerror, TaskFailedException(guard_cleanup)))
    istaskfailed(tool_cleanup) && return ExecutionResult(false, sprint(showerror, TaskFailedException(tool_cleanup)))
    return tool_result(fetch(worker))
end

struct ToolCall{A}
    name::Symbol
    arguments::A
end

ToolCall(name, arguments) = ToolCall(Symbol(name), arguments)

struct ToolExecutor
    scope::ExtensionScope
    owns_scope::Bool
end

ToolExecutor(scope::ExtensionScope; owns_scope=false) = ToolExecutor(scope, owns_scope)
ToolExecutor() = ToolExecutor(ExtensionScope(); owns_scope=true)

initialize_executor!(executor::ToolExecutor, session) = executor
fork_executor(executor::ToolExecutor) = ToolExecutor(ExtensionScope(executor.scope); owns_scope=true)
close_executor!(executor::ToolExecutor) = executor.owns_scope ? close(executor.scope) : nothing

"""Execute a protocol-independent tool action through an injected scoped tool registry."""
function execute!(executor::ToolExecutor, action::ToolCall, context::ExecutionContext)
    cancelled(context) && return ExecutionResult(false, "Cancelled")
    result = invoke_tool!(executor.scope, action.name, action.arguments; context)
    emit!(context, HarnessEvent(:tool_result, (name=action.name, result)))
    return result
end

action_kind(::ToolCall) = :tool_call
action_content(action::ToolCall) = string(action.name, "(", repr(action.arguments), ")")
agent_decision(action::ToolCall) = ActionDecision(action)
