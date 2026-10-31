using JSON
using Downloads

const CODE_MODE_INSTRUCTIONS = """
You are the model in a Julia agent harness. Respond with a JSON object containing exactly the
string fields kind and content. For an action, return kind=code and Julia source in content;
the host executes it and supplies a user message with kind=code_result and its output.
Return kind=answer when the user's request is complete or no action is needed.
Assistant messages preserve their original kind and content as JSON. Code executes with the
user's permissions in a persistent Julia module with kernel, session, include, print, println,
and the JuliaForever2 exports. Install components with install!(kernel, ComponentSpec(:name,
value; requires=[:dependency])). Layer behavior with wrap_component! around the current
component. spawn_agent! returns a TaskHandle immediately; fetch(handle) waits for its result
and handle.session contains the child session. Generated Julia follows the success path
without exception handling. Inspect code results before claiming an action completed.
"""

struct CodeModePolicy
    instructions::String
end
CodeModePolicy() = CodeModePolicy(CODE_MODE_INSTRUCTIONS)
prompt_instructions(policy::CodeModePolicy, session) = policy.instructions
prompt_instructions(instructions::AbstractString, session) = String(instructions)
reply_schema(policy) = Dict("type" => "object", "properties" => Dict("kind" => Dict("type" => "string", "enum" => ["code", "answer"]), "content" => Dict("type" => "string")), "required" => ["kind", "content"], "additionalProperties" => false)
reply_format(policy) = Dict("type" => "json_object")

struct UsageReport
    input_tokens::Union{Nothing,Int}
    output_tokens::Union{Nothing,Int}
    cost::Union{Nothing,Float64}
end
UsageReport() = UsageReport(nothing, nothing, nothing)
usage_tokens(value::Integer) = value isa Bool || value < 0 || value > typemax(Int) ? nothing : Int(value)
usage_tokens(value) = nothing
usage_cost(value::Real) = value isa Bool || !isfinite(value) || value < 0 ? nothing : Float64(value)
usage_cost(value) = nothing
normalize_usage(data) = UsageReport()
normalize_usage(data::UsageReport) = data
normalize_usage(data::AbstractDict) = UsageReport(usage_tokens(get(data, "prompt_tokens", get(data, "input_tokens", nothing))), usage_tokens(get(data, "completion_tokens", get(data, "output_tokens", nothing))), usage_cost(get(data, "cost", nothing)))

function record_usage!(session::Session, report::UsageReport)
    lock(session.lock) do
        usage = session.usage
        if !isnothing(report.input_tokens) && !isnothing(report.output_tokens)
            usage.input_tokens += report.input_tokens
            usage.output_tokens += report.output_tokens
            usage.reported = true
        else
            usage.partial = true
        end
        if isnothing(report.cost)
            usage.cost_known = false
        else
            usage.cost += report.cost
        end
    end
    return nothing
end
record_usage!(session::Session, data) = record_usage!(session, normalize_usage(data))

function usage_label(session::Session)
    lock(session.lock) do
        usage = session.usage
        usage.reported || return ""
        label = (usage.partial ? "~" : "") * "↑$(usage.input_tokens) ↓$(usage.output_tokens)"
        return usage.cost_known ? label * " \$" * string(round(usage.cost; digits=4)) : label
    end
end

wire_metadata(metadata) = metadata
wire_metadata(result::ExecutionResult) = (ok=result.ok,)

function wire_content(message)
    metadata = wire_metadata(message.metadata)
    message.kind == :text && message.role != :code_result && isnothing(metadata) && return message.content
    kind = message.role == :code_result ? :code_result : message.kind
    return JSON.json((kind=kind, content=message.content, metadata=metadata))
end

function conversation_messages(messages, instructions; system_role="system")
    result = Dict{String,Any}[Dict("role" => system_role, "content" => instructions)]
    for message in messages
        role = message.role == :code_result ? "user" : string(message.role)
        push!(result, Dict("role" => role, "content" => wire_content(message)))
    end
    return result
end

function agent_reply(data::AbstractDict)
    kind = get(data, "kind", nothing)
    content = get(data, "content", nothing)
    kind in ("code", "answer") && content isa AbstractString || return Reply(:error, "Provider returned an invalid agent response.")
    return Reply(Symbol(kind), String(content))
end
agent_reply(data) = Reply(:error, "Provider returned an invalid agent response.")
parse_json(text::AbstractString) = JSON.isvalidjson(text) ? JSON.parse(text) : nothing
decode_reply(text::AbstractString) = agent_reply(parse_json(text))
decode_reply(value) = agent_reply(nothing)
decode_reply(policy, text) = decode_reply(text)
choice_reply(policy, data) = agent_reply(nothing)
message_reply(policy, data) = agent_reply(nothing)
message_reply(policy, data::AbstractDict) = decode_reply(policy, get(data, "content", nothing))
choice_reply(policy, data::AbstractDict) = message_reply(policy, get(data, "message", nothing))
choices_reply(policy, choices) = agent_reply(nothing)
choices_reply(policy, choices::AbstractVector) = isempty(choices) ? Reply(:error, "Provider returned no choices.") : choice_reply(policy, first(choices))

response_result(response::Downloads.Response, body::AbstractString) = (status=response.status, body=String(body), reason="")
response_result(response::Downloads.RequestError, body::AbstractString) = (status=0, body="", reason=response.message)

function http_request(url, method, body, headers, context::ExecutionContext; timeout=120.0, sink=nothing)
    cancelled(context) && return (status=0, body="", reason="Request cancelled or timed out.")
    output = isnothing(sink) ? IOBuffer() : sink
    input = method == "GET" ? nothing : IOBuffer(body)
    interrupt = Base.Event()
    register_cancellation!(context, interrupt)
    response = Downloads.request(url; method, input, output, headers, throw=false,
        timeout=min(timeout, remaining_time(context)), interrupt)
    unregister_cancellation!(context, interrupt)
    text = isnothing(sink) ? String(take!(output)) : ""
    return response_result(response, text)
end

router_request(url, body, headers, context::ExecutionContext=ExecutionContext()) = http_request(url, "POST", body, headers, context)
openai_request(url, method, body, headers, context::ExecutionContext=ExecutionContext(), sink=nothing) = http_request(url, method, body, headers, context; timeout=180.0, sink)

function transport_request(transport, url, body, headers, context::ExecutionContext)
    return applicable(transport, url, body, headers, context) ? transport(url, body, headers, context) : transport(url, body, headers)
end

function transport_request(transport, url, method, body, headers, context::ExecutionContext, sink=nothing)
    if applicable(transport, url, method, body, headers, context, sink)
        return transport(url, method, body, headers, context, sink)
    end
    response = transport(url, method, body, headers)
    isnothing(sink) || write(sink, response.body)
    return response
end

provider_failure(message) = ProviderResult(Reply(:error, message), nothing)
transport_reason(response, label) = isempty(get(response, :reason, "")) ? "$label returned HTTP $(response.status)." : "$label: $(response.reason)"
transport_failure(response, label) = provider_failure(transport_reason(response, label))

function call_provider(provider, messages, session::Session)
    result = respond(provider, messages, session, ExecutionContext())
    usage = response_usage(result)
    isnothing(usage) || record_usage!(session, usage)
    return response_reply(result)
end

struct DemoProvider end
function respond(::DemoProvider, messages, session, context::ExecutionContext)
    answer = !isempty(messages) && messages[end].role == :code_result ? "The Julia program finished. Its output is shown above." : "Demo provider: configure Codex or another provider to get a model response. Julia code can be run with /julia."
    return ProviderResult(Reply(:answer, answer), nothing)
end
(provider::DemoProvider)(messages, session) = call_provider(provider, messages, session)

struct CodexProvider{P}
    executable::String
    model::String
    reasoning::String
    policy::P
end
CodexProvider(executable::AbstractString="codex"; model="gpt-6.1-terra", reasoning="max", policy=CodeModePolicy()) = CodexProvider(String(executable), String(model), String(reasoning), policy)
CodexProvider(executable::AbstractString, model::AbstractString, reasoning::AbstractString) = CodexProvider(executable; model, reasoning)
(provider::CodexProvider)(messages, session) = call_provider(provider, messages, session)

function codex_usage(events)
    report = UsageReport()
    for line in events
        event = parse_json(line)
        event isa AbstractDict || continue
        get(event, "type", "") == "turn.completed" && (report = normalize_usage(get(event, "usage", nothing)))
    end
    return report
end
record_codex_usage!(session::Session, events) = record_usage!(session, codex_usage(events))

function wait_process!(process::Base.Process, context::ExecutionContext)
    while process_running(process) && !cancelled(context)
        sleep(min(0.02, max(0.001, remaining_time(context))))
    end
    if process_running(process)
        kill(process)
        timedwait(() -> !process_running(process), 1.0; pollint=0.01)
        process_running(process) && kill(process, Base.SIGKILL)
    end
    wait(process)
    return success(process) && !cancelled(context)
end

function respond(provider::CodexProvider, messages, session, context::ExecutionContext)
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    schema = reply_schema(provider.policy)
    conversation = conversation_messages(messages, prompt_instructions(provider.policy, session))
    return mktempdir() do directory
        schemafile = joinpath(directory, "schema.json")
        outfile = joinpath(directory, "reply.json")
        eventsfile = joinpath(directory, "events.jsonl")
        inputfile = joinpath(directory, "input.json")
        write(schemafile, JSON.json(schema))
        write(inputfile, JSON.json(conversation))
        reasoning = "model_reasoning_effort=" * JSON.json(provider.reasoning)
        command = `$(provider.executable) exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C $directory --model $(provider.model) -c $reasoning --json --output-schema $schemafile -o $outfile -`
        completed = open(eventsfile, "w") do output
            open(inputfile, "r") do input
                process = run(pipeline(ignorestatus(command); stdin=input, stdout=output, stderr=devnull); wait=false)::Base.Process
                wait_process!(process, context)
            end
        end
        completed || return provider_failure(cancelled(context) ? "Request cancelled or timed out." : "Codex could not produce a response. Check that the CLI is installed and signed in.")
        isfile(outfile) || return provider_failure("Codex did not return an agent response.")
        return ProviderResult(decode_reply(provider.policy, read(outfile, String)), codex_usage(eachline(eventsfile)))
    end
end

function default_kernel(provider=DemoProvider())
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, provider))
    install!(kernel, ComponentSpec(:executor, default_evaluate!))
    install!(kernel, ComponentSpec(:loop, default_loop!))
    return kernel
end

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

function respond(provider::OpenRouterProvider, messages, session, context::ExecutionContext)
    isempty(provider.api_key) && return provider_failure("Set OPENROUTER_API_KEY before selecting OpenRouter.")
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    conversation = conversation_messages(messages, prompt_instructions(provider.policy, session))
    body = JSON.json(Dict("model" => provider.model, "messages" => conversation, "response_format" => reply_format(provider.policy)))
    headers = ["Authorization" => "Bearer $(provider.api_key)", "Content-Type" => "application/json"]
    response = transport_request(provider.transport, "https://openrouter.ai/api/v1/chat/completions", body, headers, context)
    response.status == 401 && return provider_failure("OpenRouter rejected the API key (HTTP 401). Check or replace the configured key.")
    200 <= response.status < 300 || return transport_failure(response, "OpenRouter")
    parsed = parse_json(response.body)
    parsed isa AbstractDict || return provider_failure("OpenRouter returned invalid JSON.")
    choices = get(parsed, "choices", [])
    reply = choices_reply(provider.policy, choices)
    return ProviderResult(reply, normalize_usage(get(parsed, "usage", nothing)))
end

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
    lock(provider.catalog.lock) do
        time() < provider.catalog.expires_at && return (models=provider.catalog.models, reason="")
        response = transport_request(provider.transport, OPENAI_RESOURCE * "/models", "GET", "", headers, context)
        200 <= response.status < 300 || return (models=String[], reason=transport_reason(response, "ChatGPT model discovery"))
        data = parse_json(response.body)
        data isa AbstractDict || return (models=String[], reason="ChatGPT model discovery returned invalid JSON.")
        models = get(data, "models", [])
        provider.catalog.models = String[m["slug"] for m in models if get(m, "visibility", "") == "list" && get(m, "slug", nothing) isa AbstractString]
        provider.catalog.expires_at = time() + provider.catalog_ttl
        return (models=provider.catalog.models, reason="")
    end
end

mutable struct ChatGPTStream{C}
    context::C
    text::IOBuffer
    completed::Bool
    failed::Bool
    usage::UsageReport
end
ChatGPTStream(context) = ChatGPTStream(context, IOBuffer(), false, false, UsageReport())

function (stream::ChatGPTStream)(event)
    event.data == "[DONE]" && return nothing
    data = parse_json(event.data)
    data isa AbstractDict || return nothing
    kind = get(data, "type", event.event)
    if kind == "response.output_text.delta"
        delta = get(data, "delta", "")
        print(stream.text, delta)
        emit!(stream.context, HarnessEvent(:provider_delta, delta))
    elseif kind == "response.completed"
        stream.completed = true
        stream.usage = normalize_usage(get(get(data, "response", Dict()), "usage", nothing))
    elseif kind in ("response.failed", "response.incomplete", "error")
        stream.failed = true
    end
    return nothing
end

function respond(provider::OpenAIProvider, messages, session, context::ExecutionContext)
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
    conversation = conversation_messages(messages, prompt_instructions(provider.policy, session); system_role="developer")
    body = JSON.json(Dict("model" => model, "input" => conversation, "store" => false, "stream" => true, "text" => Dict("format" => reply_format(provider.policy))))
    stream = ChatGPTStream(context)
    decoder = SSEDecoder(stream)
    response = transport_request(provider.transport, OPENAI_RESOURCE * "/responses", "POST", body, headers, context, decoder)
    200 <= response.status < 300 || return transport_failure(response, "ChatGPT")
    stream.completed && !stream.failed || return provider_failure("ChatGPT response ended before successful completion.")
    return ProviderResult(decode_reply(provider.policy, String(take!(stream.text))), stream.usage)
end

provider_id(provider) = :custom
provider_id(::DemoProvider) = :demo
provider_id(::OpenRouterProvider) = :openrouter
provider_id(::OpenAIProvider) = :chatgpt
provider_id(::CodexProvider) = :codex
provider_name(provider) = "Custom provider"
provider_name(::DemoProvider) = "Demo"
provider_name(::OpenRouterProvider) = "OpenRouter"
provider_name(::OpenAIProvider) = "ChatGPT"
provider_name(::CodexProvider) = "Codex"
provider_detail(provider) = provider_name(provider)
provider_detail(::DemoProvider) = "(demo) offline · /settings to connect"
provider_detail(provider::OpenRouterProvider) = "(openrouter) " * provider.model
provider_detail(provider::OpenAIProvider) = "(chatgpt) " * (isempty(provider.model) ? "auto" : provider.model)
provider_detail(provider::CodexProvider) = "(openai-codex) " * provider.model * " • " * provider.reasoning

struct ProviderDescriptor{F,A,S}
    id::Symbol
    label::String
    create::F
    auth::A
    status::S
end
ProviderDescriptor(id::Symbol, label::AbstractString, create; auth=nothing, status=Returns("")) = ProviderDescriptor(id, String(label), create, auth, status)
const PROVIDER_REGISTRY_LOCK = ReentrantLock()
const PROVIDER_REGISTRY = ProviderDescriptor[]

function register_provider!(descriptor::ProviderDescriptor)
    lock(PROVIDER_REGISTRY_LOCK) do
        index = findfirst(item -> item.id == descriptor.id, PROVIDER_REGISTRY)
        isnothing(index) ? push!(PROVIDER_REGISTRY, descriptor) : (PROVIDER_REGISTRY[index] = descriptor)
    end
    return descriptor
end
function unregister_provider!(id::Symbol)
    lock(PROVIDER_REGISTRY_LOCK) do
        filter!(descriptor -> descriptor.id != id, PROVIDER_REGISTRY)
    end
    return nothing
end
provider_descriptors() = lock(() -> copy(PROVIDER_REGISTRY), PROVIDER_REGISTRY_LOCK)
function provider_descriptor(id::Symbol)
    descriptors = provider_descriptors()
    index = findfirst(descriptor -> descriptor.id == id, descriptors)
    return isnothing(index) ? nothing : descriptors[index]
end
function provider_from_name(id::Symbol; dir=config_dir())
    descriptor = provider_descriptor(id)
    return isnothing(descriptor) ? nothing : Base.invokelatest(descriptor.create, dir)
end
provider_from_name(name::AbstractString; dir=config_dir()) = provider_from_name(Symbol(name); dir)

function configured_provider(dir::AbstractString=config_dir())
    path = joinpath(dir, "provider")
    return provider_from_name(isfile(path) ? strip(read(path, String)) : "demo"; dir)
end

function save_provider!(dir::AbstractString, provider::Symbol)
    mkpath(dir; mode=0o700)
    mktemp(dir) do temp, io
        chmod(temp, 0o600)
        print(io, provider)
        close(io)
        Base.Filesystem.rename(temp, joinpath(dir, "provider"))
    end
    return nothing
end

function chatgpt_status(dir)
    saved = load_credentials(dir, :chatgpt)
    isnothing(saved) && return "not connected"
    email = get(saved, "email", "")
    return isempty(email) ? "connected" : email
end
openrouter_status(dir) = !isnothing(load_credentials(dir, :openrouter)) || !isempty(get(ENV, "OPENROUTER_API_KEY", "")) ? "key configured" : "sign in or use Pi credentials"
register_provider!(ProviderDescriptor(:demo, "Demo", dir -> DemoProvider(); status=Returns("offline, deterministic")))
register_provider!(ProviderDescriptor(:chatgpt, "ChatGPT direct OAuth", dir -> OpenAIProvider(dir); auth=sign_in!, status=chatgpt_status))
register_provider!(ProviderDescriptor(:openrouter, "OpenRouter", dir -> OpenRouterProvider(; dir); auth=sign_in!, status=openrouter_status))
register_provider!(ProviderDescriptor(:codex, "ChatGPT / Codex", dir -> CodexProvider(); auth=codex_sign_in!, status=Returns("CLI sign-in")))
