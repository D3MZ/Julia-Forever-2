using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module TerminalOutputTests
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Original terminal progress and keepalive source contract" begin
    root=get(ENV,"PI_REFERENCE","")
    mktempdir() do directory
        output=joinpath(directory,"original.json")
        original=JSON.parsefile(joinpath(@__DIR__,"fixtures","terminal-output.json"))
        if !isempty(root)
            @test isdir(root)
            run(`node $(joinpath(@__DIR__,"differential","terminal_output_oracle.mjs")) $root $output`)
            @test JSON.parsefile(output)==original
        end
        @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
        state=T.TerminalOutputState();io=IOBuffer()
        for expected in original["snapshots"]
            step=expected["step"]
            T.terminal_progress!(state,io,get(step,"active",state.progress);now=expected["now"]/1000,force=haskey(step,"active"))
            @test String(take!(copy(io)))==expected["output"]
            @test state.progress==expected["active"]
        end
        T.terminal_output_close!(state,io)
        before=String(take!(copy(io)))
        T.terminal_progress!(state,io,true;now=100)
        @test String(take!(copy(io)))==before
        @test state.closed
    end
end
@testset "Cursor output positions hidden IME anchors only at real viewport cells" begin
    state=T.TerminalOutputState();io=IOBuffer()
    T.terminal_cursor!(state,io,true,(3,4);width=80,height=24)
    @test String(take!(io))=="\e[4;3H\e[?25h"
    T.terminal_cursor!(state,io,true,nothing;width=80,height=24)
    @test String(take!(io))=="\e[?25l"
    T.terminal_cursor!(state,io,true,(81,4);width=80,height=24)
    @test isempty(String(take!(io)))
    T.terminal_cursor!(state,io,false,(3,4);width=80,height=24)
    @test String(take!(io))=="\e[4;3H\e[?25l"
    @test !state.cursor_visible
    T.terminal_cursor!(state,io,false,(5,4);width=80,height=24)
    @test String(take!(io))=="\e[4;5H\e[?25l"
    T.terminal_cursor!(state,io,false,nothing;width=80,height=24)
    @test isempty(String(take!(io)))
    T.terminal_output_close!(state,io);take!(io)
    T.terminal_cursor!(state,io,true,(3,4);width=80,height=24)
    @test isempty(String(take!(io)))
end
@testset "Actual App terminal progress follows real owned turn and teardown" begin
    directory=mktempdir();started=Channel{Nothing}(1);release=Channel{Nothing}(1)
    provider=(messages,session)->begin put!(started,nothing);take!(release);Answer("done") end
    app=T.App(Session(Kernel(provider));settings_dir=directory,registry=JuliaForever2.ProviderRegistry())
    io=IOBuffer();terminal=Tachikoma.Terminal(;io,size=(cols=80,rows=24),external_size=true)
    app.settings.terminal=terminal
    T.set_setting_value!(app,"terminal-progress","true")
    @test T.submit_literal_input!(app,"test").ok
    take!(started);T.terminal_output_frame!(app;now=0)
    @test String(take!(io))=="\e]9;4;3\a"
    T.terminal_output_frame!(app;now=0.5)
    @test isempty(String(take!(io)))
    T.terminal_output_frame!(app;now=1)
    @test String(take!(io))=="\e]9;4;3\a"
    put!(release,nothing)
    @test timedwait(5;pollint=0.001) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy
    end == :ok
    T.terminal_output_frame!(app;now=1.1)
    @test String(take!(io))=="\e]9;4;0\a"
    T.set_setting_value!(app,"show-hardware-cursor","true")
    T.terminal_output_cursor!(app,(7,9));T.terminal_output_frame!(app;now=1.2)
    @test String(take!(io))=="\e[9;7H\e[?25h"
    T.set_setting_value!(app,"show-hardware-cursor","false")
    T.terminal_output_cursor!(app,(8,9));T.terminal_output_frame!(app;now=1.3)
    @test String(take!(io))=="\e[9;8H\e[?25l"
    @test !app.settings.output.cursor_visible
    kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
    @test app.settings.output.closed
end
end
