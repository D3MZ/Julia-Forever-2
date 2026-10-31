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
    @test ("Authorization" => "Bearer secret") in requests[1][3]
    failed = OpenRouterProvider("secret", "example/model", (args...) -> (status=401, body="bad"))
    @test failed([Message(:user, "Hi")], Session(Kernel())).kind == :error
end
