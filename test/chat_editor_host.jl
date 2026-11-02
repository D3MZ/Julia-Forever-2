using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module ChatEditorHostTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function fixture()
    directory=mktempdir();requests=String[]
    provider=(messages,session)->begin push!(requests,last(messages).content);Answer("done") end
    app=T.App(Session(Kernel(provider));settings_dir=directory,registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    app,requests
end
function finish!(app)
    kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
function drain!(app)
    timedwait(5;pollint=0.001) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy
    end
end
function packet!(app,raw;key=:unknown)
    T.page_input!(app,Val(:chat),KeyEvent(key),collect(codeunits(raw)))
end
@testset "Actual native host consumes multiline and atomic-paste editor requests" begin
    app,requests=fixture()
    packet!(app,"hello")
    packet!(app,"\e[13;2u")
    packet!(app,"world")
    @test Tachikoma.text(app.input)=="hello\nworld"
    packet!(app,"\r";key=:enter)
    @test drain!(app)==:ok
    @test requests==["hello\nworld"]
    @test isempty(Tachikoma.text(app.input))
    @test first(T.chat_editor_state!(app).history)=="hello\nworld"
    packet!(app,"\e[A";key=:up)
    @test Tachikoma.text(app.input)=="hello\nworld"
    T.chat_set_text!(T.chat_editor_state!(app),"")
    packet!(app,"\e[200~")
    packet!(app,"a"^2100*"\n\x03\e[201~")
    @test !app.quit
    @test startswith(Tachikoma.text(app.input),"[paste #")
    packet!(app,"\r";key=:enter)
    @test drain!(app)==:ok
    @test last(requests)=="a"^2100
    T.chat_set_text!(T.chat_editor_state!(app),"preserve")
    app.operations.closing[]=true
    packet!(app,"\r";key=:enter)
    @test Tachikoma.text(app.input)=="preserve"
    finish!(app)
end
@testset "Actual native Ctrl-C follows source clear then double-press shutdown" begin
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-editor-host-oracle.json"))
    root=get(ENV,"PI_REFERENCE","")
    if !isempty(root)
        mktempdir() do dir
            output=joinpath(dir,"original.json")
            run(`node $(joinpath(@__DIR__,"differential","pi_editor_host_oracle.mjs")) $root $(joinpath(@__DIR__,"fixtures","pi-editor-owner-oracle.json")) $output`)
            @test JSON.parsefile(output)==original
        end
    end
    for case in original["cases"]
        app,_=fixture()
        for (step,state) in zip(case["steps"],case["states"])
            haskey(step,"text") && Tachikoma.set_text!(app.input,step["text"])
            T.chat_host_interrupt!(app;now_ms=step["now"])
            @test Tachikoma.text(app.input)==state["text"]
            @test app.menus.last_sigint_ms==state["lastSigint"]
            @test app.quit==("shutdown" in state["events"])
        end
        finish!(app)
    end
end
end
