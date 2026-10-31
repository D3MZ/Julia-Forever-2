struct ProviderDescriptor{F,A,S}
    id::Symbol
    label::String
    create::F
    auth::A
    status::S
end
ProviderDescriptor(id::Symbol, label::AbstractString, create; auth=nothing, status=Returns("")) =
    ProviderDescriptor(id, String(label), create, auth, status)

struct ProviderRegistry
    lock::ReentrantLock
    descriptors::Vector{ProviderDescriptor}
end
ProviderRegistry() = ProviderRegistry(ReentrantLock(), ProviderDescriptor[])
const DEFAULT_PROVIDER_REGISTRY = ProviderRegistry()
const PROVIDER_REGISTRY_LOCK = DEFAULT_PROVIDER_REGISTRY.lock
const PROVIDER_REGISTRY = DEFAULT_PROVIDER_REGISTRY.descriptors

"""Register a provider in an explicit catalog or in the compatibility default catalog."""
function register_provider!(registry::ProviderRegistry, descriptor::ProviderDescriptor)
    lock(registry.lock) do
        index = findfirst(item -> item.id == descriptor.id, registry.descriptors)
        if isnothing(index)
            push!(registry.descriptors, descriptor)
        else
            registry.descriptors[index] = descriptor
        end
    end
    return descriptor
end
register_provider!(descriptor::ProviderDescriptor) = register_provider!(DEFAULT_PROVIDER_REGISTRY, descriptor)

function unregister_provider!(registry::ProviderRegistry, id::Symbol)
    lock(registry.lock) do
        filter!(descriptor -> descriptor.id != id, registry.descriptors)
    end
    return nothing
end
unregister_provider!(id::Symbol) = unregister_provider!(DEFAULT_PROVIDER_REGISTRY, id)

provider_descriptors(registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY) =
    lock(() -> copy(registry.descriptors), registry.lock)

function provider_descriptor(registry::ProviderRegistry, id::Symbol)
    descriptors = provider_descriptors(registry)
    index = findfirst(descriptor -> descriptor.id == id, descriptors)
    return isnothing(index) ? nothing : descriptors[index]
end
provider_descriptor(id::Symbol) = provider_descriptor(DEFAULT_PROVIDER_REGISTRY, id)

function provider_from_name(id::Symbol; dir=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    descriptor = provider_descriptor(registry, id)
    return isnothing(descriptor) ? nothing : Base.invokelatest(descriptor.create, dir)
end
provider_from_name(name::AbstractString; kwargs...) = provider_from_name(Symbol(name); kwargs...)
