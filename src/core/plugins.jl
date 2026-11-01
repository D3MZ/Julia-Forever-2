struct PluginSpec{F}
    name::Symbol
    setup::F
    provides::Vector{Symbol}
    requires::Vector{Symbol}
end

"""Declare a plugin factory and the service contracts it provides and requires."""
PluginSpec(name, setup; provides=Symbol[], requires=Symbol[]) =
    PluginSpec(Symbol(name), setup, collect(Symbol, provides), unique(collect(Symbol, requires)))
PluginSpec(setup::Function, name::Union{Symbol,AbstractString}; kwargs...) = PluginSpec(name, setup; kwargs...)

mutable struct PluginRegistry
    lock::ReentrantLock
    plugins::Dict{Symbol,PluginSpec}
end

PluginRegistry() = PluginRegistry(ReentrantLock(), Dict{Symbol,PluginSpec}())

"""Register an independently authored plugin without activating its effects."""
function register_plugin!(registry::PluginRegistry, spec::PluginSpec; replace=false)
    length(unique(spec.provides)) == length(spec.provides) ||
        return (ok=false, reason="Plugin $(spec.name) declares duplicate services")
    return lock(registry.lock) do
        haskey(registry.plugins, spec.name) && !replace &&
            return (ok=false, reason="Plugin $(spec.name) is already registered")
        registry.plugins[spec.name] = PluginSpec(spec.name, spec.setup;
            provides=copy(spec.provides), requires=copy(spec.requires))
        return (ok=true, reason="")
    end
end

"""Remove a factory from the catalog without interrupting existing activations."""
function unregister_plugin!(registry::PluginRegistry, name::Symbol)
    return lock(registry.lock) do
        present = haskey(registry.plugins, name)
        delete!(registry.plugins, name)
        return (ok=present, reason=present ? "" : "Plugin $name is not registered")
    end
end

struct Profile
    name::Symbol
    plugins::Vector{Symbol}
    config::Dict{Symbol,Any}
    bindings::Dict{Symbol,Symbol}
end

"""Select ordered plugins, their configuration, and explicit service implementation choices."""
Profile(name, plugins; config=Dict(), bindings=Dict()) = Profile(Symbol(name),
    collect(Symbol, plugins), Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(config)),
    Dict{Symbol,Symbol}(Symbol(key) => Symbol(value) for (key, value) in pairs(bindings)))

copy_profile(profile::Profile) = Profile(profile.name, copy(profile.plugins);
    config=deepcopy(profile.config), bindings=copy(profile.bindings))

mutable struct PluginContext{C}
    kernel::Kernel
    name::Symbol
    config::C
    owner::Symbol
    entry::Union{Nothing,ComponentEntry}
    selected::Set{Symbol}
    declared::Set{Symbol}
    dependencies::Dict{Symbol,Any}
    provided::Dict{Symbol,Any}
    pending::Set{Symbol}
    resources::Vector{ResourceRegistration}
    lock::ReentrantLock
    closed::Bool
    failure::String
end

function PluginContext(kernel::Kernel, spec::PluginSpec, config, selected)
    return PluginContext(kernel, spec.name, config, gensym(:plugin), nothing, Set(selected), Set(spec.provides),
        Dict{Symbol,Any}(), Dict{Symbol,Any}(), Set{Symbol}(), ResourceRegistration[], ReentrantLock(), false, "")
end

function plugin_available(context::PluginContext)
    return lock(context.kernel.lock) do
        entry = context.entry
        !isnothing(entry) && !entry.cleaning && !entry.cleaned && lock(() -> !context.closed, context.lock)
    end
end

"""Retain the activation generation even after a profile switch removes its original kernel names."""
function acquire_plugin!(context::PluginContext)
    return lock(context.kernel.lock) do
        entry = context.entry
        (isnothing(entry) || entry.cleaning || entry.cleaned || lock(() -> context.closed, context.lock)) && return nothing
        entry.users += 1
        return ComponentLease(context.kernel, entry, context, false)
    end
end

plugin_value(value) = value
plugin_value(value::Task) = plugin_value(fetch(value))

"""Retain an arbitrary plugin resource until every consumer of its activation has finished."""
function own_resource!(context::PluginContext, value; cleanup=close)
    owned = Ref{ResourceRegistration}()
    registration = ResourceRegistration(value, value -> begin
        lock(context.lock) do
            filter!(resource -> resource !== owned[], context.resources)
        end
        plugin_value(Base.invokelatest(cleanup, value))
    end)
    owned[] = registration
    accepted = lock(context.lock) do
        if context.closed
            false
        else
            push!(context.resources, registration)
            true
        end
    end
    accepted || release!(registration)
    return registration
end

"""Register a reversible plugin effect, disposed in reverse registration order."""
effect!(cleanup, context::PluginContext) = own_resource!(context, nothing;
    cleanup=value -> Base.invokelatest(cleanup))

"""Read an exact dependency generation or a service published by this activation."""
function service(context::PluginContext, name::Symbol)
    return lock(context.lock) do
        return get(context.dependencies, name, get(context.provided, name, nothing))
    end
end

function plugin_failure!(context::PluginContext, reason)
    lock(context.lock) do
        isempty(context.failure) && (context.failure = String(reason))
    end
    return (ok=false, reason=String(reason), active=false)
end

"""Publish a selected service; unselected implementations immediately release their value."""
function provide!(context::PluginContext, name::Symbol, value; requires=Symbol[], cleanup=Returns(nothing))
    dispose = value -> plugin_value(Base.invokelatest(cleanup, value))
    disposition = lock(context.lock) do
        context.closed && return :closed
        name in context.declared || return :undeclared
        name in context.selected || return :unselected
        (haskey(context.provided, name) || name in context.pending) && return :duplicate
        push!(context.pending, name)
        return :selected
    end
    if disposition !== :selected
        dispose(value)
        disposition === :unselected && return (ok=true, reason="", active=false)
        return plugin_failure!(context, "Plugin $(context.name) cannot provide $name: $disposition")
    end
    dependencies = unique([context.owner; collect(Symbol, requires)])
    result = install!(context.kernel, ComponentSpec(name, value; requires=dependencies, cleanup=dispose))
    if !result.ok
        lock(context.lock) do
            delete!(context.pending, name)
        end
        dispose(value)
        return plugin_failure!(context, result.reason)
    end
    lock(context.lock) do
        delete!(context.pending, name)
        context.provided[name] = value
    end
    return (ok=true, reason="", active=true)
end

"""Dispose every effect even when an earlier cleanup fails."""
function Base.close(context::PluginContext)
    resources = lock(context.lock) do
        context.closed = true
        pending = reverse(copy(context.resources))
        empty!(context.resources)
        pending
    end
    failures = Task[]
    for resource in resources
        worker = spawn_cleanup(() -> release!(resource))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

mutable struct PluginHost
    lock::ReentrantLock
    base::Kernel
    kernel::Kernel
    registry::PluginRegistry
    profile::Profile
    active::Vector{Symbol}
    revision::UInt64
    closed::Bool
end

"""Own an independently replaceable composition while retaining the supplied base services."""
function PluginHost(kernel::Kernel=Kernel(); registry::PluginRegistry=PluginRegistry())
    base = fork_kernel(kernel)
    return PluginHost(ReentrantLock(), base, fork_kernel(base), registry,
        Profile(:empty, Symbol[]), Symbol[], UInt64(0), !isopen(base))
end

PluginHost(kernel::Kernel, registry::PluginRegistry) = PluginHost(kernel; registry)

function profile_specs(registry::PluginRegistry, profile::Profile)
    length(unique(profile.plugins)) == length(profile.plugins) ||
        return (ok=false, reason="Profile $(profile.name) selects a plugin more than once", specs=PluginSpec[])
    return lock(registry.lock) do
        missing = filter(name -> !haskey(registry.plugins, name), profile.plugins)
        isempty(missing) || return (ok=false, reason="Unknown plugins: $(join(missing, ", "))", specs=PluginSpec[])
        specs = PluginSpec[registry.plugins[name] for name in profile.plugins]
        return (ok=true, reason="", specs)
    end
end

function profile_providers(specs, profile::Profile)
    candidates = Dict{Symbol,Vector{Symbol}}()
    for spec in specs, name in spec.provides
        push!(get!(Vector{Symbol}, candidates, name), spec.name)
    end
    selected = Dict{Symbol,Symbol}()
    for name in sort!(collect(keys(candidates)))
        names = candidates[name]
        chosen = get(profile.bindings, name, nothing)
        if isnothing(chosen)
            length(names) == 1 || return (ok=false, reason="Service $name has multiple providers; select a profile binding", selected)
            selected[name] = only(names)
        elseif chosen in names
            selected[name] = chosen
        else
            return (ok=false, reason="Plugin $chosen does not provide service $name in this profile", selected)
        end
    end
    for name in keys(profile.bindings)
        haskey(candidates, name) || return (ok=false, reason="Profile binding $name has no selected provider", selected)
    end
    return (ok=true, reason="", selected)
end

function profile_order(specs, selected, base::Kernel)
    available = Set(item.name for item in component_snapshot(base))
    remaining = filter(spec -> isempty(spec.provides) || any(name -> get(selected, name, nothing) === spec.name, spec.provides), specs)
    ordered = PluginSpec[]
    completed = Set{Symbol}()
    for spec in remaining, name in spec.requires
        if !haskey(selected, name) && !(name in available)
            return (ok=false, reason="Plugin $(spec.name) requires unavailable service $name", ordered)
        end
    end
    while !isempty(remaining)
        index = findfirst(remaining) do spec
            all(spec.requires) do name
                provider = get(selected, name, nothing)
                isnothing(provider) ? name in available : provider in completed
            end
        end
        isnothing(index) && return (ok=false, reason="Cyclic plugin service dependencies", ordered)
        spec = popat!(remaining, index)
        push!(ordered, spec)
        push!(completed, spec.name)
    end
    return (ok=true, reason="", ordered)
end

function plugin_setup_result(result)
    hasproperty(result, :ok) || return (ok=true, reason="")
    result.ok === true && return (ok=true, reason="")
    detail = hasproperty(result, :reason) ? result.reason :
        hasproperty(result, :text) ? result.text :
        hasproperty(result, :error) ? sprint(show, result.error) : "Plugin setup failed"
    return (ok=false, reason=string(detail))
end
plugin_setup_result(result::Bool) = (ok=result, reason=result ? "" : "Plugin setup returned false")
plugin_setup_result(result::Task) = plugin_setup_result(plugin_value(result))
function plugin_setup_result(result::NamedTuple)
    successful = get(result, :ok, true)
    return (ok=successful === true, reason=successful === true ? "" : String(get(result, :reason, "Plugin setup failed")))
end

function setup_plugin!(kernel::Kernel, spec::PluginSpec, profile::Profile, selected)
    names = filter(name -> get(selected, name, nothing) === spec.name, spec.provides)
    context = PluginContext(kernel, spec, get(profile.config, spec.name, NamedTuple()), names)
    installed = install!(kernel, ComponentSpec(context.owner, context; requires=spec.requires, cleanup=close))
    installed.ok || return installed
    lock(kernel.lock) do
        owner = kernel.entries[context.owner]
        context.entry = owner
        for entry in owner.dependencies
            context.dependencies[entry.spec.name] = entry.spec.value
        end
    end
    result = plugin_setup_result(Base.invokelatest(spec.setup, context))
    result.ok || return result
    isempty(context.failure) || return (ok=false, reason=context.failure)
    missing = setdiff(context.selected, keys(context.provided))
    isempty(missing) || return (ok=false, reason="Plugin $(spec.name) did not provide: $(join(sort!(collect(missing)), ", "))")
    return (ok=true, reason="")
end

function setup_profile!(kernel::Kernel, ordered, profile::Profile, selected)
    for spec in ordered
        result = setup_plugin!(kernel, spec, profile, selected)
        result.ok || return result
    end
    return (ok=true, reason="")
end

function close_composition!(kernel::Kernel)
    worker = spawn_cleanup(() -> close(kernel))
    wait(worker; throw=false)
    return istaskfailed(worker) ? sprint(showerror, TaskFailedException(worker)) : ""
end

function discard_composition!(kernel::Kernel, reason)
    cleanup = close_composition!(kernel)
    detail = isempty(cleanup) ? String(reason) : "$reason; cleanup failed: $cleanup"
    return (ok=false, reason=detail)
end

"""Stage a complete profile and publish it only after all selected plugins initialize successfully."""
function activate!(host::PluginHost, requested::Profile)
    profile = copy_profile(requested)
    catalog = profile_specs(host.registry, profile)
    catalog.ok || return (ok=false, reason=catalog.reason)
    providers = profile_providers(catalog.specs, profile)
    providers.ok || return (ok=false, reason=providers.reason)
    initial = lock(host.lock) do
        (closed=host.closed, revision=host.revision, kernel=host.closed ? nothing : fork_kernel(host.base))
    end
    staged = initial.kernel
    isnothing(staged) && return (ok=false, reason="Plugin host is closed")
    order = profile_order(catalog.specs, providers.selected, staged)
    order.ok || return discard_composition!(staged, order.reason)
    worker = spawn_scoped(() -> setup_profile!(staged, order.ordered, profile, providers.selected))
    wait(worker; throw=false)
    if istaskfailed(worker)
        return discard_composition!(staged, sprint(showerror, TaskFailedException(worker)))
    end
    setup = fetch(worker)
    setup.ok || return discard_composition!(staged, setup.reason)
    committed = lock(host.lock) do
        if host.closed || host.revision != initial.revision
            return (ok=false, previous=nothing)
        end
        previous = host.kernel
        host.kernel = staged
        host.profile = profile
        host.active = [spec.name for spec in order.ordered]
        host.revision += UInt64(1)
        return (ok=true, previous)
    end
    previous = committed.previous
    isnothing(previous) && return discard_composition!(staged, "Plugin composition changed during activation")
    cleanup = close_composition!(previous)
    return (ok=true, reason=isempty(cleanup) ? "" : "Previous profile cleanup failed: $cleanup")
end

"""Remove a plugin by staging the remaining profile and validating its service dependencies."""
function deactivate!(host::PluginHost, name::Symbol)
    profile = lock(host.lock) do
        copy_profile(host.profile)
    end
    name in profile.plugins || return (ok=false, reason="Plugin $name is not selected")
    filter!(!=(name), profile.plugins)
    delete!(profile.config, name)
    filter!(pair -> last(pair) !== name, profile.bindings)
    return activate!(host, profile)
end

"""Snapshot the current profile without exposing mutable registration state or live resources."""
function plugin_snapshot(host::PluginHost)
    return lock(host.lock) do
        return (profile=copy_profile(host.profile), active=copy(host.active), revision=host.revision, closed=host.closed)
    end
end

component(host::PluginHost, name::Symbol) = lock(() -> component(host.kernel, name), host.lock)
component_snapshot(host::PluginHost) = lock(() -> component_snapshot(host.kernel), host.lock)
fork_kernel(host::PluginHost) = lock(() -> fork_kernel(host.kernel), host.lock)
bind_component(host::PluginHost, name::Symbol; kwargs...) = lock(() -> bind_component(host.kernel, name; kwargs...), host.lock)
acquire!(host::PluginHost, name::Symbol) = lock(() -> acquire!(host.kernel, name), host.lock)
Base.isopen(host::PluginHost) = lock(() -> !host.closed, host.lock)

"""Use the current service generation outside host locks and release it even when the callback fails."""
function with_component(callback, host::PluginHost, name::Symbol; fallback=nothing)
    binding = bind_component(host, name; fallback, owner=nothing)
    binding.available || return nothing
    worker = spawn_scoped(() -> plugin_value(Base.invokelatest(callback, binding.value)))
    wait(worker; throw=false)
    cleanup = spawn_cleanup(() -> release!(binding))
    wait(cleanup; throw=false)
    istaskfailed(worker) && return fetch(worker)
    fetch(cleanup)
    return fetch(worker)
end

"""Close the host while outstanding session and component leases retain their exact plugin resources."""
function Base.close(host::PluginHost)
    compositions = lock(host.lock) do
        if host.closed
            Kernel[]
        else
            host.closed = true
            host.revision += UInt64(1)
            [host.kernel, host.base]
        end
    end
    failures = Task[]
    for kernel in compositions
        worker = spawn_cleanup(() -> close(kernel))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end
