"""Recognize actual provider effort, never a heuristic from the displayed thinking label."""
anthropic_effort(value)=value isa String && value in ("low","medium","high","xhigh","max")
anthropic_compat(model::ModelSpec)=get(model_metadata(model),"compat",Dict{String,Any}())
function anthropic_managed_effort(model::ModelSpec,options)
    thinking=get(options,"thinking",nothing)
    disabled=thinking isa AbstractDict && get(thinking,"type",nothing)=="disabled"
    get(anthropic_compat(model),"supportsMidConvoEffort",false)===true && !disabled
end
function anthropic_active_effort(options)
    configured=get(options,"outputConfig",nothing)
    level=configured isa AbstractDict ? get(configured,"effort",nothing) : nothing
    anthropic_effort(level) ? level : "high"
end
anthropic_message_context(message)=nothing
anthropic_message_context(message::AbstractDict)=message
anthropic_message_context(message::Message)=provider_message_context(message.metadata)
function anthropic_previous_effort(message,model)
    data=anthropic_message_context(message)
    level=data isa AbstractDict ? get(data,"providerThinkingLevel",nothing) : nothing
    same=data isa AbstractDict && get(data,"api",nothing)=="anthropic-messages" && get(data,"provider",nothing)==String(model.provider)
    same && anthropic_effort(level) ? level : nothing
end
anthropic_effort_marker(level)=Dict{String,Any}("role"=>"system","content"=>Any[],"output_config"=>Dict("effort"=>level))
function anthropic_context_messages(model,request,options)
    messages=Dict{String,Any}[]
    managed=anthropic_managed_effort(model,options)
    for message in request.messages
        if anthropic_sendable(message)
            wire=anthropic_wire_message(message)
            if !anthropic_empty_assistant(wire)
                previous=managed && get(wire,"role",nothing)=="assistant" ? anthropic_previous_effort(message,model) : nothing
                isnothing(previous) || push!(messages,anthropic_effort_marker(previous))
                push!(messages,wire)
            end
        end
    end
    managed && push!(messages,anthropic_effort_marker(anthropic_active_effort(options)))
    messages
end
function anthropic_managed_payload!(payload,model,options)
    compat=anthropic_compat(model)
    if anthropic_managed_effort(model,options)
        thinking=get(options,"thinking",nothing)
        display=thinking isa AbstractDict ? get(thinking,"display","summarized") : "summarized"
        payload["thinking"]=Dict("type"=>"adaptive","display"=>display,"block_binding"=>Dict("prefix_mismatch_behavior"=>"drop_block"))
        payload["output_config"]=Dict("effort"=>"low")
    end
    thinking=get(payload,"thinking",nothing)
    active=thinking isa AbstractDict && get(thinking,"type",nothing)!="disabled"
    if get(compat,"supportsTemperature",true)!==true || get(compat,"supportsMidConvoEffort",false)===true || active
        pop!(payload,"temperature",nothing)
    end
    fallbacks=get(compat,"allowedFallbackModels",nothing)
    if fallbacks isa AbstractVector && !isempty(fallbacks)
        payload["fallbacks"]=[Dict("model"=>row["model"]) for row in fallbacks if row isa AbstractDict && get(row,"model",nothing) isa String]
    end
    nothing
end
function anthropic_beta_features(model,options,request)
    compat=anthropic_compat(model)
    features=String[]
    thinking=get(options,"thinking",nothing)
    active=thinking isa AbstractDict && get(thinking,"type",nothing) in ("enabled","adaptive")
    active && get(compat,"forceAdaptiveThinking",false)!==true && push!(features,"interleaved-thinking-2025-05-14")
    fallbacks=get(compat,"allowedFallbackModels",nothing)
    fallbacks isa AbstractVector && !isempty(fallbacks) && push!(features,"server-side-fallback-2026-07-01")
    if get(compat,"supportsMidConvoEffort",false)===true
        append!(features,["mid-conversation-output-config-2026-07-01","thinking-binding-controls-2026-08-01"])
    end
    features
end
function model_protocol_headers(protocol::AnthropicMessagesProtocol,model,options,request)
    headers=model_protocol_headers(protocol)
    beta=anthropic_beta_features(model,options,request)
    isempty(beta) || push!(headers,"anthropic-beta"=>join(beta,','))
    headers
end
function prepare_protocol_state!(::AnthropicMessagesProtocol,state,payload,options)
    if anthropic_managed_effort(state.model,options)
        state.message["providerThinkingLevel"]=anthropic_active_effort(options)
    end
    nothing
end
function response_context_message(message::Message,response::StreamedCompletion)
    data=response.message
    level=data isa AbstractDict ? get(data,"providerThinkingLevel",nothing) : nothing
    if message.role==:assistant && data isa AbstractDict && get(data,"api",nothing)=="anthropic-messages" &&
            get(data,"provider",nothing) isa String && anthropic_effort(level)
        original=message.metadata isa ProviderMessageMetadata ? message.metadata.original : message.metadata
        metadata=ProviderMessageMetadata(original,Dict{String,Any}("api"=>data["api"],"provider"=>data["provider"],"providerThinkingLevel"=>level))
        Message(message.role,message.content,message.kind;metadata)
    else
        message
    end
end

function anthropic_empty_assistant(wire::AbstractDict)
    content=get(wire,"content",nothing)
    get(wire,"role",nothing)=="assistant" && content isa AbstractVector &&
        all(block->block isa AbstractDict && get(block,"type",nothing)=="text" && isempty(strip(get(block,"text",""))),content)
end
