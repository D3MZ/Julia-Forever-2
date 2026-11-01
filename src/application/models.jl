using Downloads

struct ModelSpec{M}
    provider::Symbol
    id::String
    api::String
    kind::Symbol
    metadata::M
end
ModelSpec(provider::Symbol, id::AbstractString; api="", kind=:chat, metadata=nothing) = ModelSpec(provider, String(id), String(api), Symbol(kind), metadata)

Base.@kwdef struct ProviderFactory{C,M,S}
    create::C
    models::M = Returns(ModelSpec[])
    select::S = Returns(nothing)
end
ProviderFactory(create; kwargs...) = ProviderFactory(; create, kwargs...)
(factory::ProviderFactory)(directory) = Base.invokelatest(factory.create, directory)
instantiate_provider(factory::ProviderFactory, directory, model::AbstractString) = Base.invokelatest(factory.select, directory, model)

"""Return a provider-owned catalog without allowing one failing plugin to hide other providers."""
function catalog_models(factory::ProviderFactory)
    task = Task(() -> Base.invokelatest(factory.models))
    schedule(task)
    wait(task; throw=false)
    istaskfailed(task) ? ModelSpec[] : catalog(fetch(task))
end

catalog(models::AbstractVector{<:ModelSpec}) = copy(models)
catalog(value) = ModelSpec[]
catalog_models(factory) = ModelSpec[]

provider_catalog_descriptors(registry::ProviderRegistry, ::Nothing) = provider_descriptors(registry)
provider_catalog_descriptors(registry::ProviderRegistry, id::Symbol) = (provider_descriptor(registry, id),)
provider_catalog_descriptors(registry::ProviderRegistry, name::AbstractString) = provider_catalog_descriptors(registry, Symbol(name))

"""Filter model catalogs inside a dedicated iteration boundary."""
catalog_models_of_kind(descriptors, kind) = ModelSpec[
    model for descriptor in descriptors for model in models(descriptor)
    if kind == :all || model.kind == kind
]

"""Read last-known model metadata; catalog callbacks must not perform network or authentication work."""
provider_models(registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY; provider=nothing, kind=:chat) =
    catalog_models_of_kind(provider_catalog_descriptors(registry, provider), kind)

models(::Nothing) = ModelSpec[]
models(descriptor::ProviderDescriptor) = catalog_models(descriptor.create)
"""Look up a model by provider, model id, and operation type."""
function provider_model(registry::ProviderRegistry, provider, id::AbstractString; kind=:chat)
    models = provider_models(registry; provider, kind)
    index = findfirst(model -> model.id == id, models)
    return isnothing(index) ? nothing : models[index]
end
"""Resolve one named provider's model without snapshotting unrelated provider descriptors."""
provider_model(registry::ProviderRegistry, provider::Symbol, id::AbstractString; kind=:chat) = model(provider_descriptor(registry, provider), id, kind)
provider_model(registry::ProviderRegistry, name::AbstractString, id::AbstractString; kind=:chat) = provider_model(registry, Symbol(name), id; kind)
model(::Nothing, id::AbstractString, kind) = nothing

function model(descriptor::ProviderDescriptor, id::AbstractString, kind)
    catalog = catalog_models(descriptor.create)
    index = findfirst(item -> item.id == id && (kind == :all || item.kind == kind), catalog)
    isnothing(index) ? nothing : catalog[index]
end

provider_model(provider, id::AbstractString; kwargs...) = provider_model(DEFAULT_PROVIDER_REGISTRY, provider, id; kwargs...)

struct ModelProvider{M,B}
    model::M
    backend::B
    label::String
end
ModelProvider(model::ModelSpec, backend; label=string(model.provider)) = ModelProvider(model, backend, String(label))
Base.show(io::IO, provider::ModelProvider) = print(io, "ModelProvider(", repr(provider.model.provider), ", ", repr(provider.model.id), ")")

"""Implement this method, or supply a callable backend, to own model protocol, auth, and streaming policy."""
respond_model(backend, model::ModelSpec, request::ModelRequest, context::ExecutionContext) = Base.invokelatest(backend, model, request, context)

respond(provider::ModelProvider, request::ModelRequest, context::ExecutionContext) = cancelled(context) ? provider_failure("Request cancelled or timed out.") : respond_model(provider.backend, provider.model, request, context)
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
select_model(provider::OpenRouterProvider, model::AbstractString) = OpenRouterProvider(provider, model)
select_model(provider::CodexProvider, model::AbstractString) = CodexProvider(provider, model)
select_model(provider::OpenAIProvider, model::AbstractString) = OpenAIProvider(provider, model)

ProviderFactory(descriptor::ProviderDescriptor) = ProviderFactory(descriptor.create; select=(directory, model) -> select_model(Base.invokelatest(descriptor.create, directory), model))
ProviderDescriptor(descriptor::ProviderDescriptor, factory::ProviderFactory) = ProviderDescriptor(descriptor.id, descriptor.label, factory; auth=descriptor.auth, status=descriptor.status)
with_model_selection(descriptor::ProviderDescriptor) = ProviderDescriptor(descriptor, ProviderFactory(descriptor))
Base.@kwdef struct MemoryModelStore
    lock::ReentrantLock = ReentrantLock()
    entries::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

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


"""Accept only positive, representable model limits; unknown metadata is not guessed."""
model_limit(value) = nothing
model_limit(value::Bool) = nothing
model_limit(value::Integer) = 0 < value <= typemax(Int) ? Int(value) : nothing
model_limit(metadata::AbstractDict, key::String) = model_limit(get(metadata, key, nothing))
model_limit(metadata, key::String) = nothing
model_context_window(model::ModelSpec) = model_limit(model.metadata, "contextWindow")
model_output_limit(model::ModelSpec) = model_limit(model.metadata, "maxTokens")
model_context_window(provider::ModelProvider) = model_context_window(provider.model)
model_output_limit(provider::ModelProvider) = model_output_limit(provider.model)

"""Resolve a selected model's cached metadata without requiring a network request."""
selected_model(provider) = hasproperty(provider, :model) &&
    getproperty(provider, :model) isa ModelSpec ? getproperty(provider, :model) : nothing
selected_model(provider::ModelProvider) = provider.model
selected_model(provider::OpenRouterProvider) = provider_model(:openrouter, provider.model)
selected_model(provider::CodexProvider) = provider_model(:codex, provider.model)
selected_model(provider::OpenAIProvider) = isempty(provider.model) ?
    nothing : provider_model(:chatgpt, provider.model)

model_context_window(provider) = model_context_window(selected_model(provider))
model_context_window(::Nothing) = nothing
model_output_limit(provider) = model_output_limit(selected_model(provider))
model_output_limit(::Nothing) = nothing

"""Explicitly refresh a named provider's metadata; invalid catalogs do not replace a good cache."""
function refresh_pi_model_catalog!(registry::ProviderRegistry, provider::Symbol; fetcher=fetch_pi_catalog)
    descriptor = provider_descriptor(registry, provider)
    if isnothing(descriptor)
        (ok=false, reason="Unknown provider", count=0)
    else
        url = "https://pi.dev/api/models/providers/" * String(provider)
        catalog = pi_model_catalog(Base.invokelatest(fetcher, url), provider)
        if isnothing(catalog)
            (ok=false, reason="Invalid model catalog", count=0)
        elseif !(descriptor.create isa ProviderFactory)
            (ok=false, reason="Provider has no model factory", count=0)
        else
            factory = descriptor.create
            replacement = ProviderFactory(factory.create;
                models=() -> copy(catalog), select=factory.select)
            register_provider!(registry, ProviderDescriptor(descriptor, replacement))
            (ok=true, reason="", count=length(catalog))
        end
    end
end
refresh_pi_model_catalog!(provider::Symbol; kwargs...) =
    refresh_pi_model_catalog!(DEFAULT_PROVIDER_REGISTRY, provider; kwargs...)

function fetch_pi_catalog(url::AbstractString)
    output = IOBuffer()
    response = Downloads.request(url; output, timeout=15, throw=false)
    response isa Downloads.Response && response.status == 200 ? String(take!(output)) : ""
end

pi_catalog_rows(data::AbstractVector) = data
pi_catalog_rows(data::AbstractDict) =
    haskey(data, "models") ? pi_catalog_rows(data["models"]) : pi_catalog_map(data)
pi_catalog_rows(data) = nothing

"""Accept both Pi's id-keyed model catalogs and the array-shaped model list."""
function pi_catalog_map(data::AbstractDict)
    all(value -> value isa AbstractDict, values(data)) ?
        [merge(Dict{String,Any}("id" => String(id)), entry)
            for (id, entry) in data if id isa AbstractString] : nothing
end

pi_catalog_entry(provider, entry) = nothing
function pi_catalog_entry(provider::Symbol, entry::AbstractDict)
    id = get(entry, "id", nothing)
    api = get(entry, "api", "")
    model_type = get(entry, "type", "chat")
    valid_limits = all(name -> !haskey(entry, name) ||
        !isnothing(model_limit(entry, name)), ("contextWindow", "maxTokens"))
    if id isa AbstractString && !isempty(id) && api isa AbstractString &&
            model_type isa AbstractString && valid_limits
        ModelSpec(provider, String(id); api, kind=Symbol(model_type),
            metadata=deepcopy(entry))
    else
        nothing
    end
end

function pi_model_catalog(text::AbstractString, provider::Symbol)
    rows = pi_catalog_rows(parse_json(text))
    if isnothing(rows)
        nothing
    else
        models = [pi_catalog_entry(provider, row) for row in rows]
        isempty(models) || any(isnothing, models) ?
            nothing : ModelSpec[model for model in models]
    end
end
pi_model_catalog(data, provider::Symbol) = nothing
