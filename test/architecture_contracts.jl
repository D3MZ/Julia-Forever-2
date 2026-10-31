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
