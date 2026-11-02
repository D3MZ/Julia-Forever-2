# Explicit real-PTY integration test. Not part of unattended offline suites.
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const helper=abspath(joinpath(@__DIR__,"fixtures","external-editor-helper.py"))
workspace=mktempdir();session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=workspace)
app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
terminal=Tachikoma.Terminal(;size=(rows=24,cols=80));Tachikoma.enter_tui!(terminal);Tachikoma.init!(app,terminal)
records=Any[];frames=Any[]
function capture_editor(app,mode,kind,phase)
    if kind!="tty"
        width=80;rows=T.chat_completion_lines(T.chat_completion_state!(app),width,24;runtime=app.menus.theme_runtime).lines
        backend=TestBackend(width,max(1,length(rows)));T.session_draw_lines!(backend.buf,1,1,width,rows)
        lines=[sprint() do io
            for x in 1:width
                cell=backend.buf.content[(y-1)*width+x]
                if cell.char!=Tachikoma.WIDE_CHAR_PAD
                    print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
                end
            end
            print(io,"\e[0m")
        end for y in 1:length(rows)]
        push!(frames,Dict("id"=>"external.$mode.$kind.$phase","width"=>width,"terminalAnsiLines"=>lines))
    end
end
@testset "Real attached TTY external editor restores input and both presentation modes" begin
    @test stdin isa Base.TTY
    for mode in (:fullscreen,:regular)
        @test T.presentation_switch!(terminal.io,mode).ok
        for kind in ("edited","nonzero","signal","missing","tty")
            T.chat_completion_set_text!(T.chat_completion_state!(app),"original draft")
            capture_editor(app,mode,kind,"before")
            original_input=app.input;original_terminal=app.settings.terminal;original_sink=T.terminal_presentation_sink(app)
            withenv("EDITOR"=>(kind=="missing" ? "/nonexistent-jf2-editor-for-test" : "python3 "*helper*" "*kind),"VISUAL"=>nothing) do
                T.chat_host_packet!(app,"\a")
            end
            capture_editor(app,mode,kind,"after")
            actual=Tachikoma.text(app.input)
            println("EXTERNAL_EDITOR_RESULT ",JSON.json(Dict("kind"=>kind,"mode"=>String(mode),"status"=>app.status,"draft"=>actual)))
            expected=kind=="edited" ? "edited α draft\n" : kind=="tty" ? "edited through tty: fixture input" : "original draft"
            @test actual==expected
            @test app.input===original_input && app.settings.terminal===original_terminal
            @test T.terminal_presentation_sink(app)===original_sink
            @test app.settings.presentation.mode==mode && !app.settings.presentation.leased && !app.settings.presentation.closed
            @test !isnothing(app.settings.theme_input)
            @test Tachikoma.INPUT_ACTIVE[]
            @test isnothing(app.operations.active)
            @test ccall(:tcgetpgrp,Cint,(Cint,),0)==ccall(:getpgrp,Cint,())
            if kind=="tty" && get(ENV,"EDITOR_RESIZE_PROBE","")=="1"
                @test terminal.size.width==100 && terminal.size.height==30
            end
            push!(records,Dict("mode"=>String(mode),"kind"=>kind,"draft"=>actual,"status"=>app.status,"leased"=>app.settings.presentation.leased))
        end
    end
    T.chat_completion_set_text!(T.chat_completion_state!(app),"original draft")
    owner=T.ExternalEditorProcess()
    task=@async T.external_editor_command!(app;command="python3 "*helper*" hang",owner)
    @test Base.timedwait(()->!isnothing(owner.process),10.0;pollint=0.01)==:ok
    @test !T.terminal_presentation_pause!(app).ok
    T.chat_completion_set_text!(T.chat_completion_state!(app),"new concurrent draft")
    T.cancel_external_editor!(owner);result=fetch(task)
    @test !result.ok && occursin("cancelled",result.reason)
    @test Tachikoma.text(app.input)=="new concurrent draft"
    @test !app.settings.presentation.leased && !app.settings.presentation.closed
    @test !isnothing(app.settings.theme_input) && Tachikoma.INPUT_ACTIVE[]
end
T.close_terminal_theme!(app);Tachikoma.leave_tui!(terminal);T.finish_shutdown!(app);close(session.kernel)
write(ARGS[1],JSON.json(Dict("records"=>records,"snapshots"=>frames))*"\n")
