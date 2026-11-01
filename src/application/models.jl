struct ModelSpec{M}
    provider::Symbol
    id::String
    api::String
    kind::Symbol
    metadata::M
end
ModelSpec(provider::Symbol, id::AbstractString; api="", kind=:chat, metadata=nothing) =
    ModelSpec(provider, String(id), String(api), Symbol(kind), metadata)

struct ProviderFactory{C,M,S}
    create::C
    models::M
    select::S
end
ProviderFactory(create; models=Returns(ModelSpec[]), select=Returns(nothing)) =
    ProviderFactory(create, models, select)
(factory::ProviderFactory)(directory) = Base.invokelatest(factory.create, directory)
instantiate_provider(factory::ProviderFactory, directory, model::AbstractString) =
    Base.invokelatest(factory.select, directory, model)

"""Return a provider-owned catalog without allowing one failing plugin to hide other providers."""
function catalog_models(factory::ProviderFactory)
    task = Task(() -> Base.invokelatest(factory.models))
    schedule(task)
    wait(task; throw=false)
    istaskfailed(task) && return ModelSpec[]
    models = fetch(task)
    return models isa AbstractVector{<:ModelSpec} ? copy(models) : ModelSpec[]
end
catalog_models(factory) = ModelSpec[]

"""Read last-known model metadata; catalog callbacks must not perform network or authentication work."""
function provider_models(registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY; provider=nothing, kind=:chat)
    descriptors = isnothing(provider) ? provider_descriptors(registry) :
        (provider_descriptor(registry, Symbol(provider)),)
    result = ModelSpec[]
    for descriptor in descriptors
        isnothing(descriptor) && continue
        if isnothing(provider) || descriptor.id == Symbol(provider)
            for model in catalog_models(descriptor.create)
                if kind == :all || model.kind == kind
                    push!(result, model)
                end
            end
        end
    end
    return result
end

"""Look up a model by provider, model id, and operation type."""
function provider_model(registry::ProviderRegistry, provider, id::AbstractString; kind=:chat)
    models = provider_models(registry; provider, kind)
    index = findfirst(model -> model.id == id, models)
    return isnothing(index) ? nothing : models[index]
end
"""Resolve one named provider's model without snapshotting unrelated provider descriptors."""
function provider_model(registry::ProviderRegistry, provider::Union{Symbol,AbstractString},
        id::AbstractString; kind=:chat)
    descriptor = provider_descriptor(registry, Symbol(provider))
    isnothing(descriptor) && return nothing
    for model in catalog_models(descriptor.create)
        if model.id == id && (kind == :all || model.kind == kind)
            return model
        end
    end
    return nothing
end

provider_model(provider, id::AbstractString; kwargs...) =
    provider_model(DEFAULT_PROVIDER_REGISTRY, provider, id; kwargs...)

struct ModelProvider{M,B}
    model::M
    backend::B
    label::String
end
ModelProvider(model::ModelSpec, backend; label=string(model.provider)) =
    ModelProvider(model, backend, String(label))
Base.show(io::IO, provider::ModelProvider) =
    print(io, "ModelProvider(", repr(provider.model.provider), ", ", repr(provider.model.id), ")")

"""Implement this method, or supply a callable backend, to own model protocol, auth, and streaming policy."""
respond_model(backend, model::ModelSpec, request::ModelRequest, context::ExecutionContext) =
    Base.invokelatest(backend, model, request, context)

function respond(provider::ModelProvider, request::ModelRequest, context::ExecutionContext)
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    return respond_model(provider.backend, provider.model, request, context)
end
function respond(provider::ModelProvider, messages, session::Session, context::ExecutionContext)
    request = model_request(operation_protocol(session.definition, provider), messages, session)
    return respond(provider, request, context)
end
(provider::ModelProvider)(messages, session) = call_provider(provider, messages, session)
provider_id(provider::ModelProvider) = provider.model.provider
provider_name(provider::ModelProvider) = provider.label
provider_detail(provider::ModelProvider) = "($(provider.model.provider)) $(provider.model.id)"

"""Select a model without changing a provider's authentication, transport, or protocol policy."""
select_model(provider, model::AbstractString) = nothing
select_model(provider::OpenRouterProvider, model::AbstractString) =
    OpenRouterProvider(provider.api_key, model, provider.transport; policy=provider.policy)
select_model(provider::CodexProvider, model::AbstractString) =
    CodexProvider(provider.executable; model, reasoning=provider.reasoning, policy=provider.policy)
select_model(provider::OpenAIProvider, model::AbstractString) =
    OpenAIProvider(provider.dir, String(model), provider.transport, provider.auth_transport,
        provider.policy, provider.catalog, provider.catalog_ttl)

function with_model_selection(descriptor::ProviderDescriptor)
    factory = ProviderFactory(descriptor.create;
        select=(directory, model) -> select_model(Base.invokelatest(descriptor.create, directory), model))
    return ProviderDescriptor(descriptor.id, descriptor.label, factory;
        auth=descriptor.auth, status=descriptor.status)
end

struct MemoryModelStore
    lock::ReentrantLock
    entries::Dict{Symbol,Any}
end
MemoryModelStore() = MemoryModelStore(ReentrantLock(), Dict{Symbol,Any}())

"""Read an isolated catalog snapshot; persistent stores may implement the same three operations."""
function read_model_catalog(store::MemoryModelStore, provider::Symbol)
    lock(store.lock) do
        return deepcopy(get(store.entries, provider, nothing))
    end
end

"""Publish a defensive copy, preserving opaque cache validators and provider metadata verbatim."""
function write_model_catalog!(store::MemoryModelStore, provider::Symbol, entry)
    lock(store.lock) do
        store.entries[provider] = deepcopy(entry)
    end
    return nothing
end

"""Remove only the selected provider's cached catalog."""
function delete_model_catalog!(store::MemoryModelStore, provider::Symbol)
    lock(store.lock) do
        delete!(store.entries, provider)
    end
    return nothing
end
