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

@testset "Usage reports preserve provider fields until accounting" begin
    report = JuliaForever2.UsageReport(-2, 4, Inf)
    @test report.input_tokens == -2
    @test report.output_tokens == 4
    @test report.cost == Inf
    @test JuliaForever2.normalize_usage(report) === report
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
    @test JuliaForever2.UsageReport(-4, 3, 0.25).input_tokens == -4
    @test JuliaForever2.UsageReport(2, 3, -0.5).cost == -0.5
    dictionary = Dict("input_tokens" => -2, "output_tokens" => 4, "cost" => Inf)
    normalized = JuliaForever2.normalize_usage(dictionary)
    @test isnothing(normalized.input_tokens)
    @test normalized.output_tokens == 4
    @test isnothing(normalized.cost)
    malformed = Dict("input_tokens" => "invalid", "output_tokens" => 4, "cost" => true)
    parsed = JuliaForever2.UsageReport(malformed)
    @test isnothing(parsed.input_tokens)
    @test parsed.output_tokens == 4
    @test isnothing(parsed.cost)
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


@testset "Inner constructors reject invalid domain states" begin
    @test_throws ErrorException JuliaForever2.ToolBatch(JuliaForever2.ToolCall[], 0)
    @test_throws ErrorException JuliaForever2.ToolBatch(JuliaForever2.ToolCall[], -1)
    @test JuliaForever2.ToolBatch(JuliaForever2.ToolCall[], 1).max_parallel == 1
    invalid = Dict("type" => "unrecognized")
    @test_throws ErrorException JuliaForever2.CheckedJSONSchema{typeof(invalid)}(invalid)
    source = Dict("type" => "string")
    schema = JuliaForever2.CheckedJSONSchema(source)
    source["type"] = "invalid"
    @test schema.definition["type"] == "string"
    @test_throws ErrorException JuliaForever2.StringEscape(nothing, 1, :complete)
    @test_throws ErrorException JuliaForever2.StringEscape('a', 1, :invalid)
    @test JuliaForever2.StringEscape('a', 1, :complete).value == 'a'
    mktempdir() do directory
        @test JuliaForever2.Workspace(SubString(directory)).path == realpath(directory)
        @test_throws ErrorException JuliaForever2.Workspace(joinpath(directory, "missing"))
        session = Session(Kernel(); working_directory=directory)
        @test JuliaForever2.working_directory(session) == realpath(directory)
        close(session)
    end
end

struct UnreadResponse end
JuliaForever2.response_reply(::UnreadResponse) = error("Cancelled responses must not be decoded")

@testset "Cancellation precedes response conversion" begin
    session = Session(Kernel())
    context = ExecutionContext()
    cancel!(context)
    result = JuliaForever2.consume!(session, UnreadResponse(), context)
    @test !result.ok
    @test isempty(session.messages)
    close(context)
    close(session)
end

struct CustomDecisionResponse
    text::String
end

JuliaForever2.agent_decision(response::CustomDecisionResponse) = Answer(response.text)

@testset "Decision constructors preserve external conversion methods" begin
    response = CustomDecisionResponse("external")
    @test JuliaForever2.AgentDecision(response) == Answer("external")
    @test JuliaForever2.AgentDecision(Answer("identity")) == Answer("identity")
    @test JuliaForever2.AgentDecision(RunJulia("1 + 1")).action.source == "1 + 1"
end

@testset "Keyword defaults preserve constructor APIs and fresh state" begin
    usage = JuliaForever2.Usage()
    @test usage.input_tokens == 0
    @test usage.cost_known
    @test JuliaForever2.Usage(input_tokens=7, partial=true).input_tokens == 7

    first_kernel, second_kernel = Kernel(), Kernel()
    @test first_kernel.entries !== second_kernel.entries
    @test Kernel(closed=true).closed
    first_plugins, second_plugins = JuliaForever2.PluginRegistry(), JuliaForever2.PluginRegistry()
    @test first_plugins.plugins !== second_plugins.plugins
    first_providers, second_providers = JuliaForever2.ProviderRegistry(), JuliaForever2.ProviderRegistry()
    @test first_providers.descriptors !== second_providers.descriptors

    first_catalog, second_catalog = JuliaForever2.ModelCatalog(), JuliaForever2.ModelCatalog()
    @test first_catalog.models !== second_catalog.models
    @test JuliaForever2.ModelCatalog(expires_at=4.5).expires_at == 4.5
    first_store, second_store = JuliaForever2.MemoryModelStore(), JuliaForever2.MemoryModelStore()
    @test first_store.entries !== second_store.entries

    factory = JuliaForever2.ProviderFactory(identity)
    @test isempty(factory.models())
    @test isnothing(factory.select())
    @test JuliaForever2.ProviderFactory(; create=identity).create === identity

    provider = (messages, session) -> Answer("ok")
    definition = AgentDefinition(provider; wrappers=[identity])
    @test definition.wrappers == (identity,)
    @test definition.executor_factory === JuliaForever2.JuliaExecutor
    @test definition.protocol == JuliaForever2.provider_protocol(provider)
    @test AgentDefinition(; provider, protocol=:custom).protocol == :custom

    registration = JuliaForever2.ResourceRegistration(:example, Returns(nothing))
    @test registration.active
    @test registration.lock isa ReentrantLock
    @test !JuliaForever2.ResourceRegistration(; value=:example, cleanup=Returns(nothing), active=false).active
end

@testset "Type-dispatched validation retains JSON and protocol semantics" begin
    @test JuliaForever2.validindex(nothing)
    @test JuliaForever2.validindex(1)
    @test !JuliaForever2.validindex(0)
    @test !JuliaForever2.validindex(true)
    @test !JuliaForever2.validindex(1.0)

    @test JuliaForever2.json_number(1.25)
    @test !JuliaForever2.json_number(true)
    @test !JuliaForever2.json_number(-0.0)
    @test !JuliaForever2.json_number(Inf)
    @test !JuliaForever2.json_number("1")
    @test JuliaForever2.json_object((value=1,))
    @test JuliaForever2.json_object(Dict("value" => 1))
    @test !JuliaForever2.json_object([1])
    @test JuliaForever2.json_scalar_equal(1, 1.0)
    @test JuliaForever2.json_scalar_equal(true, true)
    @test !JuliaForever2.json_scalar_equal(true, 1)
    @test !JuliaForever2.json_scalar_equal(1, true)
    @test JuliaForever2.entry_patch_equal(1, 1.0)
    @test !JuliaForever2.entry_patch_equal(true, 1)

    @test JuliaForever2.JSONRPCTransport.rpc_id("request")
    @test JuliaForever2.JSONRPCTransport.rpc_id(2)
    @test !JuliaForever2.JSONRPCTransport.rpc_id(true)
    @test !JuliaForever2.JSONRPCTransport.rpc_id(nothing)
    @test isnothing(JuliaForever2.JSONRPCTransport.rpc_error_code(false))
    @test JuliaForever2.JSONRPCTransport.rpc_error_code(3) == 3
    @test JuliaForever2.JSONRPCTransport.rpc_error_message(4) == "JSON-RPC error"

    @test JuliaForever2.lifetime(120)
    @test !JuliaForever2.lifetime(true)
    @test !JuliaForever2.lifetime(0)
    @test !JuliaForever2.lifetime("120")

    metadata = Dict("family" => "example")
    @test JuliaForever2.model_metadata_value(metadata) === metadata
    @test isempty(JuliaForever2.model_metadata_value(nothing))
    @test JuliaForever2.model_request_options(metadata, nothing, nothing) === metadata
    @test JuliaForever2.model_request_options((model, request) -> (dynamic=true,), nothing, nothing) == (dynamic=true,)

    @test isnothing(JuliaForever2.codex_completed_usage("other"))
    @test isnothing(JuliaForever2.codex_completed_usage(Dict("type" => "turn.started")))
    completed = JuliaForever2.codex_completed_usage(Dict("type" => "turn.completed", "usage" => Dict("input_tokens" => 7)))
    @test completed.input_tokens == 7
end

@testset "Conversation mutations expose their updated state for composition" begin
    conversation = Conversation()
    first = JuliaForever2.UsageReport(2, 3, 0.25)
    @test JuliaForever2.record_usage!(conversation, first) === conversation
    @test JuliaForever2.record_usage!(conversation,
        Dict("input_tokens" => 4, "output_tokens" => 5, "cost" => 0.5)) === conversation
    accounting = JuliaForever2.usage_snapshot(conversation)
    @test accounting == (input_tokens=6, output_tokens=8,
        cache_read_tokens=0, cache_write_tokens=0, context_tokens=4, cache_hit_rate=0.0,
        cost=0.75, reported=true, cost_known=true, partial=false)

    JuliaForever2.append_message!(conversation, Message(:user, "previous message"))
    revision = JuliaForever2.history_revision(conversation)
    @test JuliaForever2.clear_history!(conversation) === conversation
    cleared = JuliaForever2.history_snapshot(conversation)
    @test isempty(cleared.messages)
    @test cleared.changed_from == 1
    @test cleared.revision == revision + UInt(1)
    cleared_accounting = JuliaForever2.usage_snapshot(conversation)
    @test cleared_accounting.context_tokens === nothing
    @test merge(cleared_accounting, (context_tokens=accounting.context_tokens,)) == accounting
end

@testset "JSON-RPC peer keyword construction and isolated mutable defaults" begin
    legacy_input, legacy_output = IOBuffer(), IOBuffer()
    legacy = JuliaForever2.JsonRpcPeer(legacy_input, legacy_output)
    @test legacy isa JuliaForever2.JsonRpcPeer{typeof(legacy_input),typeof(legacy_output)}
    @test legacy.input === legacy_input
    @test legacy.output === legacy_output
    @test isnothing(legacy.on_request)
    @test isnothing(legacy.on_notification)

    input, output = IOBuffer(), IOBuffer()
    on_request = (method, params) -> (method=method, params=params)
    on_notification = (method, params) -> nothing
    peer = JuliaForever2.JsonRpcPeer(; input, output, on_request, on_notification)
    @test peer isa JuliaForever2.JsonRpcPeer{typeof(input),typeof(output)}
    @test peer.input === input
    @test peer.output === output
    @test peer.on_request === on_request
    @test peer.on_notification === on_notification
    @test isopen(peer)
    @test isempty(peer.buffer) && isempty(peer.pending) && isempty(peer.handlers)
    @test isnothing(peer.reader) && isnothing(peer.reader_worker) && isnothing(peer.failure)
    @test peer.lock !== legacy.lock
    @test peer.write_lock !== legacy.write_lock
    @test peer.buffer !== legacy.buffer
    @test peer.pending !== legacy.pending
    @test peer.handlers !== legacy.handlers
    push!(peer.buffer, 0x42)
    @test isempty(legacy.buffer)

    callbacks = JuliaForever2.JsonRpcPeer(IOBuffer(), IOBuffer(); on_request, on_notification)
    @test callbacks.on_request === on_request
    @test callbacks.on_notification === on_notification
    @test_throws UndefKeywordError JuliaForever2.JsonRpcPeer(; input)
    @test_throws UndefKeywordError JuliaForever2.JsonRpcPeer(; output)
    @test_throws MethodError JuliaForever2.JsonRpcPeer(; input, output, unsupported=true)

    supplied_lock = ReentrantLock()
    supplied_buffer = UInt8[0x43]
    overridden = JuliaForever2.JsonRpcPeer(; input, output,
        lock=supplied_lock, buffer=supplied_buffer)
    @test overridden.lock === supplied_lock
    @test overridden.buffer === supplied_buffer
    @test overridden.pending !== peer.pending
    @test peer.buffer == UInt8[0x42]
    @test isempty(legacy.buffer)

    pending = Dict{Any,Channel{JuliaForever2.JSONRPCTransport.RpcResult}}()
    handlers = Task[]
    full = JuliaForever2.JsonRpcPeer(input, output, ReentrantLock(),
        ReentrantLock(), UInt8[], pending, handlers, nothing, nothing,
        nothing, nothing, nothing)
    @test full isa JuliaForever2.JsonRpcPeer{typeof(input),typeof(output)}
    @test full.pending === pending
    @test full.handlers === handlers
end
