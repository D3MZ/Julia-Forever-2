# Native validated model/thinking preparation. No persistence or kernel mutations.
public prepare_model_configuration, current_thinking_level, provider_model_identity
public model_supported_thinking_levels, model_clamp_thinking_level, ConfiguredModelProvider

const MODEL_THINKING_LEVELS=("off","minimal","low","medium","high","xhigh","max")

"""Retain the exact selected catalog record and actual configured native backend."""
struct ConfiguredModelProvider{P,M}
    backend::P
    model::M
    thinking_level::String
end
Base.show(io::IO,provider::ConfiguredModelProvider)=print(io,"ConfiguredModelProvider(",repr(provider.model.provider),", ",repr(provider.model.id),", ",repr(provider.thinking_level),")")
provider_id(provider::ConfiguredModelProvider)=provider.model.provider
provider_name(provider::ConfiguredModelProvider)=provider_name(provider.backend)
provider_detail(provider::ConfiguredModelProvider)="($(provider.model.provider)) $(provider.model.id) • $(provider.thinking_level)"
provider_protocol(provider::ConfiguredModelProvider)=provider_protocol(provider.backend)
selected_model(provider::ConfiguredModelProvider)=provider.model
model_context_window(provider::ConfiguredModelProvider)=model_context_window(provider.model)
model_output_limit(provider::ConfiguredModelProvider)=model_output_limit(provider.model)
respond(provider::ConfiguredModelProvider,request::ModelRequest,context::ExecutionContext)=respond(provider.backend,request,context)
respond(provider::ConfiguredModelProvider,messages,session::Session,context::ExecutionContext)=legacy_provider_response(provider,messages,session,context)
(provider::ConfiguredModelProvider)(messages,session)=call_provider(provider,messages,session)

configuration_backend(provider)=provider
configuration_backend(provider::ConfiguredModelProvider)=provider.backend
current_thinking_level(provider)=nothing
current_thinking_level(provider::ConfiguredModelProvider)=provider.thinking_level
current_thinking_level(provider::CodexProvider)=provider.reasoning=="none" ? "off" : provider.reasoning
current_thinking_level(provider::Union{OpenAIProvider,OpenRouterProvider})=provider.reasoning=="none" ? "off" : provider.reasoning
provider_model_identity(provider)=(provider_id=provider_id(provider),model_id="")
provider_model_identity(provider::ConfiguredModelProvider)=(provider_id=provider.model.provider,model_id=provider.model.id)
provider_model_identity(provider::ModelProvider)=(provider_id=provider.model.provider,model_id=provider.model.id)
provider_model_identity(provider::Union{CodexProvider,OpenRouterProvider})=(provider_id=provider_id(provider),model_id=provider.model)
function provider_model_identity(provider::OpenAIProvider)
    selected=isempty(provider.model) ? lock(()->provider.catalog.selected_model,provider.catalog.lock) : provider.model
    (provider_id=:chatgpt,model_id=selected)
end

"""Return supported semantic levels from the selected record, not a provider-name heuristic."""
function model_supported_thinking_levels(model::ModelSpec)
    metadata=model_metadata(model)
    mapping=get(metadata,"thinkingLevelMap",Dict{String,Any}())
    if get(metadata,"reasoning",false)!==true
        ["off"]
    elseif mapping isa AbstractDict
        [level for level in MODEL_THINKING_LEVELS if get(mapping,level,missing)!==nothing && (!(level in ("xhigh","max")) || haskey(mapping,level))]
    else
        String[]
    end
end

"""Clamp with the reference's nearest-higher-then-lower preference when explicitly requested."""
function model_clamp_thinking_level(model::ModelSpec,level::AbstractString)
    supported=model_supported_thinking_levels(model)
    index=findfirst(==(level),MODEL_THINKING_LEVELS)
    options=isnothing(index) ? supported : [MODEL_THINKING_LEVELS[index:end]...;reverse(MODEL_THINKING_LEVELS[1:index-1])...]
    chosen=findfirst(item->item in supported,options)
    isnothing(chosen) ? "off" : options[chosen]
end

model_reasoning(model::ModelSpec)=get(model_metadata(model),"reasoning",false)===true
function model_wire_thinking(model::ModelSpec,level::String;off="none")
    metadata=model_metadata(model)
    mapping=get(metadata,"thinkingLevelMap",Dict{String,Any}())
    model_reasoning(model) ? get(mapping,level,level=="off" ? off : level) : nothing
end

configuration_failure(reason::AbstractString)=(ok=false,reason=String(reason),provider=nothing,model=nothing,thinking_level=nothing)
configuration_success(provider,model,level)=(ok=true,reason="",provider,model,thinking_level=String(level))
configuration_provider_id(current,id)=nothing
configuration_provider_id(current,id::Symbol)=id
function configuration_provider_id(current,::Val{:openai_codex_alias})
    active=provider_id(current)
    active in (:chatgpt,:codex,Symbol("openai-codex")) ? active : nothing
end
configuration_provider_id(current,id::AbstractString)=configuration_provider_id(current,Symbol(id))
resolved_configuration_provider(current,id)=id==Symbol("openai-codex") || id=="openai-codex" ? configuration_provider_id(current,Val(:openai_codex_alias)) : configuration_provider_id(current,id)

"""Build an isolated validated candidate; the caller separately installs and persists it."""
function prepare_model_configuration(current,registry::ProviderRegistry;provider_id,model_id::AbstractString,thinking_level=nothing,directory::AbstractString=config_dir(),allow_provider_change::Bool=false)
    id=resolved_configuration_provider(current,provider_id)
    if isnothing(id)
        configuration_failure("Ambiguous subscription alias; choose ChatGPT direct or Codex CLI explicitly.")
    elseif id!=JuliaForever2.provider_id(current) && !allow_provider_change
        configuration_failure("Changing provider requires an explicit provider selection.")
    else
        models=configuration_cached_models(provider_descriptor(registry,id))
        index=findfirst(model->model.id==model_id,models)
        model=isnothing(index) ? nothing : models[index]
        prepare_validated_configuration(current,registry,id,model,thinking_level,directory)
    end
end
configuration_cached_models(::Nothing)=ModelSpec[]
configuration_cached_models(descriptor::ProviderDescriptor)=configuration_cached_models(catalog_models(descriptor.create))
configuration_cached_models(models::AbstractVector)=ModelSpec[model for model in models if model isa ModelSpec && model.kind==:chat]
configuration_cached_models(models)=ModelSpec[]

prepare_validated_configuration(current,registry,id,::Nothing,level,directory)=configuration_failure("Model is absent from the configured provider's current catalog.")
function prepare_validated_configuration(current,registry,id,model::ModelSpec,requested,directory)
    model=ModelSpec(model.provider,model.id;api=model.api,kind=model.kind,metadata=deepcopy(model.metadata))
    previous=current_thinking_level(current)
    level=isnothing(requested) ? model_clamp_thinking_level(model,isnothing(previous) ? "medium" : previous) : requested
    if !(level isa AbstractString) || !(level in model_supported_thinking_levels(model))
        configuration_failure("Thinking level '$level' is not supported by this model.")
    else
        level=String(level)
        backend=configuration_backend(current)
        selected=id==provider_id(current) ? configuration_select(backend,model) : provider_from_name(id;dir=directory,registry,model=model.id)
        if isnothing(selected)
            configuration_failure("Provider cannot prepare the selected model.")
        elseif provider_id(selected)!=id
            configuration_failure("Provider factory returned a different provider identity.")
        else
            configured=configure_model_thinking(selected,model,level)
            if isnothing(configured)
                configuration_failure("This backend has no verified thinking configuration adapter for the selected model.")
            else
                configuration_success(ConfiguredModelProvider(configured,model,level),model,level)
            end
        end
    end
end
configuration_select(provider,model::ModelSpec)=select_model(provider,model.id)
configuration_select(provider::ModelProvider,model::ModelSpec)=ModelProvider(model,provider.backend;label=provider.label)
configure_model_thinking(provider,model::ModelSpec,level::String)=nothing
function configure_model_thinking(provider::OpenAIProvider,model::ModelSpec,level::String)
    effort=model_wire_thinking(model,level)
    effort isa Union{Nothing,String} ? OpenAIProvider(provider.dir,model.id,provider.transport,provider.auth_transport,provider.policy,provider.catalog,provider.catalog_ttl,effort,level=="off" ? nothing : "auto") : nothing
end
function configure_model_thinking(provider::OpenRouterProvider,model::ModelSpec,level::String)
    effort=model_wire_thinking(model,level)
    effort isa Union{Nothing,String} ? OpenRouterProvider(provider.api_key,model.id,provider.transport,provider.policy,effort) : nothing
end
function configure_model_thinking(provider::CodexProvider,model::ModelSpec,level::String)
    effort=model_wire_thinking(model,level)
    reasoning=isnothing(effort) ? "none" : effort
    reasoning isa String ? CodexProvider(provider.executable;model=model.id,reasoning,policy=provider.policy) : nothing
end

"""Compose new protocol options without changing credential, transport or original option ownership."""
struct ConfiguredModelOptions{O,F}
    original::O
    fields::F
end
function (options::ConfiguredModelOptions)(model,request)
    base=deepcopy(model_request_options(options.original,model,request))
    if base isa AbstractDict
        fields=configuration_runtime_fields(options.fields,base)
        for name in ("reasoningEffort","reasoning","thinking","outputConfig")
            previous=pop!(base,name,nothing)
            replacement=get(fields,name,nothing)
            if previous isa AbstractDict && replacement isa AbstractDict
                if name=="thinking"
                    pop!(previous,"type",nothing)
                    pop!(previous,"budget_tokens",nothing)
                end
                fields[name]=merge(previous,replacement)
            end
        end
        merge!(base,fields)
    else
        base
    end
end

function configure_model_thinking(provider::ModelProvider,model::ModelSpec,level::String)
    backend=configure_model_backend(provider.backend,model,level)
    isnothing(backend) ? nothing : ModelProvider(model,backend;label=provider.label)
end
configure_model_backend(backend,model::ModelSpec,level::String)=nothing
configuration_base_options(options)=options
configuration_base_options(options::ConfiguredModelOptions)=configuration_base_options(options.original)
function configure_model_backend(backend::HTTPModelBackend,model::ModelSpec,level::String)
    fields=configuration_thinking_fields(backend.protocol,model,level)
    isnothing(fields) ? nothing : HTTPModelBackend(backend.protocol,backend.endpoint,backend.credentials,backend.transport,ConfiguredModelOptions(configuration_base_options(backend.options),fields))
end
configuration_thinking_fields(protocol,model::ModelSpec,level::String)=nothing
function configuration_thinking_fields(protocol::OpenAIChatProtocol,model::ModelSpec,level::String)
    compatibility=protocol.compatibility
    format=get(compatibility,"thinkingFormat","openai")
    effort=model_wire_thinking(model,level;off=nothing)
    if !model_reasoning(model)
        Dict{String,Any}()
    elseif !isnothing(effort) && !(effort isa AbstractString)
        nothing
    elseif format=="openai" && get(compatibility,"supportsReasoningEffort",true)
        isnothing(effort) ? Dict{String,Any}() : Dict{String,Any}("reasoningEffort"=>effort)
    elseif format=="openrouter"
        mapped=model_wire_thinking(model,level)
        isnothing(mapped) ? Dict{String,Any}() : Dict{String,Any}("reasoning"=>Dict("effort"=>mapped))
    else
        nothing
    end
end

function provider_footer_status(provider::ConfiguredModelProvider)
    original=provider_footer_status(provider.backend)
    (provider=string(provider.model.provider),model=provider.model.id,thinking=provider.thinking_level,
        context_window=model_context_window(provider.model),subscription=original.subscription)
end

"""Derive per-request Anthropic limits without changing the original options object."""
struct AnthropicThinkingOptions{M}
    model::M
    level::String
end
configuration_runtime_fields(fields,options)=deepcopy(fields)
function configuration_runtime_fields(fields::AnthropicThinkingOptions,options::AbstractDict)
    model,level=fields.model,fields.level
    metadata=model_metadata(model)
    compatibility=get(metadata,"compat",Dict{String,Any}())
    if !model_reasoning(model)
        Dict{String,Any}()
    elseif level=="off"
        Dict{String,Any}("thinking"=>Dict("type"=>"disabled"))
    elseif get(compatibility,"forceAdaptiveThinking",false)===true
        mapping=get(metadata,"thinkingLevelMap",Dict{String,Any}())
        mapped=get(mapping,level,nothing)
        effort=mapped isa AbstractString ? String(mapped) : level in ("minimal","low") ? "low" : level=="medium" ? "medium" : "high"
        Dict{String,Any}("thinking"=>Dict("type"=>"adaptive","display"=>"summarized"),"outputConfig"=>Dict("effort"=>effort))
    else
        budget=level=="minimal" ? 1024 : level=="low" ? 2048 : level=="medium" ? 8192 : 16384
        cap=model_output_limit(model)::Int
        requested=get(options,"maxTokens",nothing)
        ceiling=isnothing(requested) ? cap : min(requested+budget,cap)
        Dict{String,Any}("maxTokens"=>ceiling,"thinking"=>Dict("type"=>"enabled","budget_tokens"=>min(budget,max(0,ceiling-1024)),"display"=>"summarized"))
    end
end
function configuration_thinking_fields(::AnthropicMessagesProtocol,model::ModelSpec,level::String)
    compatibility=get(model_metadata(model),"compat",Dict{String,Any}())
    supported=!model_reasoning(model) || level=="off" || get(compatibility,"forceAdaptiveThinking",false)===true || !isnothing(model_output_limit(model))
    supported ? AnthropicThinkingOptions(model,level) : nothing
end
