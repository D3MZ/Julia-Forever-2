struct PluginSpec{F}
    name::Symbol
    setup::F
    provides::Vector{Symbol}
    requires::Vector{Symbol}
end

"""Declare a plugin factory and the service contracts it provides and requires."""
PluginSpec(name, setup; provides=Symbol[], requires=Symbol[]) = PluginSpec(Symbol(name), setup, collect(Symbol, provides), unique(collect(Symbol, requires)))
PluginSpec(setup::Function, name::Union{Symbol,AbstractString}; kwargs...) = PluginSpec(name, setup; kwargs...)

Base.@kwdef mutable struct PluginRegistry
    lock::ReentrantLock = ReentrantLock()
    plugins::Dict{Symbol,PluginSpec} = Dict{Symbol,PluginSpec}()
end

"""Register an independently authored plugin without activating its effects."""
function register_plugin!(registry::PluginRegistry, spec::PluginSpec; replace=false)
    lock(registry.lock) do
        if length(unique(spec.provides)) != length(spec.provides)
            (ok=false, reason="Plugin $(spec.name) declares duplicate services")
        elseif haskey(registry.plugins, spec.name) && !replace
            (ok=false, reason="Plugin $(spec.name) is already registered")
        else
            registry.plugins[spec.name] = PluginSpec(spec)
            (ok=true, reason="")
        end
    end
end

PluginSpec(spec::PluginSpec) = PluginSpec(spec.name, spec.setup; provides=copy(spec.provides), requires=copy(spec.requires))
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
Profile(name, plugins; config=Dict(), bindings=Dict()) = Profile(Symbol(name), collect(Symbol, plugins), Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(config)), Dict{Symbol,Symbol}(Symbol(key) => Symbol(value) for (key, value) in pairs(bindings)))

Profile(profile::Profile) = Profile(profile.name, copy(profile.plugins); config=deepcopy(profile.config), bindings=copy(profile.bindings))
copy_profile(profile::Profile) = Profile(profile)

"""Compose reusable plugin groups; later groups replace plugin configuration and service bindings."""
function Profile(name, profiles::Profile...)
    plugins = Symbol[]
    config = Dict{Symbol,Any}()
    bindings = Dict{Symbol,Symbol}()
    for profile in profiles
        for plugin in profile.plugins
            plugin in plugins || push!(plugins, plugin)
        end
        for (plugin, value) in profile.config
            config[plugin] = deepcopy(value)
        end
        merge!(bindings, profile.bindings)
    end
    return Profile(name, plugins; config, bindings)
end

compose_profiles(name, profiles::Profile...) = Profile(name, profiles...)

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
    lock(context.kernel.lock) do
        plugin_available(context) ? retain!(context.kernel, context.entry) : nothing
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
effect!(cleanup, context::PluginContext) = own_resource!(context, nothing; cleanup=value -> Base.invokelatest(cleanup))

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
function reserve!(context::PluginContext, name::Symbol)
    lock(context.lock) do
        if context.closed
            :closed
        elseif !(name in context.declared)
            :undeclared
        elseif !(name in context.selected)
            :unselected
        elseif haskey(context.provided, name) || name in context.pending
            :duplicate
        else
            push!(context.pending, name)
            :selected
        end
    end
end

function provide!(context::PluginContext, name::Symbol, value; requires=Symbol[], cleanup=Returns(nothing))
    dispose = value -> plugin_value(Base.invokelatest(cleanup, value))
    disposition = reserve!(context, name)
    if disposition === :selected
        publish!(context, name, value, requires, dispose)
    else
        dispose(value)
        disposition === :unselected ? (ok=true, reason="", active=false) : plugin_failure!(context, "Plugin $(context.name) cannot provide $name: $disposition")
    end
end

function publish!(context::PluginContext, name::Symbol, value, requires, dispose)
    dependencies = unique([context.owner; collect(Symbol, requires)])
    result = install!(context.kernel, ComponentSpec(name, value; requires=dependencies, cleanup=dispose))
    lock(context.lock) do
        delete!(context.pending, name)
        if result.ok
            context.provided[name] = value
        end
    end
    if result.ok
        (ok=true, reason="", active=true)
    else
        dispose(value)
        plugin_failure!(context, result.reason)
    end
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
    lock(registry.lock) do
        absent = filter(name -> !haskey(registry.plugins, name), profile.plugins)
        if length(unique(profile.plugins)) != length(profile.plugins)
            (ok=false, reason="Profile $(profile.name) selects a plugin more than once", specs=PluginSpec[])
        elseif !isempty(absent)
            (ok=false, reason="Unknown plugins: $(join(absent, ", "))", specs=PluginSpec[])
        else
            (ok=true, reason="", specs=PluginSpec[registry.plugins[name] for name in profile.plugins])
        end
    end
end
function profile_providers(specs, profile::Profile)
    candidates = Dict{Symbol,Vector{Symbol}}()
    for spec in specs, name in spec.provides
        push!(get!(Vector{Symbol}, candidates, name), spec.name)
    end
    selected = Dict{Symbol,Symbol}()
    reason = select!(selected, candidates, profile.bindings)
    absent = filter(name -> !haskey(candidates, name), collect(keys(profile.bindings)))
    if isempty(reason) && !isempty(absent)
        reason = "Profile binding $(first(absent)) has no selected provider"
    end
    (ok=isempty(reason), reason, selected)
end

function select!(selected::Dict{Symbol,Symbol}, candidates, bindings)
    names = sort!(collect(keys(candidates)))
    index = 1
    reason = ""
    while index <= length(names) && isempty(reason)
        name = names[index]
        reason = select!(selected, name, candidates[name], get(bindings, name, nothing))
        index += 1
    end
    reason
end

function select!(selected::Dict{Symbol,Symbol}, name::Symbol, candidates, chosen)
    if isnothing(chosen) && length(candidates) != 1
        "Service $name has multiple providers; select a profile binding"
    elseif !isnothing(chosen) && !(chosen in candidates)
        "Plugin $chosen does not provide service $name in this profile"
    else
        selected[name] = isnothing(chosen) ? only(candidates) : chosen
        ""
    end
end
function profile_order(specs, selected, base::Kernel)
    available = Set(item.name for item in component_snapshot(base))
    remaining = filter(spec -> isempty(spec.provides) || any(name -> get(selected, name, nothing) === spec.name, spec.provides), specs)
    absent = [(spec.name, name) for spec in remaining for name in spec.requires if !haskey(selected, name) && !(name in available)]
    if isempty(absent)
        order!(remaining, selected, available)
    else
        plugin, service = first(absent)
        (ok=false, reason="Plugin $plugin requires unavailable service $service", ordered=PluginSpec[])
    end
end

function order!(remaining, selected, available)
    ordered = PluginSpec[]
    completed = Set{Symbol}()
    reason = ""
    while !isempty(remaining) && isempty(reason)
        index = findfirst(remaining) do spec
            all(name -> ready(name, selected, available, completed), spec.requires)
        end
        if isnothing(index)
            reason = "Cyclic plugin service dependencies"
        else
            spec = popat!(remaining, index)
            push!(ordered, spec)
            push!(completed, spec.name)
        end
    end
    (ok=isempty(reason), reason, ordered)
end

function ready(name::Symbol, selected, available, completed)
    provider = get(selected, name, nothing)
    isnothing(provider) ? name in available : provider in completed
end
function plugin_setup_result(result)
    successful = !hasproperty(result, :ok) || result.ok === true
    (ok=successful, reason=successful ? "" : explanation(result))
end

function explanation(result)
    if hasproperty(result, :reason)
        string(result.reason)
    elseif hasproperty(result, :text)
        string(result.text)
    elseif hasproperty(result, :error)
        sprint(show, result.error)
    else
        "Plugin setup failed"
    end
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
    installed.ok ? initialize!(context, spec) : installed
end

function initialize!(context::PluginContext, spec::PluginSpec)
    lock(context.kernel.lock) do
        owner = context.kernel.entries[context.owner]
        context.entry = owner
        for entry in owner.dependencies
            context.dependencies[entry.spec.name] = entry.spec.value
        end
    end
    result = plugin_setup_result(Base.invokelatest(spec.setup, context))
    result.ok ? validate(context) : result
end

function validate(context::PluginContext)
    absent = setdiff(context.selected, keys(context.provided))
    if !isempty(context.failure)
        (ok=false, reason=context.failure)
    elseif !isempty(absent)
        (ok=false, reason="Plugin $(context.name) did not provide: $(join(sort!(collect(absent)), ", "))")
    else
        (ok=true, reason="")
    end
end
function setup_profile!(kernel::Kernel, ordered, profile::Profile, selected)
    result = (ok=true, reason="")
    index = 1
    while index <= length(ordered) && result.ok
        result = setup_plugin!(kernel, ordered[index], profile, selected)
        index += 1
    end
    result
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
    profile = Profile(requested)
    catalog = profile_specs(host.registry, profile)
    catalog.ok ? prepare!(host, profile, catalog.specs) : (ok=false, reason=catalog.reason)
end

function prepare!(host::PluginHost, profile::Profile, specs)
    providers = profile_providers(specs, profile)
    providers.ok ? stage!(host, profile, specs, providers.selected) : (ok=false, reason=providers.reason)
end

struct Activation
    kernel::Kernel
    profile::Profile
    ordered::Vector{PluginSpec}
    selected::Dict{Symbol,Symbol}
    revision::UInt64
end

function stage!(host::PluginHost, profile::Profile, specs, selected)
    initial = lock(host.lock) do
        (revision=host.revision, kernel=host.closed ? nothing : fork_kernel(host.base))
    end
    stage!(host, initial.kernel, initial.revision, profile, specs, selected)
end

stage!(host::PluginHost, ::Nothing, revision, profile, specs, selected) = (ok=false, reason="Plugin host is closed")

function stage!(host::PluginHost, kernel::Kernel, revision, profile, specs, selected)
    order = profile_order(specs, selected, kernel)
    order.ok ? activate!(host, Activation(kernel, profile, order.ordered, selected, revision)) : discard_composition!(kernel, order.reason)
end

function activate!(host::PluginHost, activation::Activation)
    worker = spawn_scoped(() -> setup_profile!(activation.kernel, activation.ordered, activation.profile, activation.selected))
    wait(worker; throw=false)
    if istaskfailed(worker)
        discard_composition!(activation.kernel, sprint(showerror, TaskFailedException(worker)))
    else
        setup = fetch(worker)
        setup.ok ? commit!(host, activation) : discard_composition!(activation.kernel, setup.reason)
    end
end

function commit!(host::PluginHost, activation::Activation)
    previous = lock(host.lock) do
        host.closed || host.revision != activation.revision ? nothing : publish!(host, activation)
    end
    retire!(previous, activation)
end

function publish!(host::PluginHost, activation::Activation)
    previous = host.kernel
    host.kernel = activation.kernel
    host.profile = activation.profile
    host.active = [spec.name for spec in activation.ordered]
    host.revision += UInt64(1)
    previous
end

retire!(::Nothing, activation::Activation) = discard_composition!(activation.kernel, "Plugin composition changed during activation")

function retire!(previous::Kernel, activation::Activation)
    cleanup = close_composition!(previous)
    (ok=true, reason=isempty(cleanup) ? "" : "Previous profile cleanup failed: $cleanup")
end
"""Remove a plugin by staging the remaining profile and validating its service dependencies."""
function deactivate!(host::PluginHost, name::Symbol)
    profile = lock(() -> Profile(host.profile), host.lock)
    name in profile.plugins ? deactivate!(host, profile, name) : (ok=false, reason="Plugin $name is not selected")
end

function deactivate!(host::PluginHost, profile::Profile, name::Symbol)
    filter!(!=(name), profile.plugins)
    delete!(profile.config, name)
    filter!(pair -> last(pair) !== name, profile.bindings)
    activate!(host, profile)
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
    binding.available ? supervised(callback, binding) : nothing
end

function supervised(callback, binding::BoundComponent)
    worker = spawn_scoped(() -> plugin_value(Base.invokelatest(callback, binding.value)))
    wait(worker; throw=false)
    cleanup = spawn_cleanup(() -> release!(binding))
    wait(cleanup; throw=false)
    resolve(worker, [cleanup])
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
