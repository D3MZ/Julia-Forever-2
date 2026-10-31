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
