using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const PresentationOwner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Native screen backend, lease and close ownership" begin
    T=PresentationOwner;raw=IOBuffer();events=Symbol[]
    state=T.TerminalPresentation(;attached=true,width=40,height=12,
        lines=[[Tachikoma.Span("actual content")]],on_exit=io->push!(events,:exit),before_exit=()->push!(events,:prepare))
    io=T.PresentationIO(raw,state)
    @test T.presentation_switch!(io,:regular).ok
    @test !state.closed && state.mode==:regular
    @test String(take!(raw))=="\e[?1049l"*Tachikoma.MOUSE_OFF
    @test T.presentation_switch!(io,:regular).ok && position(raw)==0
    @test !T.presentation_switch!(io,:fullscreen;overlay=true).ok
    @test state.mode==:regular && position(raw)==0
    frame=Vector{UInt8}(codeunits("\e[?2026hignored framework absolute frame\e[?2026l"))
    write(io,frame)
    output=String(take!(raw))
    @test occursin("actual content",output) && !occursin("ignored framework",output)
    @test T.presentation_pause!(io).ok
    @test !T.presentation_pause!(io).ok
    write(io,frame);@test position(raw)==0
    @test !T.presentation_switch!(io,:fullscreen).ok
    print(io,Tachikoma.ALT_SCREEN_OFF)
    @test !state.closed && isempty(events)
    print(io,Tachikoma.ALT_SCREEN_ON)
    @test T.presentation_resume!(io).ok && !state.leased
    @test state.regular.width==-1
    @test !T.presentation_resume!(io).ok
    take!(raw)
    write(io,frame);@test occursin("\e[3J",String(take!(raw)))
    @test T.presentation_switch!(io,:fullscreen).ok
    take!(raw);write(io,frame);@test take!(raw)==frame
    print(io,Tachikoma.ALT_SCREEN_OFF)
    @test state.closed && events==[:prepare,:exit]
    final=String(take!(raw));@test occursin("\e[?25h",final) && any(row->occursin("actual content",row),state.regular.rows)
    print(io,"late");write(io,frame);@test position(raw)==0
    close(io);@test isopen(raw)
    @test !T.presentation_switch!(io,:regular).ok
end

@testset "Actual App persistent mode effects and real native stream" begin
    T=PresentationOwner
    mktempdir() do directory
        path=joinpath(directory,"terminal-settings.json")
        write(path,JSON.json(Dict("tui-mode"=>"regular","quiet-startup"=>"true")))
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=directory);settings_dir=directory)
        @test app.settings.presentation.mode==:regular
        sink=IOBuffer();terminal=Tachikoma.Terminal(;io=sink,size=(rows=12,cols=60));app.settings.terminal=terminal
        T.initialize_terminal_presentation!(app,terminal)
        @test terminal.io isa T.PresentationIO
        Tachikoma.draw!(terminal) do frame
            T.default_view!(app,frame)
        end
        @test length(app.settings.presentation.regular.rows)<12
        for (setting,value,field,expected) in (("clear-on-shrink","true",:clear_on_shrink,true),("fullscreen-exit-output","resume-hint",:exit_output,Symbol("resume-hint")),("tui-mode","fullscreen",:mode,:fullscreen))
            T.set_setting_value!(app,setting,value)
            @test getproperty(app.settings.presentation,field)==expected
            @test JSON.parsefile(path)[setting]==value
        end
        @test T.terminal_presentation_pause!(app).ok
        T.set_setting_value!(app,"tui-mode","regular")
        @test app.settings.presentation.mode==:fullscreen
        @test JSON.parsefile(path)["tui-mode"]=="fullscreen"
        @test occursin("external process",app.status)
        @test T.terminal_presentation_resume!(app).ok
        T.set_setting_value!(app,"tui-mode","regular")
        @test app.settings.presentation.mode==:regular && JSON.parsefile(path)["tui-mode"]=="regular"
        @test last(app.transcript.notices.notices).message=="TUI mode: regular"
        T.cleanup!(app)
        @test isnothing(app.menus.chat_completion)
        print(terminal.io,Tachikoma.ALT_SCREEN_OFF)
        @test isnothing(app.menus.chat_completion)
        @test app.settings.presentation.closed
        last_position=position(sink);T.cleanup!(app)
        @test position(sink)==last_position
        close(app.session)
    end
end

@testset "Regular teardown never restores an obsolete alternate-screen cursor" begin
    T=PresentationOwner;raw=IOBuffer()
    state=T.TerminalPresentation(;attached=true,mode=:regular,width=40,height=12,
        lines=[[Tachikoma.Span("actual row")],[Tachikoma.Span("editor")],[Tachikoma.Span("footer")]],cursor=(1,2))
    io=T.PresentationIO(raw,state)
    T.presentation_frame!(io);take!(raw)
    print(io,Tachikoma.ALT_SCREEN_OFF)
    ending=String(take!(raw))
    @test !occursin("\e[?1049l",ending)
    @test ending==" \e[2B\r\n\e[?25h"
    @test state.closed
    state=T.TerminalPresentation(;attached=true,mode=:regular,leased=true)
    io=T.PresentationIO(raw,state);print(io,Tachikoma.ALT_SCREEN_OFF)
    @test position(raw)==0 && !state.closed
end
