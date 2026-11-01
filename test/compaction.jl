using JSON
using JuliaForever2: ModelSpec, ModelProvider, ModelRequest, ProviderFactory, ProviderDescriptor,
    ProviderRegistry, register_provider!, provider_model, model_context_window, model_output_limit,
    refresh_pi_model_catalog!, CompactionSettings, resolved_compaction, context_messages,
    compact!, compaction_snapshot, SessionStore, save_session!, load_session

struct CompactionFixtureProvider
    model::ModelSpec
    requests::Vector{ModelRequest}
end

function JuliaForever2.respond(provider::CompactionFixtureProvider, request::ModelRequest,
        context::ExecutionContext)
    push!(provider.requests, request)
    if occursin("Summarize", request.instructions)
        return JuliaForever2.ProviderResult(Reply(:answer, "Verified condensed history"), nothing)
    end
    return JuliaForever2.ProviderResult(Reply(:answer, "finished"), nothing)
end

@testset "Pi model limits are metadata, never invented defaults" begin
    model = ModelSpec(:fixture, "code/large"; metadata=Dict(
        "contextWindow" => 128_000, "maxTokens" => 16_384))
    @test model_context_window(model) == 128_000
    @test model_output_limit(model) == 16_384
    @test model_context_window(ModelProvider(model, Returns(nothing))) == 128_000
    @test isnothing(model_context_window(ModelSpec(:fixture, "unknown")))
    @test isnothing(model_context_window(ModelSpec(:fixture, "invalid";
        metadata=Dict("contextWindow" => "128000", "maxTokens" => true))))
    @test isnothing(model_output_limit(ModelSpec(:fixture, "invalid";
        metadata=Dict("maxTokens" => -1))))
end

@testset "Compaction defaults and exact provider/model overrides" begin
    defaults = CompactionSettings()
    @test defaults.enabled
    @test defaults.reserve_tokens == 16_384
    @test defaults.keep_recent_tokens == 20_000
    model = ModelSpec(:fixture, "code/large"; metadata=Dict("contextWindow" => 128_000))
    ordinary = resolved_compaction(defaults, model)
    @test ordinary.reserve_tokens == 16_384
    @test ordinary.keep_recent_tokens == 20_000
    custom = CompactionSettings(; reserve_tokens=1000, keep_recent_tokens=800,
        model_overrides=Dict("fixture/code/large" => Dict("reserveTokens" => 5000),
            "other/code/large" => Dict("reserveTokens" => 3000)))
    selected = resolved_compaction(custom, model)
    @test selected.reserve_tokens == 5000
    @test selected.keep_recent_tokens == 800
    @test resolved_compaction(custom, ModelSpec(:fixture, "else")).reserve_tokens == 1000
    @test_throws ErrorException CompactionSettings(; reserve_tokens=-1)
    @test_throws ErrorException CompactionSettings(; keep_recent_tokens=true)
    @test_throws ErrorException resolved_compaction(
        CompactionSettings(; model_overrides=Dict("fixture/code/large" =>
            Dict("reserveTokens" => "invalid"))), model)
end

@testset "Explicit catalog refresh publishes validated provider model limits" begin
    registry = ProviderRegistry()
    factory = ProviderFactory(_ -> nothing; models=Returns(ModelSpec[]))
    register_provider!(registry, ProviderDescriptor(:fixture, "Fixture", factory))
    original = provider_model(registry, :fixture, "code/large")
    @test isnothing(original)
    payload = JSON.json(Dict("models" => [Dict("id" => "code/large",
        "contextWindow" => 200_000, "maxTokens" => 12_000)]))
    requested = String[]
    fetched = url -> (push!(requested, url); payload)
    result = refresh_pi_model_catalog!(registry, :fixture; fetcher=fetched)
    @test result.ok
    @test requested == ["https://pi.dev/api/models/providers/fixture"]
    selected = provider_model(registry, :fixture, "code/large")
    @test selected isa ModelSpec
    @test model_context_window(selected) == 200_000
    @test model_output_limit(selected) == 12_000
    @test JuliaForever2.pi_catalog_provider(:codex) == "openai-codex"
    @test JuliaForever2.pi_catalog_provider(:chatgpt) == "openai-codex"
    @test JuliaForever2.pi_catalog_provider(:openrouter) == "openrouter"
    @test !refresh_pi_model_catalog!(registry, :fixture;
        fetcher=_ -> """{"models":[{"id":"bad","contextWindow":-1}]}""").ok
    @test model_context_window(provider_model(registry, :fixture, "code/large")) == 200_000
end

@testset "Manual compaction retains original history, preserves newest turn and tracks revisions" begin
    model = ModelSpec(:fixture, "code/large"; metadata=Dict("contextWindow" => 40_000))
    provider = CompactionFixtureProvider(model, ModelRequest[])
    session = Session(Kernel(provider); compaction=CompactionSettings(; keep_recent_tokens=0))
    for (role, text) in ((:user, "first"), (:assistant, "reply"),
            (:user, "second"), (:assistant, "reply2"), (:user, "current"))
        JuliaForever2.append_message!(session, Message(role, text))
    end
    original = [message.content for message in JuliaForever2.history_snapshot(session).messages]
    summarized = Vector{Vector{String}}()
    summarize = messages -> (push!(summarized, getproperty.(messages, :content)); "condensed")
    @test compact!(session; summarize).status == :compacted
    @test [message.content for message in JuliaForever2.history_snapshot(session).messages] == original
    @test [message.content for message in context_messages(session)] == ["condensed", "current"]
    @test compaction_snapshot(session).first_kept == 5
    JuliaForever2.append_message!(session, Message(:assistant, "third"))
    JuliaForever2.append_message!(session, Message(:user, "next"))
    @test compact!(session; summarize).status == :compacted
    @test summarized[2][1] == "condensed"
    @test [message.content for message in context_messages(session)] == ["condensed", "next"]
    @test compaction_snapshot(session).first_kept == 7
    @test compact!(session; summarize=_->"").status == :nothing_to_compact
    JuliaForever2.clear_history!(session)
    @test isnothing(compaction_snapshot(session))
    @test isempty(context_messages(session))
    close(session)
end

@testset "Compaction fails atomically on concurrent revision changes" begin
    provider = CompactionFixtureProvider(ModelSpec(:fixture, "tiny"), ModelRequest[])
    session = Session(Kernel(provider); compaction=CompactionSettings(; keep_recent_tokens=0),
        messages=[Message(:user, "old"), Message(:assistant, "reply"), Message(:user, "now")])
    summarize = messages -> begin
        JuliaForever2.append_message!(session, Message(:user, "concurrent"))
        "summary"
    end
    @test compact!(session; summarize).status == :revision_conflict
    @test isnothing(compaction_snapshot(session))
    @test length(context_messages(session)) == 4
    @test compact!(session; summarize=_->"").status == :summary_failed
    @test isnothing(compaction_snapshot(session))
    close(session)
end

@testset "Saved sessions restore the active compacted projection" begin
    provider = CompactionFixtureProvider(ModelSpec(:fixture, "tiny"), ModelRequest[])
    mktempdir() do directory
        session = Session(Kernel(provider); compaction=CompactionSettings(; keep_recent_tokens=0),
            messages=[Message(:user, "old"), Message(:assistant, "reply"), Message(:user, "new")])
        @test compact!(session; summarize=_->"saved").status == :compacted
        store = SessionStore(directory)
        @test save_session!(store, "compact", session).ok
        restored = load_session(store, "compact", Kernel(provider))
        @test [message.content for message in context_messages(restored)] == ["saved", "new"]
        @test length(JuliaForever2.history_snapshot(restored).messages) == 3
        @test compaction_snapshot(restored).first_kept == 3
        close(restored)
        close(session)
    end
end

@testset "Automatic compaction runs before the next model request" begin
    model = ModelSpec(:fixture, "small"; metadata=Dict("contextWindow" => 1200))
    provider = CompactionFixtureProvider(model, ModelRequest[])
    session = Session(Kernel(provider); compaction=CompactionSettings(;
        reserve_tokens=100, keep_recent_tokens=0),
        messages=[Message(:user, repeat("old ", 1000)), Message(:assistant, "previous answer")])
    @test run_turn!(session, "What now?").ok
    @test length(provider.requests) == 2
    @test occursin("Summarize", provider.requests[1].instructions)
    @test [message.content for message in provider.requests[2].messages] ==
        ["Verified condensed history", "What now?"]
    @test length(JuliaForever2.history_snapshot(session).messages) == 4
    @test compaction_snapshot(session).first_kept == 3
    close(session)

    unknown = CompactionFixtureProvider(ModelSpec(:fixture, "unknown"), ModelRequest[])
    session = Session(Kernel(unknown); messages=[
        Message(:user, repeat("old ", 1000)), Message(:assistant, "previous answer")])
    @test run_turn!(session, "What now?").ok
    @test length(unknown.requests) == 1
    @test isnothing(compaction_snapshot(session))
    close(session)
end


mutable struct OverflowFixtureProvider
    model::ModelSpec
    requests::Vector{ModelRequest}
    first_error::String
    turn_requests::Int
end

function JuliaForever2.respond(provider::OverflowFixtureProvider, request::ModelRequest,
        context::ExecutionContext)
    push!(provider.requests, request)
    if occursin("Summarize", request.instructions)
        JuliaForever2.ProviderResult(Reply(:answer, "Recovered context summary"), nothing)
    else
        provider.turn_requests += 1
        answer = provider.turn_requests == 1 ?
            Reply(:error, provider.first_error) : Reply(:answer, "Recovered")
        JuliaForever2.ProviderResult(answer, nothing)
    end
end

@testset "One overflow compact-and-retry, other errors never retried" begin
    for (failure, expected_count, works) in (("context_length_exceeded", 3, true),
            ("Request failed: HTTP 413", 3, true), ("Server timed out", 1, false))
        provider = OverflowFixtureProvider(ModelSpec(:fixture, "unknown"),
            ModelRequest[], failure, 0)
        session = Session(Kernel(provider); compaction=CompactionSettings(;
            keep_recent_tokens=0), messages=[Message(:user, "old"),
                Message(:assistant, "earlier"), Message(:user, "latest")])
        result = run_turn!(session, "New question")
        @test result.ok == works
        @test length(provider.requests) == expected_count
        @test provider.turn_requests == (works ? 2 : 1)
        @test isnothing(compaction_snapshot(session)) == !works
        if works
            @test [message.content for message in provider.requests[end].messages] ==
                ["Recovered context summary", "New question"]
        end
        close(session)
    end
end

@testset "Disabled automatic compaction preserves complete model context" begin
    provider = CompactionFixtureProvider(ModelSpec(:fixture, "small";
        metadata=Dict("contextWindow" => 1000)), ModelRequest[])
    session = Session(Kernel(provider); compaction=CompactionSettings(;
        enabled=false, reserve_tokens=100), messages=[
        Message(:user, repeat("prior ", 1000)), Message(:assistant, "previous")])
    @test run_turn!(session, "Current").ok
    @test length(provider.requests) == 1
    @test isnothing(compaction_snapshot(session))
    @test length(only(provider.requests).messages) == 3
    close(session)
end
