using JSON

router_request(url, body, headers, context::ExecutionContext=ExecutionContext()) = http_request(url, "POST", body, headers, context)

struct OpenRouterProvider{F,P}
    api_key::String
    model::String
    transport::F
    policy::P
end
OpenRouterProvider(key::AbstractString, model::AbstractString, transport=router_request; policy=CodeModePolicy()) = OpenRouterProvider(String(key), String(model), transport, policy)
OpenRouterProvider(provider::OpenRouterProvider, model::AbstractString) = OpenRouterProvider(provider.api_key, model, provider.transport; policy=provider.policy)
Base.show(io::IO, provider::OpenRouterProvider) = print(io, "OpenRouterProvider(", repr(provider.model), ", [redacted])")
(provider::OpenRouterProvider)(messages, session) = call_provider(provider, messages, session)

pi_openrouter_key() = apikey(Sys.which("pi"))
apikey(::Nothing) = ""

function apikey(executable::AbstractString)
    output = IOBuffer()
    process = run(pipeline(ignorestatus(`$executable auth print-api-key --provider openrouter`); stdout=output, stderr=devnull))
    success(process) ? strip(String(take!(output))) : ""
end
function openrouter_key(dir::AbstractString; pi_key=pi_openrouter_key, environment=ENV)
    saved = load_credentials(dir, :openrouter)
    stored = isnothing(saved) ? "" : get(saved, "key", "")
    if isempty(stored)
        key = pi_key()
        isempty(key) ? get(environment, "OPENROUTER_API_KEY", "") : key
    else
        stored
    end
end
OpenRouterProvider(; dir=config_dir(), model=get(ENV, "OPENROUTER_MODEL", "nvidia/nemotron-3.5-super-vl:free"), policy=CodeModePolicy()) = OpenRouterProvider(openrouter_key(dir), model; policy)

function respond(provider::OpenRouterProvider, request::ModelRequest, context::ExecutionContext)
    if isempty(provider.api_key)
        provider_failure("Set OPENROUTER_API_KEY before selecting OpenRouter.")
    elseif cancelled(context)
        provider_failure("Request cancelled or timed out.")
    else
        exchange(provider, request, context)
    end
end

function exchange(provider::OpenRouterProvider, request::ModelRequest, context)
    conversation = conversation_messages(request.messages, request.instructions)
    body = JSON.json(Dict("model" => provider.model, "messages" => conversation, "response_format" => request.response_format))
    headers = ["Authorization" => "Bearer $(provider.api_key)", "Content-Type" => "application/json"]
    response = transport_request(provider.transport, "https://openrouter.ai/api/v1/chat/completions", body, headers, context)
    if response.status == 401
        provider_failure("OpenRouter rejected the API key (HTTP 401). Check or replace the configured key.")
    elseif 200 <= response.status < 300
        result(provider, request, parse_json(response.body))
    else
        transport_failure(response, "OpenRouter")
    end
end

result(provider::OpenRouterProvider, request, parsed) = provider_failure("OpenRouter returned invalid JSON.")
result(provider::OpenRouterProvider, request, parsed::AbstractDict) = ProviderResult(choices_reply(request.protocol, get(parsed, "choices", [])), UsageReport(get(parsed, "usage", nothing)))
respond(provider::OpenRouterProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_identity(provider::OpenRouterProvider) = ProviderIdentity(;
    id=:openrouter, name="OpenRouter", detail="(openrouter) " * provider.model)
openrouter_status(dir) = !isnothing(load_credentials(dir, :openrouter)) || !isempty(get(ENV, "OPENROUTER_API_KEY", "")) ? "key configured" : "sign in or use Pi credentials"
openrouter_provider_descriptor() = ProviderDescriptor(:openrouter, "OpenRouter", dir -> OpenRouterProvider(; dir); auth=sign_in!, status=openrouter_status)
