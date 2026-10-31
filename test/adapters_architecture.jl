using JSON

struct AdapterRequestPolicy end
JuliaForever2.decode_reply(::AdapterRequestPolicy, text) = Reply(:answer, reverse(String(text)))

@testset "Built-in model adapters consume explicit requests without a session" begin
    requests = []
    transport = (url, body, headers, context) -> begin
        push!(requests, JSON.parse(body))
        response = Dict("choices" => [Dict("message" => Dict("content" => "result"))],
            "usage" => Dict("prompt_tokens" => 7, "completion_tokens" => 3))
        (status=200, body=JSON.json(response))
    end
    provider = JuliaForever2.OpenRouterProvider("synthetic", "fixture", transport;
        policy=JuliaForever2.CodeModePolicy("provider default"))
    request = JuliaForever2.ModelRequest([Message(:user, "hello")], "request instructions",
        Dict("type" => "string"), Dict("type" => "text"), AdapterRequestPolicy())
    context = ExecutionContext()
    response = JuliaForever2.respond(provider, request, context)
    @test response.reply == Reply(:answer, "tluser")
    @test response.usage.input_tokens == 7
    @test only(requests)["messages"][1]["content"] == "request instructions"
    @test only(requests)["response_format"] == Dict("type" => "text")
    close(context)
end

@testset "Legacy calls and session turns account for provider usage once" begin
    answer = JSON.json(Dict("kind" => "answer", "content" => "finished"))
    choice = Dict("message" => Dict("content" => answer))
    body = JSON.json(Dict("choices" => [choice],
        "usage" => Dict("prompt_tokens" => 7, "completion_tokens" => 3)))
    provider = JuliaForever2.OpenRouterProvider("synthetic", "fixture",
        (arguments...) -> (status=200, body=body))
    kernel = JuliaForever2.default_kernel(provider)
    session = Session(kernel)
    @test run_turn!(session, "hello").ok
    @test session.usage.input_tokens == 7
    provider([Message(:user, "legacy call")], session)
    @test session.usage.input_tokens == 14
    close(session)
    close(kernel)
end

@testset "Coalesced protocol progress always publishes the final semantic snapshot" begin
    events = HarnessEvent[]
    context = ExecutionContext(; event_sink=event -> push!(events, event))
    stream = JuliaForever2.ChatGPTStream(context; progress_interval=Inf)
    decoder = JuliaForever2.SSEDecoder(stream)
    for fragment in ("{\"kind\":\"answer\",\"content\":\"hel", "lo\"}")
        data = JSON.json(Dict("type" => "response.output_text.delta", "delta" => fragment))
        write(decoder, "data: " * data * "\n\n")
    end
    write(decoder, "data: {\"type\":\"response.completed\"}\n\n")
    progress = filter(event -> event.kind == :response_progress, events)
    @test !isempty(progress)
    @test last(progress).data.progress.text == "hello"
    @test count(event -> event.kind == :provider_delta, events) == 2
    @test JuliaForever2.decode_reply(String(take!(stream.text))) == Reply(:answer, "hello")
    close(context)
end

@testset "Provider selection persists only successful installation" begin
    mktempdir() do directory
        kernel = JuliaForever2.default_kernel()
        @test JuliaForever2.provider_selection_snapshot(kernel).id == :demo
        @test JuliaForever2.select_provider!(kernel, :demo; dir=directory).ok
        @test strip(read(joinpath(directory, "provider"), String)) == "demo"
        @test !JuliaForever2.select_provider!(kernel, :missing_fixture; dir=directory).ok
        @test JuliaForever2.provider_selection_snapshot(kernel).id == :demo
        settings = JuliaForever2.provider_settings_snapshot(directory)
        @test any(setting -> setting.descriptor.id == :demo, settings)
        close(kernel)
        @test !JuliaForever2.select_provider!(kernel, :codex; dir=directory).ok
        @test strip(read(joinpath(directory, "provider"), String)) == "demo"
        @test JuliaForever2.provider_selection_snapshot(kernel).id == :none
    end
end

@testset "Application provider catalogs are independently composable" begin
    first_catalog = JuliaForever2.ProviderRegistry()
    second_catalog = JuliaForever2.ProviderRegistry()
    first_descriptor = JuliaForever2.ProviderDescriptor(:isolated_fixture, "First fixture",
        directory -> (source=:first, directory=directory))
    second_descriptor = JuliaForever2.ProviderDescriptor(:isolated_fixture, "Second fixture",
        directory -> (source=:second, directory=directory))
    JuliaForever2.register_provider!(first_catalog, first_descriptor)
    JuliaForever2.register_provider!(second_catalog, second_descriptor)
    @test JuliaForever2.provider_from_name(:isolated_fixture; registry=first_catalog).source == :first
    @test JuliaForever2.provider_from_name(:isolated_fixture; registry=second_catalog).source == :second
    @test isnothing(JuliaForever2.provider_descriptor(:isolated_fixture))
    JuliaForever2.unregister_provider!(first_catalog, :isolated_fixture)
    @test isempty(JuliaForever2.provider_descriptors(first_catalog))
    @test only(JuliaForever2.provider_descriptors(second_catalog)) === second_descriptor
end

JuliaForever2.authorization_url(::Val{:adapter_fixture}, attempt::JuliaForever2.OAuthAttempt) =
    "https://example.invalid/authorize?state=" * attempt.state

function JuliaForever2.complete_authorization!(::Val{:adapter_fixture}, directory, attempt, callback;
        transport, identity, context, persist)
    saved = persist(:adapter_fixture, Dict("code" => callback.code))
    return (ok=saved, reason=saved ? "Fixture connected." : "Sign-in cancelled.")
end

@testset "Authorization protocols extend without central provider branches" begin
    mktempdir() do directory
        attempt = JuliaForever2.oauth_attempt(:adapter_fixture,
            "http://127.0.0.1:12345/auth/callback")
        @test occursin(attempt.state, JuliaForever2.authorization_url(attempt))
        callback = (ok=true, code="fixture-code", client_id="", reason="")
        result = JuliaForever2.complete_authorization!(directory, attempt, callback)
        @test result.ok
        @test JuliaForever2.load_credentials(directory, :adapter_fixture)["code"] == "fixture-code"
    end
end

@testset "Authentication cancellation leaves resource draining to its owner" begin
    flow = JuliaForever2.AuthFlow()
    cleanup_started = Threads.Atomic{Bool}(false)
    finish_cleanup = Base.Event()
    JuliaForever2.own_resource!(flow.context, nothing; cleanup=value -> begin
        cleanup_started[] = true
        wait(finish_cleanup)
    end)
    cancellation = Threads.@spawn JuliaForever2.cancel_auth!(flow)
    @test timedwait(() -> istaskdone(cancellation), 3.0) == :ok
    @test !cleanup_started[]
    closing = Threads.@spawn close(flow)
    @test timedwait(() -> cleanup_started[], 3.0) == :ok
    notify(finish_cleanup)
    fetch(cancellation)
    fetch(closing)
    @test !JuliaForever2.active_auth(flow)
end
