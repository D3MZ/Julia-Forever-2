struct ArchitectureAction
    value::Int
end

mutable struct ArchitectureExecutor
    values::Vector{Int}
end

ArchitectureExecutor() = ArchitectureExecutor(Int[])
JuliaForever2.fork_executor(::ArchitectureExecutor) = ArchitectureExecutor()

function JuliaForever2.execute!(executor::ArchitectureExecutor, action::ArchitectureAction, context::ExecutionContext)
    push!(executor.values, action.value)
    return ExecutionResult(true, "structured result", action.value * 2)
end

struct ArchitectureProtocol end
JuliaForever2.prompt_instructions(::ArchitectureProtocol, session) = "Use structured actions."
JuliaForever2.reply_schema(::ArchitectureProtocol) = (type="object",)
JuliaForever2.reply_format(::ArchitectureProtocol) = (type="json_object",)

struct ArchitectureProvider
    requests::Vector{ModelRequest}
end

function JuliaForever2.respond(provider::ArchitectureProvider, request::ModelRequest, context::ExecutionContext)
    push!(provider.requests, request)
    decision = request.messages[end].role == :code_result ? Answer("complete") : ActionDecision(ArchitectureAction(21))
    return ProviderResult(decision, JuliaForever2.UsageReport(2, 3, nothing))
end

@testset "Typed actions cross the complete model-driven runtime" begin
    requests = ModelRequest[]
    definition = AgentDefinition(ArchitectureProvider(requests); executor_factory=ArchitectureExecutor, protocol=ArchitectureProtocol())
    session = Session(definition)
    other = Session(definition)
    events = HarnessEvent[]
    context = ExecutionContext(; emit=event -> push!(events, event))
    result = run_turn!(session, "compute"; context)
    @test result.ok && result.text == "complete"
    @test session.executor.values == [21]
    @test isempty(other.executor.values)
    @test session.runtime !== other.runtime
    @test session.conversation !== other.conversation
    @test !hasproperty(first(requests), :session)
    @test all(request -> request.protocol isa ArchitectureProtocol, requests)
    @test first(requests).instructions == "Use structured actions."
    @test session.messages[2].metadata == ArchitectureAction(21)
    @test session.messages[3].metadata.value == 42
    @test session.usage.input_tokens == 4
    committed = filter(event -> event.kind == :response_committed, events)
    @test length(committed) == 2
    @test all(event -> event.data.operation_id == JuliaForever2.operation_id(context), committed)
    @test last(events).kind == :completed
    close(session)
    close(other)
    @test !isopen(session.kernel)
end

@testset "Definitions compose ordered wrappers without shared executor state" begin
    observed = Symbol[]
    first_wrapper = inner -> (session, prompt, limit) -> begin
        push!(observed, :first)
        inner(session, prompt, limit)
    end
    second_wrapper = inner -> (session, prompt, limit) -> begin
        push!(observed, :second)
        inner(session, prompt, limit)
    end
    definition = AgentDefinition((messages, session) -> Reply(:answer, "ok"); wrappers=(first_wrapper, second_wrapper))
    session = Session(definition)
    @test run_turn!(session, "hello").ok
    @test observed == [:second, :first]
    @test session.messages === session.conversation.messages
    @test session.executor === session.runtime.executor
    close(session)
end

@testset "Isolated children retain resources without sharing composition changes" begin
    kernel = JuliaForever2.default_kernel((messages, session) -> Reply(:answer, "parent"))
    disposals = Ref(0)
    resource = Ref(:live)
    install!(kernel, ComponentSpec(:resource, resource; cleanup=value -> (value[] = :closed; disposals[] += 1)))
    parent = Session(kernel)
    child = spawn_agent!(parent, "hello"; isolated=true)
    @test fetch(child).text == "parent"
    @test child.session.kernel !== parent.kernel
    install!(child.session.kernel, ComponentSpec(:provider, (messages, session) -> Reply(:answer, "child")))
    @test run_turn!(child.session, "hello again").text == "child"
    @test run_turn!(parent, "hello again").text == "parent"
    @test remove!(parent.kernel, :resource).ok
    @test resource[] == :live
    close(child.session)
    @test resource[] == :closed
    @test disposals[] == 1
    alternate = AgentDefinition((messages, session) -> Reply(:answer, "defined child"))
    defined_child = spawn_agent!(parent, "another"; definition=alternate)
    @test fetch(defined_child).text == "defined child"
    @test defined_child.session.definition === alternate
    close(parent)
    close(kernel)
end

@testset "Bound dependencies identify their retained generation" begin
    kernel = Kernel()
    old_resource = Ref(:old)
    new_resource = Ref(:new)
    install!(kernel, ComponentSpec(:resource, old_resource; cleanup=value -> (value[] = :closed)))
    install!(kernel, ComponentSpec(:consumer, :consumer; requires=[:resource]))
    bound = JuliaForever2.bind_component(kernel, :consumer)
    install!(kernel, ComponentSpec(:resource, new_resource))
    @test JuliaForever2.bound_dependency(bound, :resource) === old_resource
    @test component(kernel, :resource) === new_resource
    @test bound.dependencies.resource[] == :old
    forked = JuliaForever2.fork_kernel(kernel)
    forked_binding = JuliaForever2.bind_component(forked, :consumer)
    @test JuliaForever2.bound_dependency(forked_binding, :resource) === old_resource
    @test component(forked, :resource) === new_resource
    @test remove!(kernel, :consumer).ok
    @test old_resource[] == :old
    release!(bound)
    @test old_resource[] == :old
    release!(forked_binding)
    close(forked)
    @test old_resource[] == :closed
    snapshot = JuliaForever2.component_snapshot(kernel)
    @test only(snapshot).name == :resource
    @test only(snapshot).value_type == typeof(new_resource)
    @test !hasproperty(only(snapshot), :value)
    close(kernel)
end

mutable struct ReentrantClosingExecutor
    session::Base.RefValue{Any}
    closes::Int
end

function JuliaForever2.close_executor!(executor::ReentrantClosingExecutor)
    executor.closes += 1
    close(executor.session[])
    return nothing
end

@testset "Completion and cleanup callbacks can request their owner's shutdown" begin
    kernel = JuliaForever2.default_kernel((messages, session) -> Reply(:answer, "done"))
    session = Session(kernel)
    context = ExecutionContext(; emit=event -> begin
        event.kind == :completed && close(session)
        nothing
    end)
    completed = submit_turn!(session, "finish"; context)
    @test timedwait(() -> istaskdone(completed), 10.0; pollint=0.01) == :ok
    if istaskdone(completed)
        @test fetch(completed).ok
        close(session)
    end
    close(kernel)

    resource_provider = (messages, session) -> begin
        JuliaForever2.own_resource!(JuliaForever2.current_execution_context(), session)
        Reply(:answer, "resource cleanup")
    end
    resource_kernel = JuliaForever2.default_kernel(resource_provider)
    resource_session = Session(resource_kernel)
    resource_handle = submit_turn!(resource_session, "finish")
    @test timedwait(() -> istaskdone(resource_handle), 10.0; pollint=0.01) == :ok
    if istaskdone(resource_handle)
        @test fetch(resource_handle).ok
        close(resource_session)
    end
    close(resource_kernel)

    executor = ReentrantClosingExecutor(Ref{Any}(nothing), 0)
    executor_session = Session(Kernel(); executor)
    executor.session[] = executor_session
    shutdown = Threads.@spawn close(executor_session)
    @test timedwait(() -> istaskdone(shutdown), 10.0; pollint=0.01) == :ok
    if istaskdone(shutdown)
        fetch(shutdown)
        @test executor.closes == 1
    end
end

@testset "Cleanup callbacks retain their own nested component acquisitions" begin
    for fail_cleanup in (false, true)
        kernel = Kernel()
        resource_closed = Ref(false)
        live_during_cleanup = Ref(false)
        install!(kernel, ComponentSpec(:resource, resource_closed; cleanup=value -> (value[] = true)))
        cleanup = value -> with_component(kernel, :resource) do resource
            remove!(kernel, :resource)
            live_during_cleanup[] = !resource[]
            fail_cleanup && error("nested cleanup failure")
            nothing
        end
        provider = (messages, session) -> begin
            JuliaForever2.own_resource!(JuliaForever2.current_execution_context(), nothing; cleanup)
            Reply(:answer, "done")
        end
        install!(kernel, ComponentSpec(:provider, provider))
        session = Session(kernel)
        handle = submit_turn!(session, "finish")
        wait(handle; throw=false)
        @test live_during_cleanup[]
        @test resource_closed[]
        @test istaskfailed(handle) == fail_cleanup
        @test !istaskfailed(handle.worker)
        close(session)
        close(kernel)
    end
end

@testset "Completion callbacks have a fresh scope across nested operations" begin
    kernel = JuliaForever2.default_kernel((messages, session) -> Reply(:answer, "done"))
    before = Ref(false)
    after = Ref(false)
    install!(kernel, ComponentSpec(:before, before; cleanup=value -> (value[] = true)))
    install!(kernel, ComponentSpec(:after, after; cleanup=value -> (value[] = true)))
    session = Session(kernel)
    observations = Bool[]
    evaluated = Ref(0)
    context = ExecutionContext(; emit=event -> begin
        if event.kind == :completed
            with_component(kernel, :before) do resource
                remove!(kernel, :before)
                push!(observations, !resource[])
            end
            evaluated[] = evaluate!(session, "2 + 3").value
            with_component(kernel, :after) do resource
                remove!(kernel, :after)
                push!(observations, !resource[])
            end
        end
        nothing
    end)
    handle = submit_turn!(session, "finish"; context)
    @test timedwait(() -> istaskdone(handle), 10.0; pollint=0.01) == :ok
    if istaskdone(handle)
        @test fetch(handle).ok
        @test observations == [true, true]
        @test evaluated[] == 5
        @test before[] && after[]
        close(session)
        close(kernel)
    end
end

mutable struct OrderedTeardownExecutor
    block::Bool
    started::Channel{Nothing}
    finish::Channel{Nothing}
    closes::Int
end

JuliaForever2.fork_executor(executor::OrderedTeardownExecutor) = OrderedTeardownExecutor(true, executor.started, executor.finish, 0)

function JuliaForever2.close_executor!(executor::OrderedTeardownExecutor)
    executor.closes += 1
    if executor.block
        put!(executor.started, nothing)
        take!(executor.finish)
    end
    return nothing
end

@testset "Parent shutdown joins child teardown before closing parent resources" begin
    parent_reference = Ref{Session}()
    provider = (messages, session) -> begin
        close(parent_reference[])
        Reply(:answer, "child finished")
    end
    executor = OrderedTeardownExecutor(false, Channel{Nothing}(1), Channel{Nothing}(1), 0)
    kernel = JuliaForever2.default_kernel(provider)
    parent = Session(kernel; executor)
    parent_reference[] = parent
    child = spawn_agent!(parent, "child")
    @test timedwait(() -> istaskdone(child), 10.0; pollint=0.01) == :ok
    @test timedwait(() -> isready(executor.started), 10.0; pollint=0.01) == :ok
    if isready(executor.started)
        take!(executor.started)
        @test !parent.runtime.executor_closed
        @test executor.closes == 0
        put!(executor.finish, nothing)
        close(parent)
        @test parent.runtime.executor_closed
        @test executor.closes == 1
        @test child.session.executor.closes == 1
    end
    close(kernel)
end

@testset "Self-modification follows request, evaluation, and turn boundaries" begin
    replacement_code = """
    install!(kernel, ComponentSpec(:provider, (messages, session) ->
        messages[end].content == "replacement executor" ? Reply(:answer, "replacement provider") : Reply(:code, "unused")))
    install!(kernel, ComponentSpec(:executor, (session, code) -> ExecutionResult(true, "replacement executor")))
    install!(kernel, ComponentSpec(:loop, (session, prompt, limit) -> ExecutionResult(true, "next turn")))
    17
    """
    kernel = JuliaForever2.default_kernel((messages, session) -> Reply(:code, replacement_code))
    session = Session(kernel)
    @test run_turn!(session, "replace").text == "replacement provider"
    @test session.messages[3].content == "17"
    @test session.messages[5].content == "replacement executor"
    @test run_turn!(session, "again").text == "next turn"
    close(session)
    close(kernel)
end

@testset "Failed workers release resources and component leases before fetch" begin
    disposed = Ref(0)
    completed_cleanup = Int[]
    provider = (messages, session) -> begin
        context = JuliaForever2.current_execution_context()
        JuliaForever2.own_resource!(context, 1; cleanup=value -> push!(completed_cleanup, value))
        JuliaForever2.own_resource!(context, 2; cleanup=value -> error("cleanup failure"))
        JuliaForever2.own_resource!(context, 3; cleanup=value -> push!(completed_cleanup, value))
        error("worker failure")
    end
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, provider; cleanup=value -> (disposed[] += 1)))
    session = Session(kernel)
    handle = submit_turn!(session, "fail")
    wait(handle; throw=false)
    @test istaskfailed(handle)
    @test istaskfailed(handle.worker)
    @test sort(completed_cleanup) == [1, 3]
    @test isempty(handle.context.resources)
    @test_throws TaskFailedException fetch(handle)
    @test remove!(kernel, :provider).ok
    @test disposed[] == 1
    close(session)
    close(kernel)
end

@testset "Cleanup failure does not strand dependent component generations" begin
    kernel = Kernel()
    closed = Ref(false)
    install!(kernel, ComponentSpec(:resource, closed; cleanup=value -> (value[] = true)))
    install!(kernel, ComponentSpec(:consumer, nothing; requires=[:resource], cleanup=value -> error("consumer cleanup failure")))
    @test_throws TaskFailedException remove!(kernel, :consumer)
    @test remove!(kernel, :resource).ok
    @test closed[]
    close(kernel)
end

@testset "Child-initiated parent shutdown does not wait on its own ancestry" begin
    parent_reference = Ref{Session}()
    provider = (messages, session) -> begin
        if messages[end].content == "parent"
            fetch(spawn_agent!(session, "child"))
            Reply(:answer, "parent finished")
        else
            close(parent_reference[])
            Reply(:answer, "child finished")
        end
    end
    kernel = JuliaForever2.default_kernel(provider)
    parent = Session(kernel)
    parent_reference[] = parent
    handle = submit_turn!(parent, "parent")
    @test timedwait(() -> istaskdone(handle), 10.0; pollint=0.01) == :ok
    if istaskdone(handle)
        @test !fetch(handle).ok
        close(parent)
        @test parent.runtime.executor_closed
        @test isempty(parent.runtime.children)
        close(kernel)
    end
end

@testset "Parallel extension listeners begin before earlier callbacks finish" begin
    scope = JuliaForever2.ExtensionScope()
    first_started = Channel{Nothing}(1)
    second_started = Channel{Nothing}(1)
    release_first = Base.Event()

    JuliaForever2.on!(() -> begin
        put!(first_started, nothing)
        wait(release_first)
        nothing
    end, scope, :parallel_probe)
    JuliaForever2.on!(() -> begin
        put!(second_started, nothing)
        nothing
    end, scope, :parallel_probe)

    dispatch = Threads.@spawn JuliaForever2.dispatch_event!(scope, :parallel_probe; mode=:parallel)
    @test timedwait(() -> isready(first_started), 10.0; pollint=0.01) == :ok
    overlapped = timedwait(() -> isready(second_started), 2.0; pollint=0.01) == :ok
    notify(release_first)
    @test overlapped
    @test timedwait(() -> istaskdone(dispatch), 10.0; pollint=0.01) == :ok
    istaskdone(dispatch) && @test fetch(dispatch) === nothing
    close(scope)
end


@testset "Tool lookup ignores unrelated registry size" begin
    function populated_scope(extra_tools)
        scope = JuliaForever2.ExtensionScope()
        selected = JuliaForever2.ToolSpec(:selected, identity)
        @test JuliaForever2.register_tool!(scope, selected).ok
        for index in 1:extra_tools
            descriptor = JuliaForever2.ToolSpec(Symbol("unrelated_", index), identity)
            @test JuliaForever2.register_tool!(scope, descriptor).ok
        end
        @test JuliaForever2.tool(scope, :selected) === selected
        return scope
    end

    function lookup_count(scope, repetitions)
        hits = 0
        for _ in 1:repetitions
            hits += JuliaForever2.tool(scope, :selected) !== nothing
        end
        return hits
    end

    narrow = populated_scope(0)
    wide = populated_scope(256)
    repetitions = 100
    @test lookup_count(narrow, repetitions) == repetitions
    @test lookup_count(wide, repetitions) == repetitions
    GC.gc()
    narrow_bytes = @allocated lookup_count(narrow, repetitions)
    GC.gc()
    wide_bytes = @allocated lookup_count(wide, repetitions)
    println("Tool lookup allocations across ", repetitions, " warmed calls: ",
        "1 registered tool=", narrow_bytes, " bytes; ",
        "257 registered tools=", wide_bytes, " bytes; target growth <= 32768 bytes")
    @test wide_bytes <= narrow_bytes + 32_768
    close(wide)
    close(narrow)
end

@testset "Direct tool lookup respects scope shadowing and restrictions" begin
    root = JuliaForever2.ExtensionScope()
    child = JuliaForever2.ExtensionScope(root)
    inherited = JuliaForever2.ToolSpec(:shared, identity)
    local_tool = JuliaForever2.ToolSpec(:shared, identity)
    @test JuliaForever2.register_tool!(root, inherited).ok
    @test JuliaForever2.tool(child, :shared) === inherited
    restriction = JuliaForever2.restrict_tools!(child; deny=[:shared])
    @test restriction.ok
    @test JuliaForever2.tool(child, :shared) === nothing
    local_registration = JuliaForever2.register_tool!(child, local_tool)
    @test local_registration.ok
    @test JuliaForever2.tool(child, :shared) === local_tool
    JuliaForever2.release!(local_registration.registration)
    @test JuliaForever2.tool(child, :shared) === nothing
    JuliaForever2.release!(restriction.registration)
    @test JuliaForever2.tool(child, :shared) === inherited
    close(root)
end


@testset "Unobserved extension dispatch preserves modes and continuation" begin
    scope = JuliaForever2.ExtensionScope()
    for mode in (:emit, :bail, :serial, :parallel)
        @test JuliaForever2.dispatch_event!(scope, :unobserved, 42; mode) === nothing
    end
    invoked = Ref(0)
    continuation = () -> (invoked[] += 1; :finished)
    @test JuliaForever2.dispatch_event!(scope, :unobserved, continuation; mode=:waterfall) === :finished
    @test invoked[] == 1

    seen = Int[]
    JuliaForever2.on!(value -> (push!(seen, value); nothing), scope, :observed)
    @test JuliaForever2.dispatch_event!(scope, :observed, 7) === nothing
    @test JuliaForever2.dispatch_event!(scope, :observed, 13; mode=:serial) === nothing
    @test seen == [7, 13]
    close(scope)
    @test JuliaForever2.dispatch_event!(scope, :observed, 99) === nothing
    @test seen == [7, 13]
end

@testset "Session index candidate allocations ignore common-first query order" begin
    mktempdir() do directory
        index = JuliaForever2.SessionSearchIndex(JuliaForever2.SessionStore(directory))
        ordinary = JuliaForever2.SessionSearchHit(("synthetic", 1, :user, :text, "aaa"))
        index.documents = JuliaForever2.SessionSearchHit[ordinary for _ in 1:65_536]
        index.documents[73] = JuliaForever2.SessionSearchHit(("synthetic", 73, :user, :text, "aaa bbb"))
        index.documents[99] = JuliaForever2.SessionSearchHit(("synthetic", 99, :user, :text, "Ä aaa bbb"))
        common = BitSet(1:65_536)
        delete!(common, 99)
        index.postings = Dict("aaa" => common, "bbb" => BitSet([73]))
        index.unicode_documents = BitSet([99])

        function candidate_count(text, repetitions)
            count = 0
            for _ in 1:repetitions
                count += length(JuliaForever2.indexed_session_candidates(index, text))
            end
            return count
        end

        repetitions = 100
        for _ in 1:6
            @test candidate_count("aaa bbb", repetitions) == 2 * repetitions
            @test candidate_count("bbb aaa", repetitions) == 2 * repetitions
        end
        @test collect(JuliaForever2.indexed_session_candidates(index, "aaa bbb")) == [73, 99]
        @test collect(JuliaForever2.indexed_session_candidates(index, "bbb aaa")) == [73, 99]
        @test collect(JuliaForever2.indexed_session_candidates(index, "aaa ccc")) == [99]
        @test collect(JuliaForever2.indexed_session_candidates(index, "ccc aaa")) == [99]
        @test [hit.index for hit in JuliaForever2.search_history(index, "aaa bbb")] == [73, 99]
        @test isempty(JuliaForever2.search_history(index, "aaa ccc"))

        GC.gc()
        sparse_first_bytes = @allocated candidate_count("bbb aaa", repetitions)
        GC.gc()
        common_first_bytes = @allocated candidate_count("aaa bbb", repetitions)
        println("Session index candidate allocations across ", repetitions,
            " warmed searches (65536 documents): rare-first=", sparse_first_bytes,
            " bytes, common-first=", common_first_bytes,
            " bytes; target common-first growth <= 32768 bytes")
        @test common_first_bytes <= sparse_first_bytes + 32_768
    end
end


@testset "ASCII session trigram index preserves postings and Unicode fallback" begin
    samples = ["AaAaAa", "abcABCabc", "Julia julia JULIA", "AB", "", "A a A a", "needle token"]
    expected, observed = Dict{String,BitSet}(), Dict{String,BitSet}()
    for (id, message) in enumerate(samples)
        for gram in Set(JuliaForever2.session_trigrams(message))
            push!(get!(BitSet, expected, gram), id)
        end
        JuliaForever2.append_ascii_session_postings!(observed, message, id)
    end
    @test observed == expected
    @test observed["aaa"] == BitSet([1])
    mktempdir() do directory
        store = JuliaForever2.SessionStore(directory)
        for (name, value) in [("one", "ABABA needle token"), ("two", "café needle token"),
                ("three", "aaaa aaaa AaAa"), ("four", "中文 язык"), ("five", "ABC xyz")]
            session = Session(Kernel())
            append_message!(session.conversation, Message(:user, value, :text))
            @test JuliaForever2.save_session!(store, name, session).ok
            close(session)
        end
        index = JuliaForever2.SessionSearchIndex(store)
        @test index.postings["aba"] == BitSet([findfirst(hit -> hit.session == "one", index.documents)])
        @test 2 in index.unicode_documents
        for term in ("aba", "AAAA", "needle token", "café", "xyz", "zzzzz", "a", " NEEdle   token ")
            @test JuliaForever2.search_history(index, term) ==
                JuliaForever2.search_history(store, term)
            @test JuliaForever2.search_history(index, term; roles=[:assistant], limit=2) ==
                JuliaForever2.search_history(store, term; roles=[:assistant], limit=2)
        end
    end
end


@testset "ProfileStore ignores symlinks when listing and loading saved profiles" begin
    mktempdir() do directory
        store = JuliaForever2.ProfileStore(joinpath(directory, "profiles"))
        outside = JuliaForever2.ProfileStore(joinpath(directory, "outside"))
        @test JuliaForever2.save_profile!(store, JuliaForever2.Profile(:local, [:example])).ok
        @test JuliaForever2.save_profile!(outside, JuliaForever2.Profile(:linked, [:example])).ok
        symlink(joinpath(outside.directory, "linked.json"),
            joinpath(store.directory, "linked.json"))
        @test JuliaForever2.profile_names(store) == [:local]
        @test isnothing(JuliaForever2.load_profile(store, :linked))
        @test JuliaForever2.load_profile(store, :local).plugins == [:example]
        @test JuliaForever2.load_profile(outside, :linked).plugins == [:example]
        @test isnothing(JuliaForever2.load_profile(store, "linked"))
        @test JuliaForever2.load_profile(store, "local").plugins == [:example]
        @test isnothing(JuliaForever2.load_profile(store, Symbol("")))
    end
end


@testset "Metadata-only persisted lineage retains restore and descendant semantics" begin
    mktempdir() do directory
        store = JuliaForever2.SessionStore(directory)
        root = Session(Kernel(); messages=[Message(:user, "persistent record $index", :text)
            for index in 1:96])
        root_identity = JuliaForever2.session_lineage(root)
        @test JuliaForever2.save_session!(store, "root", root).ok
        child = Session(Kernel(); messages=[Message(:assistant, "child message $index", :text)
            for index in 1:96], parent_id=root_identity.id, root_id=root_identity.root_id)
        child_identity = JuliaForever2.session_lineage(child)
        @test JuliaForever2.save_session!(store, "child", child).ok

        @test JuliaForever2.session_lineage(store, "root") == root_identity
        @test JuliaForever2.session_lineage(store, :child) == child_identity
        @test JuliaForever2.session_descendants(store, "root") == ["child"]
        @test JuliaForever2.session_descendants(store, root_identity.id; include_self=true) == ["child", "root"]
        @test isnothing(JuliaForever2.session_lineage(store, "missing"))
        @test isnothing(JuliaForever2.session_lineage(store, "../invalid"))
        restored = JuliaForever2.load_session(store, "child", Kernel())
        @test !isnothing(restored)
        @test length(JuliaForever2.history_snapshot(restored).messages) == 96
        @test JuliaForever2.history_snapshot(restored).messages[end].content == "child message 96"
        close(restored)
        close(child)
        close(root)
    end
end
