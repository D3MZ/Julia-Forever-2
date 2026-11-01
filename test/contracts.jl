include("fixtures/ForeignHarnessPlugin.jl")

@testset "External provider and executor contracts" begin
    events = HarnessEvent[]
    provider = ForeignHarnessPlugin.ForeignProvider((messages, context) ->
        messages[end].role == :code_result ? Reply(:answer, "complete") : Reply(:code, "custom action"))
    executor = ForeignHarnessPlugin.ForeignExecutor(String[])
    kernel = JuliaForever2.default_kernel(provider)
    session = Session(kernel; executor)
    context = ExecutionContext(; emit=event -> push!(events, event))
    result = run_turn!(session, "compute"; context)
    @test result.ok && result.text == "complete"
    @test executor.actions == ["custom action"]
    execution = JuliaForever2.message_result(session.messages[3])
    @test execution.ok
    @test execution.value == (answer=42,)
    @test any(event -> event.kind == :foreign_execution, events)
end

@testset "Backend-owned non-text actions specialize" begin
    executor = ForeignHarnessPlugin.ForeignExecutor(Tuple{Symbol,Int}[])
    session = Session(Kernel(); executor)
    context = ExecutionContext()
    result = @inferred JuliaForever2.execute!(executor, session, (:compute, 42), context)
    @test result.value == (answer=42,)
    @test fetch(submit_evaluation!(session, (:compute, 7))).ok
    @test executor.actions == [(:compute, 42), (:compute, 7)]
    close(session)
end

@testset "Independently composed loop wrappers" begin
    seen = Symbol[]
    kernel = JuliaForever2.default_kernel(ForeignHarnessPlugin.ForeignProvider((messages, context) -> Reply(:answer, "ok")))
    wrap_component!(inner -> ForeignHarnessPlugin.TaggedLoop(inner, seen, :first), kernel, :loop)
    wrap_component!(inner -> ForeignHarnessPlugin.TaggedLoop(inner, seen, :second), kernel, :loop)
    @test run_turn!(Session(kernel), "hello").ok
    @test seen == [:second, :first]
    close(kernel)
end

@testset "Constructor-driven result and decision transitions" begin
    result = ExecutionResult(true, "computed", (answer=42,))
    @test ExecutionResult(result) === result
    @test ExecutionResult((ok=true, text="computed", value=(answer=42,))).value == (answer=42,)
    @test ExecutionResult(Answer("complete")).ok
    @test !ExecutionResult(Failure("denied")).ok
    @test Message(Answer("complete")).kind == :answer
    @test Message(Answer("complete")).content == "complete"
    @test Message(ActionDecision(RunJulia("1 + 1"))).kind == :code
    @test JuliaForever2.AgentDecision(Reply(:answer, "complete")) isa Answer
    @test JuliaForever2.AgentDecision(Reply(:code, "1 + 1")).action isa RunJulia
    @test JuliaForever2.AgentDecision(Reply(:unsupported, "unused")) isa Failure
end

@testset "Usage report constructors preserve raw accounting contracts" begin
    report = JuliaForever2.UsageReport(-2, 4, Inf)
    @test report.input_tokens == -2
    @test report.output_tokens == 4
    @test report.cost == Inf
    conversation = Conversation()
    JuliaForever2.record_usage!(conversation, report)
    accounting = JuliaForever2.usage_snapshot(conversation)
    @test accounting.partial
    @test !accounting.reported
    @test !accounting.cost_known
    valid = JuliaForever2.UsageReport(2, 4, 0.25)
    @test JuliaForever2.UsageReport(valid) === valid
    @test JuliaForever2.UsageReport(Dict("input_tokens" => 2, "output_tokens" => 4, "cost" => 0.25)) === valid
    @test JuliaForever2.UsageReport(nothing) === JuliaForever2.UsageReport()
end

@testset "Constructors compose definitions and independent profiles" begin
    provider = (messages, session) -> Answer("constructed")
    definition = AgentDefinition(provider)
    kernel = Kernel(definition)
    @test component(kernel, :provider) === provider
    @test run_turn!(Session(kernel), "hello").text == "constructed"
    close(kernel)
    first = JuliaForever2.Profile(:first, [:alpha]; config=Dict(:alpha => Dict("value" => 1)))
    second = JuliaForever2.Profile(:second, [:beta, :alpha]; bindings=Dict(:service => :alpha))
    combined = JuliaForever2.Profile(:combined, first, second)
    @test combined.plugins == [:alpha, :beta]
    @test combined.bindings == Dict(:service => :alpha)
    copied = JuliaForever2.Profile(combined)
    copied.config[:alpha]["value"] = 2
    @test combined.config[:alpha]["value"] == 1
end
