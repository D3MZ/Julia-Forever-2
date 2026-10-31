using JSON
using Downloads

struct DemoProvider end

function (::DemoProvider)(messages, session)
    if messages[end].role == :code_result
        return Reply(:answer, "The Julia program finished. Its output is shown above.")
    end
    return Reply(:answer, "Demo provider: configure Codex or another provider to get a model response. Julia code can be run with /julia.")
end

struct CodexProvider
    executable::String
end
CodexProvider() = CodexProvider("codex")

function (provider::CodexProvider)(messages::Vector{Message}, session::Session)
    schema = Dict("type" => "object", "properties" => Dict("kind" => Dict("type" => "string", "enum" => ["code", "answer"]), "content" => Dict("type" => "string")), "required" => ["kind", "content"], "additionalProperties" => false)
    instructions = "You are the model for a Julia agent harness. Do not use your tools. Respond with JSON matching the schema. Use kind=code with Julia source in content when you need to act; the harness executes it and returns the result. Use kind=answer for your final reply. Code runs in a persistent Julia module with kernel, session, print and println available. JuliaForever2 exports ComponentSpec, install!, component, spawn_agent!, and other kernel APIs. Code has the user's full permissions. Conversation follows:\n"
    transcript = join(["$(m.role): $(m.content)" for m in messages], "\n\n")
    return mktempdir() do dir::String
        schemafile = joinpath(dir, "schema.json")
        outfile = joinpath(dir, "reply.json")
        write(schemafile, JSON.json(schema))
        cmd = `$(provider.executable) exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C $dir --output-schema $schemafile -o $outfile -`
        process = run(pipeline(cmd, stdin=IOBuffer(instructions * transcript), stdout=devnull, stderr=devnull); wait=false)
        wait(process)
        success(process) || return Reply(:error, "Codex could not produce a response. Check that the CLI is installed and signed in.")
        parsed = JSON.parse(read(outfile, String))
        return Reply(Symbol(parsed["kind"]), String(parsed["content"]))
    end
end

function default_kernel()
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, DemoProvider()))
    install!(kernel, ComponentSpec(:executor, default_evaluate!))
    install!(kernel, ComponentSpec(:loop, default_loop!))
    install!(kernel, ComponentSpec(:input, default_input!))
    install!(kernel, ComponentSpec(:view, default_view!))
    return kernel
end

struct OpenRouterProvider{F}
    api_key::String
    model::String
    transport::F
end

Base.show(io::IO, provider::OpenRouterProvider) = print(io, "OpenRouterProvider(", repr(provider.model), ", [redacted])")

function router_request(url, body, headers)
    output = IOBuffer()
    response = Downloads.request(url; method="POST", input=IOBuffer(body), output, headers, throw=false, timeout=120)
    return (status=response.status, body=String(take!(output)))
end

OpenRouterProvider(api_key::AbstractString, model::AbstractString) = OpenRouterProvider(String(api_key), String(model), router_request)
function OpenRouterProvider()
    saved = load_credentials(config_dir(), :openrouter)
    stored = isnothing(saved) ? "" : get(saved, "key", "")
    key = isempty(stored) ? get(ENV, "OPENROUTER_API_KEY", "") : stored
    return OpenRouterProvider(key, get(ENV, "OPENROUTER_MODEL", "openai/gpt-4.1-mini"))
end

function (provider::OpenRouterProvider)(messages::Vector{Message}, session::Session)
    isempty(provider.api_key) && return Reply(:error, "Set OPENROUTER_API_KEY before selecting OpenRouter.")
    system = "You are the model for a Julia agent harness. Reply as a JSON object with exactly the string fields kind and content. Use kind=code and Julia source when you need to act; the harness runs it and returns the result. Use kind=answer for your final response. A persistent Julia module provides kernel, session, include, and JuliaForever2 exports. Register a value with install!(kernel, ComponentSpec(:name, value)); retrieve it with component(kernel, :name). Dependencies use ComponentSpec(:name, value; requires=[:dependency]). A :loop component is called as (session, prompt, max_steps) and may delegate to JuliaForever2.default_loop!(session, prompt, max_steps). spawn_agent! starts a child session. Code runs with the user's permissions."
    transcript = join(["$(m.role): $(m.content)" for m in messages], "\n\n")
    body = JSON.json(Dict("model" => provider.model, "messages" => [Dict("role" => "system", "content" => system), Dict("role" => "user", "content" => transcript)], "response_format" => Dict("type" => "json_object")))
    headers = ["Authorization" => "Bearer $(provider.api_key)", "Content-Type" => "application/json"]
    response = provider.transport("https://openrouter.ai/api/v1/chat/completions", body, headers)
    response.status == 401 && return Reply(:error, "OpenRouter rejected the API key (HTTP 401). Check or replace the configured key.")
    200 <= response.status < 300 || return Reply(:error, "OpenRouter returned HTTP $(response.status).")
    parsed = JSON.parse(response.body)
    reply = JSON.parse(parsed["choices"][1]["message"]["content"])
    reply isa AbstractDict && get(reply, "kind", nothing) isa AbstractString && get(reply, "content", nothing) isa AbstractString || return Reply(:error, "OpenRouter returned an invalid agent response.")
    return Reply(Symbol(reply["kind"]), String(reply["content"]))
end

struct OpenAIProvider{F,G}
    dir::String
    transport::F
    auth_transport::G
end

function openai_request(url, method, body, headers)
    output = IOBuffer()
    input = method == "POST" ? IOBuffer(body) : nothing
    response = Downloads.request(url; method, input, output, headers, throw=false, timeout=180)
    return (status=response.status, body=String(take!(output)))
end

OpenAIProvider(dir::AbstractString=config_dir()) = OpenAIProvider(String(dir), openai_request, auth_request)

function (provider::OpenAIProvider)(messages::Vector{Message}, session::Session)
    refreshed = refresh_chatgpt!(provider.dir; transport=provider.auth_transport)
    refreshed.ok || return Reply(:error, refreshed.reason)
    token = refreshed.credentials["access_token"]
    headers = ["Authorization" => "Bearer $(token)", "Content-Type" => "application/json"]
    catalog = provider.transport(OPENAI_RESOURCE * "/models", "GET", "", headers)
    200 <= catalog.status < 300 || return Reply(:error, "ChatGPT model discovery failed (HTTP $(catalog.status)).")
    models = get(JSON.parse(catalog.body), "models", [])
    available = [m["slug"] for m in models if get(m, "visibility", "") == "list" && haskey(m, "slug")]
    isempty(available) && return Reply(:error, "No ChatGPT models are available for this account.")
    requested = get(ENV, "CHATGPT_MODEL", "")
    model = isempty(requested) ? first(available) : requested
    model in available || return Reply(:error, "CHATGPT_MODEL is not in the account's available model list.")
    instructions = "You are the model for a Julia agent harness. Respond with a JSON object with keys kind and content. Use kind=code and Julia source when you need to act; the harness executes it and returns the result. Use kind=answer for your final answer. Code runs in a persistent Julia module with kernel, session, and JuliaForever2 exports including ComponentSpec, install!, component, and spawn_agent!. Code runs with the user's permissions."
    transcript = join(["$(m.role): $(m.content)" for m in messages], "\n\n")
    body = JSON.json(Dict("model" => model, "input" => [Dict("role" => "developer", "content" => instructions), Dict("role" => "user", "content" => transcript)], "store" => false, "stream" => true, "text" => Dict("format" => Dict("type" => "json_object"))))
    response = provider.transport(OPENAI_RESOURCE * "/responses", "POST", body, headers)
    200 <= response.status < 300 || return Reply(:error, "ChatGPT request failed (HTTP $(response.status)).")
    result = chatgpt_reply(response.body)
    result.ok || return Reply(:error, result.text)
    parsed = JSON.parse(result.text)
    kind = Symbol(get(parsed, "kind", "error"))
    content = get(parsed, "content", "")
    kind in (:code, :answer) && content isa AbstractString || return Reply(:error, "ChatGPT returned an invalid agent response.")
    return Reply(kind, String(content))
end
