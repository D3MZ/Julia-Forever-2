# Explicit controlling-PTY test: the driver sends Ctrl+C only after the child reports TTY readiness.
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
workspace=mktempdir();session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=workspace)
app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
terminal=Tachikoma.Terminal(;size=(rows=24,cols=80));Tachikoma.enter_tui!(terminal);Tachikoma.init!(app,terminal)
original_group=ccall(:tcgetpgrp,Cint,(Cint,),0);original_flags=ccall(:fcntl,Cint,(Cint,Cint),0,3)
fd_count=length(readdir("/proc/self/fd"));records=Any[]
@testset "Interrupt or stop remains within the owned editor process group" for mode in (:fullscreen,:regular)
    @test T.presentation_switch!(terminal.io,mode).ok
    T.chat_completion_set_text!(T.chat_completion_state!(app),"original draft")
    withenv("EDITOR"=>"python3 "*abspath(joinpath(@__DIR__,"fixtures","external-editor-helper.py"))*" tty","VISUAL"=>nothing) do
        T.chat_host_packet!(app,"\a")
    end
    @test Tachikoma.text(app.input)=="original draft"
    expected_signal=get(ENV,"EDITOR_INTERRUPT_SIGNAL","SIGINT")
    @test occursin(expected_signal=="SIGTSTP" ? "stopped" : expected_signal,app.status)
    @test !app.settings.presentation.leased && !app.settings.presentation.closed
    @test app.settings.presentation.mode==mode
    @test !isnothing(app.settings.theme_input) && Tachikoma.INPUT_ACTIVE[]
    @test ccall(:tcgetpgrp,Cint,(Cint,),0)==original_group
    @test ccall(:fcntl,Cint,(Cint,Cint),0,3)==original_flags
    @test length(readdir("/proc/self/fd"))==fd_count
    push!(records,Dict("mode"=>String(mode),"status"=>app.status,"draft"=>Tachikoma.text(app.input),"foreground_restored"=>true,"parent_flags_preserved"=>true))
end
println("EXTERNAL_EDITOR_PARENT_RESUMED")
T.close_terminal_theme!(app);Tachikoma.leave_tui!(terminal);T.finish_shutdown!(app);close(session.kernel)
write(ARGS[1],JSON.json(records)*"\n")
