using JuliaForever2: Kernel, ComponentSpec, install!, Session, Message, Reply, run_turn!, spawn_agent!, component,
    ExecutionResult, ExecutionContext, submit_turn!, submit_evaluation!, evaluate!, cancel!, cancelled,
    append_message!, clear_history!, replace_message!, history_revision, history_snapshot, cancellation_event

@testset "Agent code and replacement" begin
    kernel = Kernel()
    replies = [Reply(:code, "install!(kernel, ComponentSpec(:custom, x -> x * 3)); println(\"installed\"); 42"), Reply(:answer, "Ready.")]
    provider = (messages, session) -> popfirst!(replies)
    @test install!(kernel, ComponentSpec(:provider, provider)).ok
    session = Session(kernel)
    result = run_turn!(session, "Make a component")
    @test result.ok
    @test result.text == "Ready."
    @test occursin("installed", session.messages[3].content)
    @test occursin("42", session.messages[3].content)
    @test Base.invokelatest(component(kernel, :custom), 7) == 21
    @test [message.role for message in session.messages] == [:user, :assistant, :code_result, :assistant]
    @test session.messages[2].kind == :code
    @test session.messages[4].kind == :answer
end

@testset "Stateful turn counter plugin" begin
    path = joinpath(@__DIR__, "..", "plugins", "turn_counter.jl")
    sessions = [Session(Kernel()), Session(Kernel())]
    for session in sessions
        install!(session.kernel, ComponentSpec(:provider, (messages, session) -> Reply(:answer, "ok")))
        @test JuliaForever2.evaluate!(session, "include($(repr(path)))").ok
    end
    @test run_turn!(sessions[1], "first").ok
    @test run_turn!(sessions[1], "second").ok
    @test run_turn!(sessions[2], "independent").ok
    @test component(sessions[1].kernel, :turn_counter_state).count == 2
    @test component(sessions[2].kernel, :turn_counter_state).count == 1
    @test !remove!(sessions[1].kernel, :turn_counter_state).ok
end

@testset "Managed child agents" begin
    kernel = Kernel()
    started = Channel{Nothing}(1)
    finish = Channel{Nothing}(1)
    provider = (messages, session) -> begin
        put!(started, nothing)
        take!(finish)
        Reply(:answer, "Child response")
    end
    install!(kernel, ComponentSpec(:provider, provider))
    session = Session(kernel)
    child = spawn_agent!(session, "Hello child")
    take!(started)
    @test !istaskdone(child)
    put!(finish, nothing)
    @test fetch(child).text == "Child response"
    @test child.session !== session
    @test child.session.kernel === kernel
    @test child.session.executor !== session.executor
    close(session)
    @test !isopen(child.session)
end

@testset "Replaceable loop and executor" begin
    kernel = Kernel()
    install!(kernel, ComponentSpec(:loop, (session, prompt, limit) -> (ok=true, text="alternate: " * prompt)))
    @test run_turn!(Session(kernel), "hello").text == "alternate: hello"
    install!(kernel, ComponentSpec(:executor, (session, code) -> (ok=true, text="executed: " * code)))
    @test JuliaForever2.evaluate!(Session(kernel), "1+1").text == "executed: 1+1"
end

@testset "Explicit IO semantics and structured values" begin
    session = Session(Kernel())
    result = evaluate!(session, "target = IOBuffer(); println(target, \"destination text\"); String(take!(target))")
    @test result.value == "destination text\n"
    @test result.text == "\"destination text\\n\""
    @test evaluate!(session, "println(\"captured\"); nothing").text == "captured\n"
    handle = submit_evaluation!(session, "(answer=42,)")
    @test fetch(handle).value == (answer=42,)
    @test session.messages[end].metadata.value == (answer=42,)
end

@testset "Same-session evaluations retain all output" begin
    session = Session(Kernel())
    started = Channel{Nothing}(1)
    finish = Channel{Nothing}(1)
    Core.eval(session.scope, :(const started = $(QuoteNode(started))))
    Core.eval(session.scope, :(const finish = $(QuoteNode(finish))))
    first = submit_evaluation!(session, "println(\"A-before\"); put!(started, nothing); take!(finish); println(\"A-after\"); nothing")
    take!(started)
    second = submit_evaluation!(session, "println(\"B-only\"); nothing")
    put!(finish, nothing)
    @test fetch(first).text == "A-before\nA-after\n"
    @test fetch(second).text == "B-only\n"
    @test [message.content for message in session.messages] == ["A-before\nA-after\n", "B-only\n"]
end

@testset "Same-session turns own a complete conversation step" begin
    kernel = Kernel()
    session = Session(kernel)
    started = Channel{Nothing}(1)
    finish = Channel{Nothing}(1)
    snapshots = Vector{Vector{String}}()
    provider = (messages, session) -> begin
        push!(snapshots, [message.content for message in messages])
        if length(snapshots) == 1
            put!(started, nothing)
            take!(finish)
            Reply(:answer, "first answer")
        else
            Reply(:answer, "second answer")
        end
    end
    install!(kernel, ComponentSpec(:provider, provider))
    first = submit_turn!(session, "first user")
    take!(started)
    second = submit_turn!(session, "second user")
    put!(finish, nothing)
    @test fetch(first).text == "first answer"
    @test fetch(second).text == "second answer"
    @test snapshots == [["first user"], ["first user", "first answer", "second user"]]
    @test [message.role for message in session.messages] == [:user, :assistant, :user, :assistant]
end

struct CooperativeTestExecutor
    started::Channel{Nothing}
end

function JuliaForever2.execute!(executor::CooperativeTestExecutor, session, code, context::ExecutionContext)
    put!(executor.started, nothing)
    wait(cancellation_event(context))
    return ExecutionResult(!cancelled(context), "cancelled")
end

@testset "Cooperative cancellation, deadlines, and shutdown" begin
    executor = CooperativeTestExecutor(Channel{Nothing}(1))
    session = Session(Kernel(); executor)
    handle = submit_evaluation!(session, "work")
    take!(executor.started)
    @test !istaskdone(handle)
    cancel!(handle)
    @test !fetch(handle).ok
    @test cancelled(handle.context)
    deadline = ExecutionContext(; timeout=0.02)
    wait(cancellation_event(deadline))
    @test cancelled(deadline)
    timed = submit_evaluation!(session, "work"; context=deadline)
    @test !fetch(timed).ok
    owned = submit_evaluation!(session, "work")
    take!(executor.started)
    close(session)
    @test istaskdone(owned)
    @test !isopen(session)
    @test !fetch(owned).ok
    @test !run_turn!(session, "closed").ok
end

@testset "Revisioned history snapshots" begin
    session = Session(Kernel())
    revision = history_revision(session)
    @test isnothing(history_snapshot(session, revision))
    append_message!(session, Message(:user, "one"))
    first = history_snapshot(session, revision)
    @test first.changed_from == 1
    append_message!(session, Message(:assistant, "two"))
    append_message!(session, Message(:user, "three"))
    @test history_snapshot(session, first.revision).changed_from == 2
    replace_message!(session, 1, Message(:user, "edited"))
    @test history_snapshot(session, first.revision).changed_from == 1
    clear_history!(session)
    last = history_snapshot(session, first.revision)
    @test isempty(last.messages)
    @test last.changed_from == 1
end

mutable struct CloseCountingExecutor
    closes::Int
end

JuliaForever2.close_executor!(executor::CloseCountingExecutor) = (executor.closes += 1; nothing)
JuliaForever2.fork_executor(::CloseCountingExecutor) = CloseCountingExecutor(0)

@testset "Idempotent shutdown rejects new work and closes rejected children" begin
    executor = CloseCountingExecutor(0)
    session = Session(Kernel(); executor)
    first_close = Threads.@spawn close(session)
    second_close = Threads.@spawn close(session)
    fetch(first_close)
    fetch(second_close)
    @test executor.closes == 1
    rejected = submit_evaluation!(session, "unused")
    @test !fetch(rejected).ok
    @test isempty(session.messages)
    child = spawn_agent!(session, "unused")
    @test !fetch(child).ok
    @test !isopen(child.session)
    @test child.session.executor.closes == 1
    close(session)
    @test executor.closes == 1
end

@testset "Parent cancellation reaches child request events" begin
    kernel = Kernel()
    started = Channel{Nothing}(1)
    provider = (messages, session) -> begin
        context = JuliaForever2.current_execution_context()
        interrupt = JuliaForever2.register_cancellation!(context, Base.Event())
        put!(started, nothing)
        wait(interrupt)
        JuliaForever2.unregister_cancellation!(context, interrupt)
        Reply(:answer, "finished")
    end
    install!(kernel, ComponentSpec(:provider, provider))
    session = Session(kernel)
    parent = ExecutionContext()
    child = task_local_storage(:JuliaForever2_context, parent) do
        spawn_agent!(session, "child")
    end
    take!(started)
    cancel!(parent)
    @test !fetch(child).ok
    @test cancelled(child.context)
    @test child.context.parent === parent
    @test isempty(parent.listeners)
    close(session)
end

@testset "Explicit child retirement releases parent ownership" begin
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, (messages, session) -> Reply(:answer, "done")))
    session = Session(kernel)
    first = spawn_agent!(session, "first")
    @test fetch(first).ok
    @test isopen(first.session)
    @test first.session in session.children
    close(first.session)
    second = spawn_agent!(session, "second")
    @test fetch(second).ok
    @test !(first.session in session.children)
    @test second.session in session.children
    close(session)
    @test isempty(session.children)
    @test isempty(session.handles)
    @test !isopen(second.session)
end

@testset "Unknown reply kinds cannot execute code" begin
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, (messages, session) -> Reply(:tool, "executed = true")))
    session = Session(kernel)
    result = run_turn!(session, "unknown")
    @test !result.ok
    @test occursin("Unsupported reply kind", result.text)
    @test !isdefined(session.scope, :executed)
end

@testset "Counter delegates to an existing custom loop" begin
    session = Session(Kernel())
    install!(session.kernel, ComponentSpec(:loop, (session, prompt, steps) -> ExecutionResult(true, "wrapped " * prompt)))
    path = joinpath(@__DIR__, "..", "plugins", "turn_counter.jl")
    @test evaluate!(session, "include($(repr(path)))").ok
    @test run_turn!(session, "custom").text == "wrapped custom"
    @test component(session.kernel, :turn_counter_state).count == 1
end

@testset "Agent-authored plugin file" begin
    mktempdir() do dir
        path = joinpath(dir, "plugin.jl")
        write(path, "install!(kernel, ComponentSpec(:increment, x -> x + 1))")
        session = Session(Kernel())
        result = JuliaForever2.evaluate!(session, "include($(repr(path)))")
        @test result.ok
        @test Base.invokelatest(component(session.kernel, :increment), 41) == 42
    end
end


@testset "Normalized provider usage costs remain finite after Float64 conversion" begin
    enormous_cost = big(10)^400
    # A finite arbitrary-precision cost must not become an infinite Float64.
    @test isnothing(JuliaForever2.normalize_usage(Dict("cost" => enormous_cost)).cost)
    @test JuliaForever2.normalize_usage(Dict("cost" => BigFloat("1.25"))).cost == 1.25
    @test isnothing(JuliaForever2.normalize_usage(Dict("cost" => -1)).cost)
end

@testset "Extension scope liveness checks avoid per-ancestor allocations" begin
    shallow = JuliaForever2.ExtensionScope()
    root = JuliaForever2.ExtensionScope()
    deep = root
    for _ in 1:128
        deep = JuliaForever2.ExtensionScope(deep)
    end

    function open_calls(scope, repetitions)
        alive = 0
        for _ in 1:repetitions
            alive += isopen(scope)
        end
        return alive
    end

    repetitions = 100
    @test open_calls(shallow, repetitions) == repetitions
    @test open_calls(deep, repetitions) == repetitions
    GC.gc()
    shallow_bytes = @allocated open_calls(shallow, repetitions)
    GC.gc()
    deep_bytes = @allocated open_calls(deep, repetitions)
    println("Extension scope liveness allocations across ", repetitions, " warmed calls: ",
        "depth 0=", shallow_bytes, " bytes; depth 128=", deep_bytes,
        " bytes; target growth <= 32768 bytes")
    @test deep_bytes <= shallow_bytes + 32_768

    close(root)
    @test !isopen(deep)
    close(shallow)
end

@testset "Empty extension scopes retire without skipping owned cleanup" begin
    root = JuliaForever2.ExtensionScope()
    child = JuliaForever2.ExtensionScope(root)
    @test isopen(root)
    @test isopen(child)
    close(root)
    @test !isopen(root)
    @test !isopen(child)
    close(root)
    close(child)

    unobserved = JuliaForever2.ExtensionScope()
    @test isnothing(JuliaForever2.dispatch_event!(unobserved, :unobserved, 1))
    close(unobserved)
    @test !isopen(unobserved)

    cleaned = Ref(0)
    owned = JuliaForever2.ExtensionScope()
    JuliaForever2.own_resource!(owned, :sentinel; cleanup=value -> begin
        value === :sentinel || error("Wrong cleanup resource")
        cleaned[] += 1
        nothing
    end)
    close(owned)
    close(owned)
    @test cleaned[] == 1
end
