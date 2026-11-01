abstract type AbstractEventListener end
abstract type AbstractToolEntry end
abstract type AbstractToolGuard end

struct ToolSpec{S,F,O,P,R}
    name::Symbol
    schema::S
    call::F
    description::String
    output_schema::O
    concurrency_policy::P
    output_renderer::R
end

"""Describe a tool independently of its executor, provider schema, or presentation protocol."""
ToolSpec(name, schema, callback; description="", output_schema=nothing, concurrency_safe=false, render_output=nothing) = ToolSpec(Symbol(name), schema, callback, String(description), output_schema, concurrency_safe, render_output)
ToolSpec(name::Symbol, schema, callback, description::AbstractString) = ToolSpec(name, schema, callback, String(description), nothing, false, nothing)
ToolSpec(name::Symbol, schema, callback, description::String, output_schema) = ToolSpec(name, schema, callback, description, output_schema, false, nothing)
ToolSpec(name::Symbol, schema, callback, description::String, output_schema, concurrency_policy) = ToolSpec(name, schema, callback, description, output_schema, concurrency_policy, nothing)
ToolSpec(name, callback; schema=(type="object",), description="", output_schema=nothing, concurrency_safe=false, render_output=nothing) = ToolSpec(name, schema, callback; description, output_schema, concurrency_safe, render_output)
ToolSpec(callback::Function, name::Union{Symbol,AbstractString}, schema; kwargs...) = ToolSpec(name, schema, callback; kwargs...)
ToolSpec(callback::Function, name::Union{Symbol,AbstractString}; kwargs...) = ToolSpec(name, callback; kwargs...)

"""A tool declares parallel safety explicitly; plugins can dispatch on their policy type."""
tool_concurrency_safe(policy::Bool, arguments) = policy
tool_concurrency_safe(policy, arguments) = Base.invokelatest(policy, arguments)
tool_concurrency_safe(spec::ToolSpec, arguments) = tool_concurrency_safe(spec.concurrency_policy, arguments)

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
    lock(scope.lock) do
        current = scope
        while !isnothing(current) && !current.closed
            current = current.parent
        end
        isnothing(current)
    end
end
function scope_admits(scope::ExtensionScope, listener_scope::ExtensionScope)
    current = scope
    while !isnothing(current) && current !== listener_scope
        current = current.parent
    end
    isnothing(listener_scope.parent) || !isnothing(current)
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
        resources
    else
        ResourceRegistration[]
    end
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
    if !isempty(retired.children) || !isempty(retired.resources)
        dispose!(retired.children, retired.resources)
    end
    nothing
end

function dispose!(children::Vector{ExtensionScope}, resources::Vector{ResourceRegistration})
    failures = Task[]
    for child in children
        worker = spawn_cleanup(() -> close(child))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    if !isempty(resources)
        worker = spawn_cleanup(() -> dispose_extension_resources!(resources))
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
    lock(root.lock) do
        invocations = EventInvocation[]
        for listener in get(root.listeners, name, AbstractEventListener[])
            if listener.active && isopen(listener.scope) && (listener.global_listener || scope_admits(scope, listener.scope))
                invocation = retain!(listener)
                if !isnothing(invocation)
                    push!(invocations, invocation)
                end
            end
        end
        invocations
    end
end

function retain!(listener::Union{AbstractEventListener,AbstractToolGuard,AbstractToolEntry})
    retention = isnothing(listener.owner) ? nothing : acquire_plugin!(listener.owner)
    isnothing(listener.owner) || !isnothing(retention) ? retain!(EventInvocation(listener, retention, extension_chain(listener.scope), nothing)) : nothing
end

function retain!(invocation::EventInvocation)
    foreach(scope -> scope.users += 1, invocation.scopes)
    invocation
end
function release!(invocation::EventInvocation)
    invocation.pending = pending(invocation.pending)
    release!(invocation, invocation.pending)
end

function pending(task::Union{Nothing,Task})
    current = task
    while !isnothing(current) && istaskdone(current)
        value = istaskfailed(current) ? nothing : fetch(current)
        current = value isa Task ? value : nothing
    end
    current
end

function release!(invocation::EventInvocation, task::Task)
    spawn_scoped() do
        wait(task; throw=false)
        value = istaskfailed(task) ? nothing : fetch(task)
        invocation.pending = value isa Task ? value : nothing
        release!(invocation)
    end
    nothing
end

function release!(invocation::EventInvocation, ::Nothing)
    resources = lock(invocation.listener.scope.lock) do
        resources = ResourceRegistration[]
        for scope in invocation.scopes
            scope.users -= 1
            append!(resources, extension_resources!(scope))
        end
        empty!(invocation.scopes)
        resources
    end
    if !isempty(resources) || !isnothing(invocation.retention)
        dispose!(invocation, resources)
    end
    nothing
end

function dispose!(invocation::EventInvocation, resources::Vector{ResourceRegistration})
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
    nothing
end
function claim_listener!(listener::EventListener)
    lock(listener.scope.lock) do
        accepted = !listener.once || !listener.claimed
        if accepted && listener.once
            listener.claimed = true
            listener.active = false
            if !isnothing(listener.registration)
                release!(listener.registration)
            end
        end
        accepted
    end
end
event_value(value) = value
event_value(value::Task) = event_value(fetch(value))
event_bailed(value) = value !== nothing && value !== false

function invoke_listener(invocation::EventInvocation, arguments; awaited=false)
    claim_listener!(invocation.listener) ? invoke(invocation, arguments, awaited) : nothing
end

function invoke(invocation::EventInvocation, arguments, awaited::Bool)
    value = Base.invokelatest(invocation.listener.callback, arguments...)
    if value isa Task
        invocation.pending = value
    end
    awaited ? event_value(value) : value
end
function dispatch_listeners(::Val{:emit}, invocations, arguments)
    for invocation in invocations
        invoke_listener(invocation, arguments)
    end
    return nothing
end

dispatch_listeners(::Val{:bail}, invocations, arguments) = firstresponse(invocations, arguments, false)
dispatch_listeners(::Val{:serial}, invocations, arguments) = firstresponse(invocations, arguments, true)

function firstresponse(invocations, arguments, awaited)
    index = 1
    value = nothing
    while index <= length(invocations) && !event_bailed(value)
        value = invoke_listener(invocations[index], arguments; awaited)
        index += 1
    end
    event_bailed(value) ? value : nothing
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
    index > length(invocations) ? Base.invokelatest(inner) : cascade(invocations[index], invocations, index, arguments, inner)
end

function cascade(invocation::EventInvocation, invocations, index, arguments, inner)
    if claim_listener!(invocation.listener)
        next = continuation(invocations, index + 1, arguments, inner)
        value = Base.invokelatest(invocation.listener.callback, arguments..., next)
        if value isa Task
            lock(invocation.listener.scope.lock) do
                invocation.pending = value
            end
        end
        value
    else
        event_waterfall(invocations, index + 1, arguments, inner)
    end
end

function continuation(invocations, index, arguments, inner)
    called = Threads.Atomic{Bool}(false)
    () -> Threads.atomic_xchg!(called, true) ? error("next() called multiple times") : event_waterfall(invocations, index, arguments, inner)
end
dispatch_listeners(::Val{:waterfall}, invocations, arguments) = event_waterfall(invocations, 1, Base.front(arguments), last(arguments))

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
    pending = returned isa Task ? Task[returned] : Task[]
    seen = IdDict{Task,Nothing}()
    refresh!(pending, invocations, seen)
    while !isempty(pending)
        worker = popfirst!(pending)
        seen[worker] = nothing
        wait(worker; throw=false)
        if !istaskfailed(worker)
            value = fetch(worker)
            value isa Task && push!(pending, value)
        end
        refresh!(pending, invocations, seen)
    end
    nothing
end

function refresh!(pending::Vector{Task}, invocations, seen)
    append!(pending, waterfall_tasks(invocations))
    filter!(task -> !haskey(seen, task), pending)
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
    isempty(invocations) && mode in (:emit, :bail, :serial, :parallel) ? nothing : dispatch!(invocations, arguments, mode)
end

function dispatch!(invocations::Vector{EventInvocation}, arguments, mode::Symbol)
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
    resolve(worker, [cleanup])
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
        register!(scope, entry)
    end
    accepted.ok ? own!(scope, entry, owner, retire_tool!) : (ok=false, reason=accepted.reason, registration=nothing)
end

function register!(scope::ExtensionScope, entry::ToolEntry)
    name = entry.spec.name
    if !isopen(scope)
        (ok=false, reason="Extension scope is closed")
    elseif haskey(scope.tools, name)
        (ok=false, reason="Tool $name is already registered in this scope")
    else
        scope.tools[name] = entry
        push!(scope.tool_order, name)
        (ok=true, reason="")
    end
end

function own!(scope::ExtensionScope, value, owner, cleanup)
    registration = own_resource!(scope, value; cleanup)
    if !isnothing(owner)
        own_resource!(owner, registration; cleanup=release!)
    end
    (ok=true, reason="", registration)
end
function overlay_tools!(names, entries, scope::ExtensionScope)
    if isopen(scope)
        for name in scope.tool_order
            entry = scope.tools[name]
            if available(entry)
                if !haskey(entries, name)
                    push!(names, name)
                end
                entries[name] = entry
            end
        end
    end
    nothing
end

available(::Nothing) = false
available(entry::ToolEntry) = entry.active && (isnothing(entry.owner) || plugin_available(entry.owner))
function tool_admitted(scope::ExtensionScope, name::Symbol)
    !isopen(scope) || all(scope.restrictions) do restriction
        (isnothing(restriction.allow) || name in restriction.allow) && (isnothing(restriction.deny) || !(name in restriction.deny))
    end
end
function tool_view(scope::ExtensionScope)
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

"""Select a single visible tool without materializing the catalog used by snapshots.

The caller holds the scope lock. A local tool overrides inherited restrictions,
while an inherited match must satisfy restrictions from every visible layer.
"""
function visible_tool_entry(scope::ExtensionScope, name::Symbol)
    current = scope
    selected = nothing
    while !isnothing(current) && isnothing(selected)
        entry = get(current.tools, name, nothing)
        if available(entry) && isopen(current)
            selected = entry
        else
            current = current.parent
        end
    end
    isnothing(selected) || current === scope || admitted(scope, name) ? selected : nothing
end

function admitted(scope::ExtensionScope, name::Symbol)
    current = scope
    while !isnothing(current) && tool_admitted(current, name)
        current = current.parent
    end
    isnothing(current)
end
"""Resolve a tool after nearest-scope shadowing and all inherited restrictions."""
function tool(scope::ExtensionScope, name::Symbol)
    return lock(scope.lock) do
        entry = visible_tool_entry(scope, name)
        isnothing(entry) ? nothing : entry.spec
    end
end

"""Copy the visible tool schema surface without exposing live executors or registration handles."""
function tools_snapshot(scope::ExtensionScope)
    return lock(scope.lock) do
        view = tool_view(scope)
        return [(name=name, schema=deepcopy(tool_schema_definition(view.entries[name].spec.schema)),
            description=view.entries[name].spec.description) for name in view.names]
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
    if isnothing(scope.parent)
        (ok=false, reason="Tool restrictions require a scoped context", registration=nothing)
    elseif isnothing(allow) && isnothing(deny)
        (ok=false, reason="A tool restriction needs allow or deny", registration=nothing)
    else
        restrict!(scope, ToolRestriction(; allow, deny), owner)
    end
end

ToolRestriction(; allow=nothing, deny=nothing) = ToolRestriction(isnothing(allow) ? nothing : Set(Symbol.(allow)), isnothing(deny) ? nothing : Set(Symbol.(deny)))

function restrict!(scope::ExtensionScope, restriction::ToolRestriction, owner)
    accepted = lock(scope.lock) do
        register!(scope, restriction)
    end
    accepted.ok ? own!(scope, restriction, owner, value -> remove_restriction!(scope, value)) : (ok=false, reason=accepted.reason, registration=nothing)
end

function register!(scope::ExtensionScope, restriction::ToolRestriction)
    known = tool_view(scope).restrictable
    specified = union(something(restriction.allow, Set{Symbol}()), something(restriction.deny, Set{Symbol}()))
    unknown = setdiff(specified, known)
    if !isopen(scope)
        (ok=false, reason="Extension scope is closed")
    elseif !isempty(unknown)
        (ok=false, reason="Unknown inherited tools: $(join(sort!(collect(unknown)), ", "))")
    else
        push!(scope.restrictions, restriction)
        (ok=true, reason="")
    end
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
        if isopen(scope)
            push!(scope.guards, entry)
            true
        else
            false
        end
    end
    accepted ? own!(scope, entry, owner, retire_tool_guard!) : (ok=false, reason="Extension scope is closed", registration=nothing)
end
"""Retain the exact guard generations and scopes while a tool call is being admitted."""
function acquire_tool_guards(scope::ExtensionScope)
    lock(scope.lock) do
        invocations = EventInvocation[]
        for layer in reverse(extension_chain(scope)), guard in layer.guards
            if guard.active && isopen(layer)
                invocation = retain!(guard)
                if !isnothing(invocation)
                    push!(invocations, invocation)
                end
            end
        end
        invocations
    end
end
"""The approval protocol is independently replaceable by dispatch on the request type."""
tool_approval_reason(::AbstractToolApprovalRequest) = nothing
tool_approval_reason(request::ToolApprovalRequest) = request.reason

"""Resolve a request through Julia-owned scoped event listeners, never an external runtime."""
tool_approval_outcome(scope::ExtensionScope, call, request::AbstractToolApprovalRequest) = dispatch_event!(scope, :tool_approval, call, request; mode=:serial)

"""Fail closed for missing, rejected, cancelled, or unsupported approval outcomes."""
function tool_approval_denial(scope::ExtensionScope, call, request::AbstractToolApprovalRequest)
    outcome = Base.invokelatest(tool_approval_outcome, scope, call, request)
    approval(outcome, call, request)
end

function approval(outcome, call, request::AbstractToolApprovalRequest)
    if outcome === :allowed_once
        nothing
    elseif outcome === :rejected
        "the user rejected tool \"$(call.name)\""
    elseif outcome === :cancelled
        "approval for tool \"$(call.name)\" was cancelled"
    elseif outcome === :unavailable
        "tool \"$(call.name)\" requires approval, but no approval channel is available"
    else
        "Unsupported approval outcome for tool \"$(call.name)\""
    end
end

function approval(::Nothing, call, request::AbstractToolApprovalRequest)
    reason = Base.invokelatest(tool_approval_reason, request)
    isnothing(reason) ? "tool \"$(call.name)\" requires approval (not yet supported)" : String(reason)
end
"""Evaluate root-to-leaf tool guards; approval never grants an exemption from later guards."""
function first_tool_denial(invocations, call, scope::ExtensionScope)
    result = nothing
    index = 1
    while index <= length(invocations) && isnothing(result)
        decision = Base.invokelatest(invocations[index].listener.callback, call)
        result = denial(decision, scope, call)
        index += 1
    end
    result
end

denial(decision::AbstractToolApprovalRequest, scope::ExtensionScope, call) = tool_approval_denial(scope, call, decision)
denial(::Nothing, scope::ExtensionScope, call) = nothing
denial(decision::AbstractString, scope::ExtensionScope, call) = String(decision)
denial(decision, scope::ExtensionScope, call) = "Tool guard must return a string, an approval request, or nothing"
function acquire_tool!(scope::ExtensionScope, name::Symbol)
    lock(scope.lock) do
        entry = visible_tool_entry(scope, name)
        isnothing(entry) ? nothing : acquire!(entry)
    end
end

function acquire!(entry::ToolEntry)
    invocation = retain!(entry)
    if !isnothing(invocation)
        entry.users += 1
    end
    invocation
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
tool_completion_decision(scope::ExtensionScope, call, result::ExecutionResult) = dispatch_event!(scope, :tool_completion, call, result; mode=:serial)

apply_tool_completion(::Nothing, result::ExecutionResult) = result
apply_tool_completion(decision::ToolResultBlock, result::ExecutionResult) = ExecutionResult(false, decision.reason)
apply_tool_completion(decision::ToolResultText, result::ExecutionResult) = ExecutionResult(result.ok, decision.text, result.ok ? result.value : nothing)
apply_tool_completion(decision, result::ExecutionResult) = ExecutionResult(false, "Unsupported tool completion decision")

"""Keep the existing two-argument policy extension point for non-value decisions."""
apply_tool_completion(decision, result::ExecutionResult, spec::ToolSpec, arguments) = apply_tool_completion(decision, result)

"""Reject attempts to revive a failure; validate and rerender substituted values."""
function apply_tool_completion(decision::ToolResultValue, result::ExecutionResult, spec::ToolSpec, arguments)
    result.ok ? substitute(decision, spec, arguments) : ExecutionResult(false, "Cannot replace a failed tool result")
end

function substitute(decision::ToolResultValue, spec::ToolSpec, arguments)
    value = decision.value
    checked_tool_result(spec, arguments, ExecutionResult(true, value isa AbstractString ? value : repr(value), value))
end

"""Render model-visible tool text independently of the validated canonical value."""
tool_output_text(renderer, arguments, value) = Base.invokelatest(renderer, arguments, value)

"""A renderer is opt-in; its failure must not expose an otherwise valid tool value."""
function present_tool_result(spec::ToolSpec, arguments, result::ExecutionResult)
    isnothing(spec.output_renderer) ? result : render(spec, arguments, result)
end

function render(spec::ToolSpec, arguments, result::ExecutionResult)
    worker = spawn_scoped(() -> Base.invokelatest(tool_output_text, spec.output_renderer, arguments, result.value))
    wait(worker; throw=false)
    istaskfailed(worker) ? ExecutionResult(false, "Tool output renderer failed") : rendered(fetch(worker), result)
end

rendered(text::AbstractString, result::ExecutionResult) = ExecutionResult(true, String(text), result.value)
rendered(text, result::ExecutionResult) = ExecutionResult(false, "Tool output renderer must return text")
"""Validate successful canonical values before rendering them for the model."""
function checked_tool_result(spec::ToolSpec, arguments, returned)
    result = tool_result(returned)
    result.ok ? validate(spec, arguments, result) : result
end

function validate(spec::ToolSpec, arguments, result::ExecutionResult)
    violations = tool_output_violations(spec.output_schema, result.value)
    isempty(violations) ? present_tool_result(spec, arguments, result) : ExecutionResult(false, string("Invalid tool result: ", join(violations, "; ")))
end
"""Evaluate admission and argument checks before starting the Julia-owned tool callback."""
function admitted_tool_result(invocation, guards, scope::ExtensionScope, call, arguments, context)
    reason = first_tool_denial(guards, call, scope)
    isnothing(reason) ? validate(invocation.listener.spec, call, arguments, context) : ExecutionResult(false, reason)
end

function validate(spec::ToolSpec, call, arguments, context)
    if cancelled(context)
        ExecutionResult(false, "Tool call aborted before dispatch")
    else
        violations = tool_argument_violations(spec.schema, call.arguments)
        isempty(violations) ? invoke(spec, call, arguments, context) : ExecutionResult(false, string(join(violations, "; ")))
    end
end

function invoke(spec::ToolSpec, call, arguments, context)
    if cancelled(context)
        ExecutionResult(false, "Tool call aborted before dispatch")
    else
        returned = event_value(Base.invokelatest(spec.call, arguments...))
        checked_tool_result(spec, call.arguments, returned)
    end
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
function invoke_tool!(scope::ExtensionScope, name::Symbol, arguments...; context=current_context())
    invocation = acquire_tool!(scope, name)
    isnothing(invocation) ? ExecutionResult(false, "Unknown tool: $name") : invoke(scope, invocation, arguments, context)
end

function invoke(scope::ExtensionScope, invocation::EventInvocation, arguments, context)
    guards = acquire_tool_guards(scope)
    worker = spawn_scoped() do
        call = ToolCall(invocation.listener.spec.name, length(arguments) == 1 ? first(arguments) : arguments)
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
    workers = (worker, guard_cleanup, tool_cleanup)
    failed = findfirst(istaskfailed, workers)
    isnothing(failed) ? tool_result(fetch(worker)) : ExecutionResult(false, sprint(showerror, TaskFailedException(workers[failed])))
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
    cancelled(context) ? ExecutionResult(false, "Cancelled") : execute(executor, action, context)
end

function execute(executor::ToolExecutor, action::ToolCall, context::ExecutionContext)
    result = invoke_tool!(executor.scope, action.name, action.arguments; context)
    emit!(context, HarnessEvent(:tool_result, (name=action.name, result)))
    result
end
action_kind(::ToolCall) = :tool_call
action_content(action::ToolCall) = string(action.name, "(", repr(action.arguments), ")")
agent_decision(action::ToolCall) = ActionDecision(action)
