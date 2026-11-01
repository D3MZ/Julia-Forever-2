using JSON

openai_request(url, method, body, headers, context::ExecutionContext=ExecutionContext(), sink=nothing) = http_request(url, method, body, headers, context; timeout=180.0, sink)

mutable struct ModelCatalog
    lock::ReentrantLock
    models::Vector{String}
    expires_at::Float64
end
ModelCatalog() = ModelCatalog(ReentrantLock(), String[], 0.0)

struct OpenAIProvider{F,G,P}
    dir::String
    model::String
    transport::F
    auth_transport::G
    policy::P
    catalog::ModelCatalog
    catalog_ttl::Float64
end
OpenAIProvider(dir::AbstractString=config_dir(), transport=openai_request, auth_transport=auth_request; model=get(ENV, "CHATGPT_MODEL", ""), policy=CodeModePolicy(), catalog_ttl=300.0) = OpenAIProvider(String(dir), String(model), transport, auth_transport, policy, ModelCatalog(), Float64(catalog_ttl))
(provider::OpenAIProvider)(messages, session) = call_provider(provider, messages, session)

function available_models!(provider::OpenAIProvider, headers, context)
    cached = lock(provider.catalog.lock) do
        time() < provider.catalog.expires_at ? provider.catalog.models : nothing
    end
    isnothing(cached) || return (models=cached, reason="")

    response = transport_request(provider.transport, OPENAI_RESOURCE * "/models", "GET", "", headers, context)
    200 <= response.status < 300 || return (models=String[], reason=transport_reason(response, "ChatGPT model discovery"))
    data = parse_json(response.body)
    data isa AbstractDict || return (models=String[], reason="ChatGPT model discovery returned invalid JSON.")
    models = get(data, "models", [])
    models isa AbstractVector || return (models=String[], reason="ChatGPT model discovery returned invalid JSON.")
    discovered = String[m["slug"] for m in models if m isa AbstractDict &&
        get(m, "visibility", "") == "list" && get(m, "slug", nothing) isa AbstractString]
    return lock(provider.catalog.lock) do
        if time() >= provider.catalog.expires_at
            provider.catalog.models = discovered
            provider.catalog.expires_at = time() + provider.catalog_ttl
        end
        return (models=provider.catalog.models, reason="")
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
ChatGPTStream(context, policy=CodeModePolicy(); progress_interval=1 / 30) =
    ChatGPTStream(context, policy, IOBuffer(), false, false, UsageReport(),
        Float64(progress_interval), -Inf)

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

function (stream::ChatGPTStream)(event)
    event.data == "[DONE]" && return nothing
    data = parse_json(event.data)
    data isa AbstractDict || return nothing
    kind = get(data, "type", event.event)
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
    return nothing
end

function respond(provider::OpenAIProvider, request::ModelRequest, context::ExecutionContext)
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    refreshed = refresh_chatgpt!(provider.dir; transport=provider.auth_transport, context)
    refreshed.ok || return provider_failure(refreshed.reason)
    token = refreshed.credentials["access_token"]
    headers = ["Authorization" => "Bearer $(token)", "Content-Type" => "application/json"]
    catalog = available_models!(provider, headers, context)
    isempty(catalog.reason) || return provider_failure(catalog.reason)
    models = catalog.models
    isempty(models) && return provider_failure("No ChatGPT models are available for this account.")
    model = isempty(provider.model) ? first(models) : provider.model
    model in models || return provider_failure("The configured ChatGPT model is not available for this account.")
    conversation = conversation_messages(request.messages, request.instructions; system_role="developer")
    body = JSON.json(Dict("model" => model, "input" => conversation, "store" => false, "stream" => true, "text" => Dict("format" => request.response_format)))
    stream = ChatGPTStream(context, request.protocol)
    decoder = SSEDecoder(stream)
    response = transport_request(provider.transport, OPENAI_RESOURCE * "/responses", "POST", body, headers, context, decoder)
    200 <= response.status < 300 || return transport_failure(response, "ChatGPT")
    stream.completed && !stream.failed || return provider_failure("ChatGPT response ended before successful completion.")
    return ProviderResult(decode_reply(request.protocol, String(take!(stream.text))), stream.usage)
end

function chatgpt_reply(stream::AbstractString)
    result = ChatGPTStream(ExecutionContext())
    write(SSEDecoder(result), stream)
    result.completed && !result.failed || return (ok=false, text="ChatGPT response ended before successful completion.")
    return (ok=true, text=String(take!(result.text)))
end

respond(provider::OpenAIProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_id(::OpenAIProvider) = :chatgpt
provider_name(::OpenAIProvider) = "ChatGPT"
provider_detail(provider::OpenAIProvider) = "(chatgpt) " * (isempty(provider.model) ? "auto" : provider.model)

function chatgpt_status(dir)
    saved = load_credentials(dir, :chatgpt)
    isnothing(saved) && return "not connected"
    email = get(saved, "email", "")
    return isempty(email) ? "connected" : email
end
chatgpt_provider_descriptor() = ProviderDescriptor(:chatgpt, "ChatGPT direct OAuth", dir -> OpenAIProvider(dir);
    auth=sign_in!, status=chatgpt_status)
