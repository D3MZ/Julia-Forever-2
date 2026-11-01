struct ExplicitRequestProtocol
    instructions::String
end

@testset "Accounting snapshots remain stable while a conversation advances" begin
    conversation = Conversation()
    @test JuliaForever2.usage_label(conversation) == ""
    JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(12, 4, 0.25))
    first_usage = JuliaForever2.usage_snapshot(conversation)
    @test JuliaForever2.usage_label(first_usage) == "↑12 ↓4 \$0.25"
    JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(5, 2, nothing))
    @test first_usage.input_tokens == 12
    @test first_usage.cost_known
    @test JuliaForever2.usage_snapshot(conversation).input_tokens == 17
    @test !JuliaForever2.usage_snapshot(conversation).cost_known
    @test JuliaForever2.usage_label(conversation) == "↑17 ↓6"
end

JuliaForever2.prompt_instructions(protocol::ExplicitRequestProtocol, capabilities) = protocol.instructions
JuliaForever2.reply_schema(::ExplicitRequestProtocol) = (type="object", required=["operation"])
JuliaForever2.reply_format(::ExplicitRequestProtocol) = (type="json_object",)

@testset "Conversation snapshots are independent of caller mutations" begin
    conversation = Conversation()
    JuliaForever2.append_message!(conversation, Message(:user, "first"))
    first_snapshot = JuliaForever2.history_snapshot(conversation)
    empty!(first_snapshot.messages)
    @test length(JuliaForever2.history_snapshot(conversation).messages) == 1
    @test isnothing(JuliaForever2.history_snapshot(conversation, first_snapshot.revision))

    JuliaForever2.append_message!(conversation, Message(:assistant, "second", :answer))
    appended = JuliaForever2.history_snapshot(conversation, first_snapshot.revision)
    @test appended.changed_from == 2
    @test [message.content for message in appended.messages] == ["first", "second"]
    JuliaForever2.replace_message!(conversation, 1, Message(:user, "revised"))
    revised = JuliaForever2.history_snapshot(conversation, appended.revision)
    @test revised.changed_from == 1
    @test appended.messages[1].content == "first"
    @test revised.messages[1].content == "revised"

    JuliaForever2.clear_history!(conversation)
    cleared = JuliaForever2.history_snapshot(conversation, revised.revision)
    @test isempty(cleared.messages)
    @test cleared.changed_from == 1
end

@testset "Request protocols specify model input without runtime access" begin
    protocol = ExplicitRequestProtocol("Perform the requested operation.")
    messages = [Message(:user, "compute")]
    request = JuliaForever2.model_request(protocol, messages)
    @test request.instructions == protocol.instructions
    @test request.schema == (type="object", required=["operation"])
    @test request.response_format == (type="json_object",)
    @test request.protocol === protocol
    @test request.messages == messages
    @test !hasproperty(request, :session)
    @test !hasproperty(request, :runtime)
end

@testset "Legacy replies retain explicit typed decision meaning" begin
    answer = JuliaForever2.agent_decision(Reply(:answer, "finished"))
    @test answer isa Answer
    @test answer.content == "finished"
    action = JuliaForever2.agent_decision(Reply(:code, "6 * 7"))
    @test action isa ActionDecision{RunJulia}
    @test action.action.source == "6 * 7"
    failure = JuliaForever2.agent_decision(Reply(:error, "provider failed"))
    @test failure isa Failure
    @test failure.content == "provider failed"
    @test JuliaForever2.agent_decision(Reply(:unsupported, "payload")) isa Failure
    @test JuliaForever2.agent_decision(JuliaForever2.decode_reply("malformed")) isa Failure
end

@testset "Typed Julia actions work through direct and queued execution" begin
    session = Session(Kernel())
    direct = JuliaForever2.evaluate!(session, RunJulia("typed_value = 6 * 7"))
    @test direct.ok
    @test direct.value == 42
    queued = fetch(JuliaForever2.submit_evaluation!(session, RunJulia("typed_value + 1")))
    @test queued.ok
    @test queued.value == 43
    @test JuliaForever2.history_snapshot(session).messages[end].metadata === queued
    close(session)
end

@testset "Accumulated provider costs remain representable" begin
    conversation = Conversation()
    maximum = floatmax(Float64)
    JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(2, 3, maximum))
    @test JuliaForever2.usage_snapshot(conversation).cost_known

    # Both reported values are finite, but their Float64 sum is not.
    JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(4, 5, maximum))
    totals = JuliaForever2.usage_snapshot(conversation)
    @test totals.input_tokens == 6
    @test totals.output_tokens == 8
    @test !totals.cost_known
    @test isfinite(totals.cost)
    @test totals.cost == maximum

    JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(1, 1, 0.25))
    @test !JuliaForever2.usage_snapshot(conversation).cost_known

    ordinary = Conversation()
    JuliaForever2.record_usage!(ordinary, JuliaForever2.UsageReport(1, 2, 0.25))
    JuliaForever2.record_usage!(ordinary, JuliaForever2.UsageReport(3, 4, 0.5))
    @test JuliaForever2.usage_snapshot(ordinary).cost == 0.75
    @test JuliaForever2.usage_snapshot(ordinary).cost_known
end

@testset "Accumulated token counts do not overflow" begin
    for (initial_input, initial_output) in ((typemax(Int), 5), (5, typemax(Int)))
        conversation = Conversation()
        JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(initial_input, initial_output, 0.25))
        JuliaForever2.record_usage!(conversation, JuliaForever2.UsageReport(1, 2, 0.5))
        totals = JuliaForever2.usage_snapshot(conversation)
        # An unrepresentable pair must not corrupt either counter.
        @test (totals.input_tokens, totals.output_tokens) == (initial_input, initial_output)
        @test totals.partial
        @test totals.reported
        @test totals.cost == 0.75
        @test totals.cost_known
    end
end

@testset "Typed provider usage reports cannot corrupt accounting" begin
    invalid_tokens = Conversation()
    JuliaForever2.record_usage!(invalid_tokens, JuliaForever2.UsageReport(-4, 3, 0.25))
    tokens = JuliaForever2.usage_snapshot(invalid_tokens)
    @test tokens.input_tokens == 0
    @test tokens.output_tokens == 0
    @test tokens.partial
    @test !tokens.reported
    @test tokens.cost == 0.25
    @test tokens.cost_known

    invalid_cost = Conversation()
    JuliaForever2.record_usage!(invalid_cost, JuliaForever2.UsageReport(2, 3, -0.5))
    cost = JuliaForever2.usage_snapshot(invalid_cost)
    @test cost.input_tokens == 2
    @test cost.output_tokens == 3
    @test cost.reported
    @test !cost.cost_known
    @test cost.cost == 0.0
end

@testset "Typed and dictionary provider usage share validation" begin
    for (input, output, cost) in ((-4, 3, 0.25), (2, 3, -0.5),
            (2, 3, 0.5), (2, -3, nothing))
        typed = Conversation()
        raw = Conversation()
        JuliaForever2.record_usage!(typed, JuliaForever2.UsageReport(input, output, cost))
        JuliaForever2.record_usage!(raw, Dict("input_tokens" => input,
            "output_tokens" => output, "cost" => cost))
        @test JuliaForever2.usage_snapshot(typed) == JuliaForever2.usage_snapshot(raw)
    end
end
