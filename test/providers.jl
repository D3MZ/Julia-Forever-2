using JuliaForever2: OpenRouterProvider
using JSON

@testset "OpenRouter protocol" begin
    requests = []
    transport = (url, body, headers) -> begin
        push!(requests, (url, JSON.parse(body), headers))
        (status=200, body=JSON.json(Dict("choices" => [Dict("message" => Dict("content" => JSON.json(Dict("kind" => "answer", "content" => "Hello"))))])))
    end
    provider = OpenRouterProvider("secret", "example/model", transport)
    reply = provider([Message(:user, "Hi")], Session(Kernel()))
    @test reply == Reply(:answer, "Hello")
    @test requests[1][2]["model"] == "example/model"
    @test occursin("Hi", requests[1][2]["messages"][2]["content"])
    @test occursin("install!(kernel, ComponentSpec", requests[1][2]["messages"][1]["content"])
    @test ("Authorization" => "Bearer secret") in requests[1][3]
    failed = OpenRouterProvider("secret", "example/model", (args...) -> (status=401, body="bad"))
    failure = failed([Message(:user, "Hi")], Session(Kernel()))
    @test failure.kind == :error
    @test occursin("401", failure.content)
    @test occursin("key", lowercase(failure.content))
    malformed = OpenRouterProvider("secret", "example/model", (args...) -> (status=200, body=JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "{}"))]))))
    @test malformed([Message(:user, "Hi")], Session(Kernel())).kind == :error
end

@testset "Reported usage appears in session" begin
    body = JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "{\"kind\":\"answer\",\"content\":\"ok\"}"))], "usage" => Dict("prompt_tokens" => 120, "completion_tokens" => 18, "cost" => 0.002)))
    provider = OpenRouterProvider("secret", "example/model", (args...) -> (status=200, body=body))
    session = Session(Kernel())
    provider([Message(:user, "Hi")], session)
    provider([Message(:user, "Hi again")], session)
    @test session.usage.input_tokens == 240
    @test session.usage.output_tokens == 36
    @test session.usage.cost ≈ 0.004
    JuliaForever2.record_usage!(session, nothing)
    @test startswith(JuliaForever2.usage_label(session), "~↑240 ↓36")
    @test !occursin("\$", JuliaForever2.usage_label(session))
end

@testset "Codex subscription model and reasoning" begin
    mktempdir() do dir
        executable = joinpath(dir, "codex")
        arguments = joinpath(dir, "arguments")
        script = """
        #!/bin/sh
        printf '%s\\n' "\$@" > "\$JF2_CODEX_ARGS"
        while [ "\$#" -gt 0 ]; do
            if [ "\$1" = "-o" ]; then shift; outfile=\$1; fi
            shift
        done
        printf '%s' '{"kind":"answer","content":"ok"}' > "\$outfile"
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":120,"output_tokens":18}}'
        """
        write(executable, script)
        chmod(executable, 0o755)
        withenv("JF2_CODEX_ARGS" => arguments) do
            provider = JuliaForever2.CodexProvider(executable)
            session = Session(Kernel())
            reply = provider([Message(:user, "hello")], session)
            @test reply == Reply(:answer, "ok")
            @test JuliaForever2.usage_label(session) == "↑120 ↓18"
            args = readlines(arguments)
            @test "gpt-6.1-terra" in args
            @test "model_reasoning_effort=\"max\"" in args
            @test "--json" in args
            @test JuliaForever2.provider_detail(provider) == "(openai-codex) gpt-6.1-terra • max"
        end
    end
end

@testset "OpenRouter key sources" begin
    mktempdir() do dir
        env = Dict("OPENROUTER_API_KEY" => "env-key")
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "pi-key", environment=env) == "pi-key"
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "", environment=env) == "env-key"
        JuliaForever2.save_credentials!(dir, :openrouter, Dict("key" => "saved-key"))
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "pi-key", environment=env) == "saved-key"
    end
end

@testset "Browser credentials take precedence" begin
    mktempdir() do dir
        JuliaForever2.save_credentials!(dir, :openrouter, Dict("key" => "browser-key"))
        withenv("JULIAFOREVER_CONFIG_DIR" => dir, "OPENROUTER_API_KEY" => "environment-key") do
            @test OpenRouterProvider().api_key == "browser-key"
        end
    end
end

@testset "Credentials are not shown when displaying a provider" begin
    provider = OpenRouterProvider("synthetic-secret", "example/model")
    @test !occursin("synthetic-secret", repr(provider))
    @test occursin("example/model", repr(provider))
end
