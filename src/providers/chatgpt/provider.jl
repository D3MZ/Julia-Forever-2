using JSON

openai_request(url, method, body, headers, context::ExecutionContext=ExecutionContext(), sink=nothing) = http_request(url, method, body, headers, context; timeout=Inf, sink, idle_timeout_ms=HTTPTransport.http_idle_timeout_ms())

Base.@kwdef mutable struct ModelCatalog
    lock::ReentrantLock = ReentrantLock()
    models::Vector{String} = String[]
    expires_at::Float64 = 0.0
    selected_model::String = ""
end

struct OpenAIProvider{F,G,P}
    dir::String
    model::String
    transport::F
    auth_transport::G
    policy::P
    catalog::ModelCatalog
    catalog_ttl::Float64
    reasoning::Union{Nothing,String}
    reasoning_summary::Union{Nothing,String}
end
OpenAIProvider(dir::AbstractString=config_dir(), transport=openai_request, auth_transport=auth_request; model=get(ENV, "CHATGPT_MODEL", ""), policy=CodeModePolicy(), catalog_ttl=300.0, reasoning=nothing,reasoning_summary=isnothing(reasoning) || reasoning=="none" ? nothing : "auto") = OpenAIProvider(String(dir), String(model), transport, auth_transport, policy, ModelCatalog(), Float64(catalog_ttl), isnothing(reasoning) ? nothing : String(reasoning),isnothing(reasoning_summary) ? nothing : String(reasoning_summary))
OpenAIProvider(provider::OpenAIProvider, model::AbstractString) = OpenAIProvider(provider.dir, String(model),
    provider.transport, provider.auth_transport, provider.policy, provider.catalog, provider.catalog_ttl, provider.reasoning,provider.reasoning_summary)
OpenAIProvider(dir::String,model::String,transport,auth_transport,policy,catalog::ModelCatalog,catalog_ttl::Float64) =
    OpenAIProvider(dir,model,transport,auth_transport,policy,catalog,catalog_ttl,nothing,nothing)
OpenAIProvider(dir::String,model::String,transport,auth_transport,policy,catalog::ModelCatalog,catalog_ttl::Float64,reasoning::Union{Nothing,String}) =
    OpenAIProvider(dir,model,transport,auth_transport,policy,catalog,catalog_ttl,reasoning,isnothing(reasoning) || reasoning=="none" ? nothing : "auto")

"""Construct the subscription request without changing authentication or transport."""
function chatgpt_request_payload(provider::OpenAIProvider,request::ModelRequest,model::AbstractString)
    conversation=conversation_messages(request.messages,request.instructions;system_role="developer")
    payload=Dict{String,Any}("model"=>model,"input"=>conversation,"store"=>false,"stream"=>true,"text"=>Dict("format"=>request.response_format))
    reasoning=provider.reasoning
    if !isnothing(reasoning)
        payload["reasoning"]=Dict("effort"=>reasoning)
        summary=provider.reasoning_summary
        if !isnothing(summary)
            payload["reasoning"]["summary"]=summary
        end
    end
    model_image_payload(Val(:responses),payload)
end

(provider::OpenAIProvider)(messages, session) = call_provider(provider, messages, session)

function available_models!(provider::OpenAIProvider, headers, context)
    cached = lock(provider.catalog.lock) do
        time() < provider.catalog.expires_at ? provider.catalog.models : nothing
    end
    isnothing(cached) ? discover!(provider, headers, context) : (models=cached, reason="")
end

function discover!(provider::OpenAIProvider, headers, context)
    response = transport_request(provider.transport, OPENAI_RESOURCE * "/models", "GET", "", headers, context)
    200 <= response.status < 300 ? discover!(provider, parse_json(response.body)) : (models=String[], reason=transport_reason(response, "ChatGPT model discovery"))
end

discover!(provider::OpenAIProvider, data) = (models=String[], reason="ChatGPT model discovery returned invalid JSON.")
function discover!(provider::OpenAIProvider,data::AbstractDict)
    if haskey(data,"data") && data["data"] isa AbstractVector
        modern=data["data"]
        valid=all(model->model isa AbstractDict && get(model,"id",nothing) isa AbstractString && !isempty(model["id"]),modern)
        valid ? cache_discovered_models!(provider,unique(String[model["id"] for model in modern])) : (models=String[],reason="ChatGPT model discovery returned invalid model records.")
    elseif haskey(data,"models") && data["models"] isa AbstractVector
        discover!(provider,data["models"])
    else
        (models=String[],reason="ChatGPT model discovery returned invalid JSON.")
    end
end

function discover!(provider::OpenAIProvider,models::AbstractVector)
    discovered=String[model["slug"] for model in models if model isa AbstractDict && get(model,"visibility","")=="list" && get(model,"slug",nothing) isa AbstractString && !isempty(model["slug"])]
    cache_discovered_models!(provider,unique(discovered))
end
function cache_discovered_models!(provider::OpenAIProvider,discovered::Vector{String})
    lock(provider.catalog.lock) do
        if time()>=provider.catalog.expires_at
            provider.catalog.models=discovered
            provider.catalog.expires_at=time()+provider.catalog_ttl
        end
        (models=copy(provider.catalog.models),reason="")
    end
end

mutable struct ChatGPTStream{C,P}
    context::C
    policy::P
    text::IOBuffer
    completed::Bool
    failed::Bool
    usage::UsageReport
    progress_interval::Float64
    last_progress::Float64
end
ChatGPTStream(context, policy=CodeModePolicy(); progress_interval=1 / 30) = ChatGPTStream(context, policy, IOBuffer(), false, false, UsageReport(), Float64(progress_interval), -Inf)

"""Coalesce semantic previews while preserving the complete response buffer."""
function publish_progress!(stream::ChatGPTStream; force=false)
    now = monotonic_seconds()
    if force || now - stream.last_progress >= stream.progress_interval
        seekstart(stream.text)
        text = read(stream.text, String)
        emit_protocol_progress!(stream.policy, text, stream.context)
        stream.last_progress = now
    end
    return nothing
end


(stream::ChatGPTStream)(event) = consume!(stream, event.data == "[DONE]" ? nothing : parse_json(event.data), event.event)
consume!(stream::ChatGPTStream, data, event) = nothing

function consume!(stream::ChatGPTStream, data::AbstractDict, event)
    kind = get(data, "type", event)
    if kind == "response.output_text.delta"
        delta = get(data, "delta", "")
        print(stream.text, delta)
        emit!(stream.context, HarnessEvent(:provider_delta, delta))
        publish_progress!(stream)
    elseif kind == "response.completed"
        stream.completed = true
        stream.usage = normalize_usage(get(get(data, "response", Dict()), "usage", nothing))
        publish_progress!(stream; force=true)
    elseif kind in ("response.failed", "response.incomplete", "error")
        stream.failed = true
    end
    nothing
end

respond(provider::OpenAIProvider, request::ModelRequest, context::ExecutionContext) = cancelled(context) ? provider_failure("Request cancelled or timed out.") : authenticate(provider, request, context)

function authenticate(provider::OpenAIProvider, request::ModelRequest, context)
    refreshed = refresh_chatgpt!(provider.dir; transport=provider.auth_transport, context)
    if refreshed.ok
        headers = ["Authorization" => "Bearer $(refreshed.credentials["access_token"])", "Content-Type" => "application/json"]
        select(provider, request, context, headers, available_models!(provider, headers, context))
    else
        provider_failure(refreshed.reason)
    end
end

function select(provider::OpenAIProvider, request, context, headers, catalog)
    if !isempty(catalog.reason)
        provider_failure(catalog.reason)
    elseif isempty(catalog.models)
        provider_failure("No ChatGPT models are available for this account.")
    else
        model = isempty(provider.model) ? first(catalog.models) : provider.model
        if model in catalog.models
            lock(provider.catalog.lock) do
                provider.catalog.selected_model = model
            end
            respond(provider, request, context, headers, model)
        else
            provider_failure("The configured ChatGPT model is not available for this account.")
        end
    end
end

function respond(provider::OpenAIProvider, request::ModelRequest, context, headers, model)
    payload=chatgpt_request_payload(provider,request,model)
    if payload isa ModelImagePolicyFailure
        provider_failure(payload.reason)
    else
        body = JSON.json(payload)
        stream = ChatGPTStream(context, request.protocol)
        response = transport_request(provider.transport, OPENAI_RESOURCE * "/responses", "POST", body, headers, context, SSEDecoder(stream))
        200 <= response.status < 300 ? result(stream, request.protocol) : transport_failure(response, "ChatGPT")
    end
end

result(stream::ChatGPTStream, protocol) = stream.completed && !stream.failed ? ProviderResult(decode_reply(protocol, String(take!(stream.text))), stream.usage) : provider_failure("ChatGPT response ended before successful completion.")
function chatgpt_reply(stream::AbstractString)
    result = ChatGPTStream(ExecutionContext())
    write(SSEDecoder(result), stream)
    result.completed && !result.failed ? (ok=true, text=String(take!(result.text))) : (ok=false, text="ChatGPT response ended before successful completion.")
end
respond(provider::OpenAIProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_identity(provider::OpenAIProvider) = ProviderIdentity(;
    id=:chatgpt, name="ChatGPT",
    detail="(chatgpt) " * (isempty(provider.model) ? "auto" : provider.model))

chatgpt_status(dir) = account(load_credentials(dir, :chatgpt))
account(::Nothing) = "not connected"
account(saved::AbstractDict) = isempty(get(saved, "email", "")) ? "connected" : saved["email"]
chatgpt_provider_descriptor() = ProviderDescriptor(:chatgpt, "ChatGPT direct OAuth", dir -> OpenAIProvider(dir); auth=sign_in!, status=chatgpt_status)
