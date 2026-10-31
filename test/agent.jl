using JuliaForever2: Kernel, ComponentSpec, install!, Session, Reply, run_turn!, spawn_agent!, component

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

@testset "Code failures and child agents" begin
    kernel = Kernel()
    replies = [Reply(:code, "error(\"broken\")"), Reply(:answer, "Recovered"), Reply(:answer, "Child response")]
    install!(kernel, ComponentSpec(:provider, (messages, session) -> popfirst!(replies)))
    session = Session(kernel)
    @test run_turn!(session, "Fail").text == "Recovered"
    @test occursin("broken", session.messages[3].content)
    child = spawn_agent!(session, "Hello child")
    @test child.result.text == "Child response"
    @test child.session !== session
    @test child.session.kernel === kernel
end

@testset "Replaceable loop and executor" begin
    kernel = Kernel()
    install!(kernel, ComponentSpec(:loop, (session, prompt, limit) -> (ok=true, text="alternate: " * prompt)))
    @test run_turn!(Session(kernel), "hello").text == "alternate: hello"
    install!(kernel, ComponentSpec(:executor, (session, code) -> (ok=true, text="executed: " * code)))
    @test JuliaForever2.evaluate!(Session(kernel), "1+1").text == "executed: 1+1"
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
