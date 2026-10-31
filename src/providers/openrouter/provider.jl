using JSON

router_request(url, body, headers, context::ExecutionContext=ExecutionContext()) = http_request(url, "POST", body, headers, context)

struct OpenRouterProvider{F,P}
    api_key::String
    model::String
    transport::F
    policy::P
end
OpenRouterProvider(key::AbstractString, model::AbstractString, transport=router_request; policy=CodeModePolicy()) = OpenRouterProvider(String(key), String(model), transport, policy)
Base.show(io::IO, provider::OpenRouterProvider) = print(io, "OpenRouterProvider(", repr(provider.model), ", [redacted])")
(provider::OpenRouterProvider)(messages, session) = call_provider(provider, messages, session)

function pi_openrouter_key()
    executable = Sys.which("pi")
    if !isnothing(executable)
        output = IOBuffer()
        process = run(pipeline(ignorestatus(`$executable auth print-api-key --provider openrouter`); stdout=output, stderr=devnull))
        success(process) && return strip(String(take!(output)))
    end
    return ""
end

function openrouter_key(dir::AbstractString; pi_key=pi_openrouter_key, environment=ENV)
    saved = load_credentials(dir, :openrouter)
    stored = isnothing(saved) ? "" : get(saved, "key", "")
    !isempty(stored) && return stored
    key = pi_key()
    return isempty(key) ? get(environment, "OPENROUTER_API_KEY", "") : key
end
OpenRouterProvider(; dir=config_dir(), model=get(ENV, "OPENROUTER_MODEL", "nvidia/nemotron-3.5-super-vl:free"), policy=CodeModePolicy()) = OpenRouterProvider(openrouter_key(dir), model; policy)

function respond(provider::OpenRouterProvider, request::ModelRequest, context::ExecutionContext)
    isempty(provider.api_key) && return provider_failure("Set OPENROUTER_API_KEY before selecting OpenRouter.")
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    conversation = conversation_messages(request.messages, request.instructions)
    body = JSON.json(Dict("model" => provider.model, "messages" => conversation, "response_format" => request.response_format))
    headers = ["Authorization" => "Bearer $(provider.api_key)", "Content-Type" => "application/json"]
    response = transport_request(provider.transport, "https://openrouter.ai/api/v1/chat/completions", body, headers, context)
    response.status == 401 && return provider_failure("OpenRouter rejected the API key (HTTP 401). Check or replace the configured key.")
    200 <= response.status < 300 || return transport_failure(response, "OpenRouter")
    parsed = parse_json(response.body)
    parsed isa AbstractDict || return provider_failure("OpenRouter returned invalid JSON.")
    choices = get(parsed, "choices", [])
    reply = choices_reply(request.protocol, choices)
    return ProviderResult(reply, normalize_usage(get(parsed, "usage", nothing)))
end

respond(provider::OpenRouterProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_id(::OpenRouterProvider) = :openrouter
provider_name(::OpenRouterProvider) = "OpenRouter"
provider_detail(provider::OpenRouterProvider) = "(openrouter) " * provider.model
openrouter_status(dir) = !isnothing(load_credentials(dir, :openrouter)) ||
    !isempty(get(ENV, "OPENROUTER_API_KEY", "")) ? "key configured" : "sign in or use Pi credentials"
openrouter_provider_descriptor() = ProviderDescriptor(:openrouter, "OpenRouter", dir -> OpenRouterProvider(; dir);
    auth=sign_in!, status=openrouter_status)
