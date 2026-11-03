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
