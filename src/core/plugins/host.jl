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

