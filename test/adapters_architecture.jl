using JSON

struct LegacyIdentityFixture end
JuliaForever2.provider_id(::LegacyIdentityFixture) = :legacy_fixture
JuliaForever2.provider_name(::LegacyIdentityFixture) = "Legacy fixture"
JuliaForever2.provider_detail(::LegacyIdentityFixture) = "Legacy detail"

@testset "Provider identity constructors preserve built-in and extension behavior" begin
    providers = (
        (JuliaForever2.DemoProvider(), :demo, "Demo"),
        (JuliaForever2.OpenRouterProvider("synthetic", "fixture"), :openrouter, "OpenRouter"),
        (JuliaForever2.CodexProvider("codex"; model="fixture"), :codex, "Codex"),
        (JuliaForever2.OpenAIProvider("unused"; model="fixture"), :chatgpt, "ChatGPT"),
    )
    for (provider, expected_id, expected_name) in providers
        identity = JuliaForever2.provider_identity(provider)
        @test identity isa JuliaForever2.ProviderIdentity
        @test identity.id == expected_id
        @test identity.name == expected_name
        @test JuliaForever2.provider_id(provider) == identity.id
        @test JuliaForever2.provider_name(provider) == identity.name
        @test JuliaForever2.provider_detail(provider) == identity.detail
    end

    legacy = JuliaForever2.provider_identity(LegacyIdentityFixture())
    @test (legacy.id, legacy.name, legacy.detail) ==
        (:legacy_fixture, "Legacy fixture", "Legacy detail")

    keyword = JuliaForever2.ProviderDescriptor(;
        id=:keyword_fixture, label="Keyword fixture", create=Returns(nothing))
    @test keyword.id == :keyword_fixture
    @test isnothing(keyword.auth)
    @test keyword.status("unused") == ""

    router = JuliaForever2.OpenRouterProvider("synthetic", "original")
    selected_router = JuliaForever2.select_model(router, "replacement")
    @test selected_router.model == "replacement"
    @test selected_router.transport === router.transport
    @test selected_router.policy === router.policy

    chatgpt = JuliaForever2.OpenAIProvider("unused"; model="original")
    selected_chatgpt = JuliaForever2.select_model(chatgpt, "replacement")
    @test selected_chatgpt.model == "replacement"
    @test selected_chatgpt.catalog === chatgpt.catalog
    @test selected_chatgpt.transport === chatgpt.transport
    @test selected_chatgpt.auth_transport === chatgpt.auth_transport
end

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

@testset "Provider lookup preserves descriptor identity and snapshot isolation" begin
    registry = JuliaForever2.ProviderRegistry()
    original = JuliaForever2.ProviderDescriptor(:lookup_fixture, "Original", directory -> :original)
    replacement = JuliaForever2.ProviderDescriptor(:lookup_fixture, "Replacement", directory -> :replacement)

    @test isnothing(JuliaForever2.provider_descriptor(registry, :lookup_fixture))
    JuliaForever2.register_provider!(registry, original)
    snapshot = JuliaForever2.provider_descriptors(registry)
    @test JuliaForever2.provider_descriptor(registry, :lookup_fixture) === original
    @test JuliaForever2.provider_from_name(:lookup_fixture; registry, dir="unused") == :original

    JuliaForever2.register_provider!(registry, replacement)
    @test JuliaForever2.provider_descriptor(registry, :lookup_fixture) === replacement
    @test JuliaForever2.provider_from_name(:lookup_fixture; registry, dir="unused") == :replacement
    @test only(snapshot) === original
    @test only(JuliaForever2.provider_descriptors(registry)) === replacement

    JuliaForever2.unregister_provider!(registry, :lookup_fixture)
    @test isnothing(JuliaForever2.provider_descriptor(registry, :lookup_fixture))
    @test isempty(JuliaForever2.provider_descriptors(registry))
    @test only(snapshot) === original
end

JuliaForever2.authorization_url(::Val{:adapter_fixture}, attempt::JuliaForever2.OAuthAttempt) = "https://example.invalid/authorize?state=" * attempt.state

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

@testset "Single-model lookups do not allocate registry-wide snapshots" begin
    model = JuliaForever2.ModelSpec(:catalog_target, "selected-model")
    factory = JuliaForever2.ProviderFactory(Returns(nothing); models=() -> [model])
    descriptor = JuliaForever2.ProviderDescriptor(:catalog_target, "Selected", factory)
    narrow = JuliaForever2.ProviderRegistry()
    wide = JuliaForever2.ProviderRegistry()
    for registry in (narrow, wide)
        JuliaForever2.register_provider!(registry, descriptor)
    end
    for index in 1:256
        JuliaForever2.register_provider!(wide,
            JuliaForever2.ProviderDescriptor(Symbol("other_model_", index), "Other", Returns(nothing)))
    end

    function count_model_lookups(registry, iterations)
        found = 0
        for _ in 1:iterations
            found += JuliaForever2.provider_model(registry, :catalog_target, "selected-model") === model
        end
        return found
    end

    repetitions = 100
    @test count_model_lookups(narrow, repetitions) == repetitions
    @test count_model_lookups(wide, repetitions) == repetitions
    @test JuliaForever2.provider_model(wide, :catalog_target, "selected-model"; kind=:all) === model
    @test isnothing(JuliaForever2.provider_model(wide, :catalog_target, "selected-model"; kind=:embedding))
    @test isnothing(JuliaForever2.provider_model(wide, :catalog_target, "unknown"))
    GC.gc()
    narrow_bytes = @allocated count_model_lookups(narrow, repetitions)
    GC.gc()
    wide_bytes = @allocated count_model_lookups(wide, repetitions)
    println("Single-model lookup allocations over ", repetitions, " warmed calls: ",
        "1 registered provider=", narrow_bytes, " bytes; ",
        "257 registered providers=", wide_bytes, " bytes; target growth <= 32768 bytes")
    @test wide_bytes <= narrow_bytes + 32_768
end

@testset "Filtered model catalogs avoid unrelated registry snapshots" begin
    model = JuliaForever2.ModelSpec(:filtered_catalog_target, "selected-model")
    embedding = JuliaForever2.ModelSpec(:filtered_catalog_target, "vector-model"; kind=:embedding)
    factory = JuliaForever2.ProviderFactory(Returns(nothing); models=() -> [model, embedding])
    descriptor = JuliaForever2.ProviderDescriptor(:filtered_catalog_target, "Target", factory)
    narrow = JuliaForever2.ProviderRegistry()
    wide = JuliaForever2.ProviderRegistry()
    for registry in (narrow, wide)
        JuliaForever2.register_provider!(registry, descriptor)
    end
    for index in 1:256
        JuliaForever2.register_provider!(wide,
            JuliaForever2.ProviderDescriptor(Symbol("unrelated_catalog_", index), "Unrelated", Returns(nothing)))
    end

    @test JuliaForever2.provider_models(narrow; provider=:filtered_catalog_target) == [model]
    @test JuliaForever2.provider_models(wide; provider="filtered_catalog_target", kind=:all) == [model, embedding]
    @test JuliaForever2.provider_models(wide; provider=:filtered_catalog_target, kind=:embedding) == [embedding]
    @test isempty(JuliaForever2.provider_models(wide; provider=:missing_catalog))
    @test JuliaForever2.provider_models(wide; kind=:all) == [model, embedding]

    function count_filtered_models(registry, iterations)
        matches = 0
        for _ in 1:iterations
            models = JuliaForever2.provider_models(registry; provider=:filtered_catalog_target)
            matches += (length(models) == 1 && only(models) === model)
        end
        return matches
    end

    repetitions = 100
    @test count_filtered_models(narrow, repetitions) == repetitions
    @test count_filtered_models(wide, repetitions) == repetitions
    GC.gc()
    narrow_bytes = @allocated count_filtered_models(narrow, repetitions)
    GC.gc()
    wide_bytes = @allocated count_filtered_models(wide, repetitions)
    println("Filtered provider catalog allocations over ", repetitions, " warmed calls: ",
        "1 provider=", narrow_bytes, " bytes; 257 providers=", wide_bytes,
        " bytes; target growth <= 32768 bytes")
    @test wide_bytes <= narrow_bytes + 32_768
end
