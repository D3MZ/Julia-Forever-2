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
