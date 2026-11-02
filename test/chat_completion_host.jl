using Test,JuliaForever2,Tachikoma,CommonMark
module ChatCompletionHostTests
using Test,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function settle!(app)
    timedwait(10;pollint=0.001) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        state=app.menus.chat_completion
        !isnothing(state) && isnothing(state.timer) && (isnothing(state.worker) || istaskdone(state.worker)) && !isready(app.queue.channel)
    end
end
packet!(app,text;key=:unknown)=T.page_input!(app,Val(:chat),KeyEvent(key),collect(codeunits(text)))
@testset "Real terminal editor completion remains data until actual submission" begin
    dir=mktempdir();app=T.App(;settings_dir=dir,registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    calls=String[]
    T.register_command!(app,T.CommandSpec("parity-actual-command","Actual registered action",(app,args)->push!(calls,args)))
    for char in "/parity-actual"
        packet!(app,string(char))
    end
    @test settle!(app)==:ok
    state=T.chat_completion_state!(app)
    @test state.mode!=:none
    @test any(item->item.value=="parity-actual-command",state.items)
    @test isempty(calls)
    packet!(app,"\t";key=:tab)
    @test settle!(app)==:ok
    @test Tachikoma.text(app.input)=="/parity-actual-command "
    @test isempty(calls)
    packet!(app,"fixture value")
    packet!(app,"\r";key=:enter)
    @test calls==["fixture value"]
    @test isempty(Tachikoma.text(app.input))
    @test first(T.chat_editor_state!(app).history)=="/parity-actual-command fixture value"
    packet!(app,"/")
    @test settle!(app)==:ok
    @test state.mode!=:none
    packet!(app,"\e";key=:escape)
    @test state.mode==:none
    @test Tachikoma.text(app.input)=="/"
    @test !app.quit
    # External public TextInput replacement invalidates older suggestions before rendering.
    Tachikoma.set_text!(app.input,"external owner")
    T.chat_completion_lines(state,100,32;runtime=app.menus.theme_runtime)
    @test state.mode==:none
    @test Tachikoma.text(app.input)=="external owner"
    T.set_setting_value!(app,"autocomplete-max-visible","10")
    @test T.chat_completion_state!(app).max_visible==10
    # A replaced session workspace owns a new provider; stale completion state is closed.
    app.settings.workspace=mktempdir()
    replacement=T.chat_completion_state!(app)
    @test replacement!==state && state.closed
    @test replacement.provider.directory==app.settings.workspace
    kernel=app.session.kernel
    T.finish_shutdown!(app);close(kernel)
    @test replacement.closed && isnothing(app.menus.chat_completion)
end
end
