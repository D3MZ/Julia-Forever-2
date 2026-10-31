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
    return mktempdir() do dir
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

function router_request(url, body, headers)
    output = IOBuffer()
    response = Downloads.request(url; method="POST", input=IOBuffer(body), output, headers, throw=false, timeout=120)
    return (status=response.status, body=String(take!(output)))
end

OpenRouterProvider(api_key::AbstractString, model::AbstractString) = OpenRouterProvider(String(api_key), String(model), router_request)
OpenRouterProvider() = OpenRouterProvider(get(ENV, "OPENROUTER_API_KEY", ""), get(ENV, "OPENROUTER_MODEL", "openai/gpt-4.1-mini"))

function (provider::OpenRouterProvider)(messages::Vector{Message}, session::Session)
    isempty(provider.api_key) && return Reply(:error, "Set OPENROUTER_API_KEY before selecting OpenRouter.")
    system = "You are the model for a Julia agent harness. Reply as a JSON object with kind and content. Use kind=code and Julia source when you need to act; the harness runs it and returns the result. Use kind=answer for your final response. A persistent Julia module provides kernel, session, and JuliaForever2 exports, including ComponentSpec, install!, component, and spawn_agent!. Code runs with the user's permissions."
    transcript = join(["$(m.role): $(m.content)" for m in messages], "\n\n")
    body = JSON.json(Dict("model" => provider.model, "messages" => [Dict("role" => "system", "content" => system), Dict("role" => "user", "content" => transcript)], "response_format" => Dict("type" => "json_object")))
    headers = ["Authorization" => "Bearer $(provider.api_key)", "Content-Type" => "application/json"]
    response = provider.transport("https://openrouter.ai/api/v1/chat/completions", body, headers)
    200 <= response.status < 300 || return Reply(:error, "OpenRouter returned HTTP $(response.status).")
    parsed = JSON.parse(response.body)
    reply = JSON.parse(parsed["choices"][1]["message"]["content"])
    return Reply(Symbol(reply["kind"]), String(reply["content"]))
end
