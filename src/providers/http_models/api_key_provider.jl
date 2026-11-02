"""Own replaceable API-key model metadata separately from private credential state."""
Base.@kwdef struct APIKeyProviderBuilder{P,T,O}
    id::Symbol
    label::String
    name::String
    catalog::Vector{ModelSpec}
    endpoint::String
    models_url::String
    protocol::P
    header::Symbol
    transport::T
    options::O
    paginate::Bool=false
end
(builder::APIKeyProviderBuilder)(directory)=api_key_build_model(builder,directory,first(builder.catalog).id)
api_key_build_model(builder::APIKeyProviderBuilder,directory,id)=api_key_model_provider(builder.catalog,builder.label,
    builder.endpoint,builder.protocol,builder.header,builder.transport,builder.options,directory,id)

"""Keep each implemented protocol's catalog and authentication contract paired."""
api_key_protocol_config(::OpenAIChatProtocol) = (api="openai-completions",header=:bearer)
api_key_protocol_config(::AnthropicMessagesProtocol) = (api="anthropic-messages",header=:anthropic)
api_key_protocol_config(protocol) = error("No implemented API key transport for this protocol")

"""Bind an implemented protocol, catalog and validator into a genuinely callable native provider."""
function api_key_provider_descriptor(id::Symbol,label::AbstractString;models::AbstractVector{<:ModelSpec},
        endpoint::AbstractString,models_url::AbstractString,protocol=OpenAIChatProtocol(),
        name=String(label)*" API key",transport=nothing,options=Dict{String,Any}(),paginate::Bool=false)
    config=api_key_protocol_config(protocol)
    valid=!isempty(models) && all(model->model.provider==id && model.kind==:chat && model.api==config.api,models)
    valid || error("API key registration requires a nonempty matching native chat catalog")
    catalog=deepcopy(models)
    header=config.header
    base=String(rstrip(endpoint,'/'))
    urls=[String(models_url),model_endpoint(protocol,base,first(catalog))]
    native=APIKeyHTTPTransport(;urls,pagination_urls=paginate ? [String(models_url)] : String[])
    all(url->api_key_endpoint_allowed(native,url),urls) || error("API key endpoints must be declared HTTPS URLs")
    wire=isnothing(transport) ? native : transport
    validator=APIKeyCatalogValidator(;provider=id,url=String(models_url),header,known_models=[model.id for model in catalog],transport=wire,paginate)
    auth=APIKeyAuthMethod(;provider=id,name=String(name),validate=validator)
    builder=APIKeyProviderBuilder(;id,label=String(label),name=String(name),catalog=ModelSpec[catalog...],endpoint=base,models_url=String(models_url),protocol,header,transport=wire,options,paginate)
    factory=ProviderFactory(builder;models=()->deepcopy(builder.catalog),select=(directory,model)->api_key_build_model(builder,directory,model))
    ProviderDescriptor(id,String(label),factory;auth,status=directory->api_key_provider_status(directory,id))
end

api_key_model_protocol(protocol::AnthropicMessagesProtocol,model::ModelSpec)=protocol
api_key_model_protocol(protocol::OpenAIChatProtocol,model::ModelSpec)=
    OpenAIChatProtocol(;compatibility=merge(deepcopy(protocol.compatibility),get(model_metadata(model),"compat",Dict{String,Any}())))
function api_key_model_provider(catalog,label,endpoint,protocol,header,transport,options,directory,id)
    index=findfirst(model->model.id==id,catalog)
    if isnothing(index)
        nothing
    else
        model=catalog[index]
        credentials=APIKeyCredentialResolver(;provider=model.provider,directory=String(directory),header)
        backend=HTTPModelBackend(api_key_model_protocol(protocol,model),endpoint;credentials,transport,options=deepcopy(options))
        ModelProvider(model,backend;label)
    end
end

"""Return a bounded app-owned credential under the same lock as replacement and logout."""
function api_key_credentials(directory::AbstractString,provider::Symbol)
    lock(auth_lock(directory,provider)) do
        revision=CredentialStorage.credential_revision(directory,provider)
        isnothing(revision) ? nothing : load_credentials(directory,provider)
    end
end
function api_key_saved(data)
    key=data isa AbstractDict ? get(data,"key",nothing) : nothing
    models=data isa AbstractDict ? get(data,"model_ids",nothing) : nothing
    validated=data isa AbstractDict ? get(data,"validated_at",nothing) : nothing
    data isa AbstractDict && get(data,"type",nothing)=="api_key" && key isa String &&
        0<sizeof(key)<=8192 && all(byte->0x21<=byte<=0x7e,codeunits(key)) &&
        validated isa Real && !(validated isa Bool) && isfinite(validated) && validated>0 &&
        models isa AbstractVector && !isempty(models) && all(id->id isa String && !isempty(id),models)
end
"""Observe credential readiness without propagating storage errors or private values into the UI."""
function api_key_observed_state(directory::AbstractString,provider::Symbol)
    task=Task(()->api_key_saved(api_key_credentials(directory,provider)))
    schedule(task)
    wait(task;throw=false)
    istaskfailed(task) ? :unavailable : fetch(task) ? :stored : :absent
end
api_key_provider_status(directory::AbstractString,provider::Symbol)=api_key_provider_status(Val(api_key_observed_state(directory,provider)))
api_key_provider_status(::Val{:stored})="stored API key; model catalog validated at sign-in"
api_key_provider_status(::Val{:absent})="API key sign-in required"
api_key_provider_status(::Val)= "Credential storage is unsafe or unavailable"

"""Refresh both public model rows and their actual factory/validator, never only decorative metadata."""
function install_model_catalog!(registry::ProviderRegistry,descriptor::ProviderDescriptor{<:ProviderFactory{<:APIKeyProviderBuilder}},catalog::AbstractVector{<:ModelSpec})
    builder=descriptor.create.create
    existing=builder.catalog
    preserved=ModelSpec[model for model in existing if !any(remote->remote.kind==model.kind && remote.id==model.id,catalog)]
    updated=vcat(preserved,catalog)
    supported=ModelSpec[model for model in updated if model.provider==builder.id && model.kind==:chat && model.api==first(existing).api]
    replacement=api_key_provider_descriptor(builder.id,builder.label;models=supported,endpoint=builder.endpoint,
        models_url=builder.models_url,protocol=builder.protocol,name=builder.name,transport=builder.transport,
        options=builder.options,paginate=builder.paginate)
    register_provider!(registry,replacement)
    nothing
end
