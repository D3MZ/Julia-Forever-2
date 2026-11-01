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
