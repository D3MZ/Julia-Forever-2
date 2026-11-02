isdefined(@__MODULE__,:ChatCompletionTests) || include("chat_completion.jl")

module ChatCompletionCommandTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const Shared=parentmodule(@__MODULE__).ChatCompletionTests
const T=Shared.T

@testset "Live App command callbacks match pinned original selection and submission" begin
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-chat-completion-commands-oracle.json"))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        path=joinpath(mktempdir(),"commands-original.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_chat_completion_commands_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
        fresh=JSON.parsefile(path)
        @test fresh==fixture
    end
    frames=Any[];states=Any[]
    for case in fixture["cases"]
        directory=mktempdir();session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=directory)
        app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
        calls=String[];executions=String[]
        callback=prefix->begin
            push!(calls,prefix)
            items=[T.ChatCompletionItem(;value,label=value,description="actual argument "*value) for value in ["all","unit","smoke"] if startswith(value,prefix)]
            case["asynchronous"] ? @async(items) : items
        end
        T.register_command!(app,T.CommandSpec("test","Registered real action",(app,args)->push!(executions,args);argument_completions=callback))
        editor=T.ChatEditorState(app.input);editor.focused=true
        state=T.ChatCompletionState(editor,T.chat_completion_provider(app))
        T.chat_completion_set_text!(state,case["initial"])
        runtime=T.ThemeRuntime(T.ThemeCatalog(;directory=mktempdir(),appearance=:dark);setting="dark")
        for (index,step) in enumerate(case["steps"])
            if index>1
                response=T.chat_completion_input!(state,case["inputs"][index-1]);Shared.flush_work(state)
                if response.action==:submit
                    T.submit!(app,response.text)
                    T.chat_accept!(editor)
                end
            end
            actual=Dict("text"=>T.chat_text(editor),"mode"=>state.mode==:none ? nothing : String(state.mode),"prefix"=>state.prefix,"items"=>Shared.itemdict.(state.items),"calls"=>copy(calls),"executions"=>copy(executions))
            @test actual==step["state"]
            push!(states,actual)
            lines=T.chat_completion_lines(state,case["width"],32;runtime).lines
            push!(frames,Dict("id"=>step["frameId"],"width"=>case["width"],"terminalAnsiLines"=>Shared.buffer_lines(lines,case["width"])))
        end
        @test isnothing(app.operations.active)
        T.chat_completion_close!(state);T.finish_shutdown!(app);close(session.kernel)
    end
    destination=get(ENV,"CHAT_COMPLETION_COMMAND_EVIDENCE","")
    if !isempty(destination)
        mkpath(destination);write(joinpath(destination,"native.json"),JSON.json(Dict("snapshots"=>frames,"states"=>states))*"\n")
    end
end

@testset "Callback constructor compatibility, failure and data-only acceptance" begin
    action=(app,args)->nothing
    @test isnothing(T.CommandSpec("old","old",action,true,:extension).argument_completions)
    @test isnothing(T.CommandSpec{typeof(action)}("old","old",action,true,:extension).argument_completions)
    @test isnothing(T.CommandSpec("old","old",action).argument_completions)
    @test isnothing(T.CommandSpec(;name="old",description="old",action).argument_completions)
    session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=mktempdir())
    app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    executions=String[];editor=T.ChatEditorState(app.input);state=T.ChatCompletionState(editor,T.chat_completion_provider(app))
    execute=(app,args)->push!(executions,args)
    for (callback,message) in ((prefix->error("Callback denied"),"Callback denied"),(prefix->(ok=false,reason="Explicit callback rejection"),"Explicit callback rejection"),(prefix->false,"must return ChatCompletionItem"),(prefix->@async(error("Async callback failed")),"Async callback failed"))
        T.register_command!(app,T.CommandSpec("test","Real callback",execute;argument_completions=callback))
        T.chat_completion_set_text!(state,"/test ");T.chat_completion_input!(state,"u");Shared.flush_work(state)
        @test occursin(message,something(state.error,""))
        @test T.chat_text(editor)=="/test u"
        @test state.mode==:none
        @test isempty(executions)
    end
    T.register_command!(app,T.CommandSpec("test","Real callback",execute;argument_completions=prefix->nothing))
    T.chat_completion_set_text!(state,"/test ");T.chat_completion_input!(state,"u");Shared.flush_work(state)
    @test isnothing(state.error)
    @test state.mode==:none
    selected="/julia do_not_execute()"
    T.register_command!(app,T.CommandSpec("test","Real callback",execute;argument_completions=prefix->[T.ChatCompletionItem(;value=selected)]))
    T.chat_completion_set_text!(state,"/test ");T.chat_completion_input!(state,"u");Shared.flush_work(state)
    accepted=T.chat_completion_input!(state,"\t")
    @test accepted.action==:handled
    @test isempty(executions)
    @test T.chat_text(editor)=="/test "*selected
    response=T.chat_completion_input!(state,"\r")
    @test response.action==:submit
    @test isempty(executions)
    T.submit!(app,response.text)
    @test executions==[selected]
    T.chat_completion_close!(state);T.finish_shutdown!(app);close(session.kernel)
end
@testset "Completion wake-up callbacks observe committed visible state" begin
    notices=Any[];holder=Ref{Any}(nothing)
    changed=()->begin
        state=holder[]
        push!(notices,(revision=state.revision,mode=state.mode,text=T.chat_text(state.editor),error=state.error,selected=state.selected))
    end
    editor=T.ChatEditorState()
    provider=T.ChatCompletionProvider(;commands=()->[T.ChatCompletionCommand(;name="first"),T.ChatCompletionCommand(;name="second")],directory=mktempdir())
    state=T.ChatCompletionState(editor,provider;on_change=changed);holder[]=state
    T.chat_completion_set_text!(state,"/");empty!(notices)
    T.chat_completion_input!(state,"\t");Shared.flush_work(state)
    @test !isempty(notices)
    @test last(notices).mode==:regular
    @test last(notices).text=="/"
    previous=length(notices);T.chat_completion_input!(state,"\e[B")
    @test length(notices)>previous
    @test last(notices).selected==2
    T.chat_completion_input!(state,"\t")
    @test any(notice->notice.text=="/second ",notices)
    @test last(notices).mode==:none
    previous=length(notices);T.chat_completion_set_visible!(state,7)
    @test length(notices)>previous
    T.chat_completion_close!(state)
    @test last(notices).mode==:none
    @test issorted([notice.revision for notice in notices])
    failed=T.ChatCompletionState(T.ChatEditorState(),Shared.FailingCompletionProvider();on_change=()->push!(notices,:failed_ready))
    T.chat_completion_set_text!(failed,"/bad");empty!(notices);T.chat_completion_input!(failed,"\t");Shared.flush_work(failed)
    @test :failed_ready in notices
    @test failed.error=="Denied completion fixture"
    T.chat_completion_close!(failed)
    notification_failure=T.ChatCompletionState(T.ChatEditorState(),provider;on_change=()->error("Owner queue unavailable"))
    T.chat_completion_set_text!(notification_failure,"/")
    @test occursin("Owner queue unavailable",something(notification_failure.error,""))
    T.chat_completion_close!(notification_failure)
end

@testset "Mouse release, external replacement and cached workspace ownership" begin
    provider=T.ChatCompletionProvider(;commands=()->[T.ChatCompletionCommand(;name=name) for name in ["first","second","third"]],directory=mktempdir())
    state=T.ChatCompletionState(T.ChatEditorState(),provider)
    T.chat_completion_set_text!(state,"/");T.chat_completion_input!(state,"\t");Shared.flush_work(state);T.chat_completion_lines(state,60,32)
    T.chat_completion_mouse!(state,:press,:left,5,3,60)
    @test state.pressed==1
    T.chat_completion_mouse!(state,:release,:left,5,30,60)
    @test isnothing(state.pressed)
    @test isnothing(state.press_position)
    T.chat_completion_mouse!(state,:click,:left,5,4,60)
    @test T.chat_text(state.editor)=="/second "
    T.chat_completion_set_text!(state,"/");T.chat_completion_input!(state,"\t");Shared.flush_work(state);T.chat_completion_lines(state,60,32)
    Tachikoma.set_text!(state.editor.input,"replaced outside completion")
    T.chat_completion_mouse!(state,:click,:left,5,3,60)
    @test T.chat_text(state.editor)=="replaced outside completion"
    @test state.mode==:none
    T.chat_completion_close!(state)
    session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=mktempdir())
    app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    cached=mktempdir();app.settings.workspace=cached
    @test T.chat_completion_provider(app).directory==cached
    T.finish_shutdown!(app);close(session.kernel)
end

@testset "Plain-string completion boundaries accept decorated and sliced strings" begin
    directory=mktempdir();write(joinpath(directory,"alpha.txt"),"fixture")
    provider=T.ChatCompletionProvider(;commands=()->T.ChatCompletionCommand[],directory)
    for wrap in (identity,Base.AnnotatedString,text->SubString("X"*text,2))
        prefix=wrap("@\"./alpha")
        @test T.chat_completion_path_parts(prefix)==("./alpha",true,true)
        @test T.chat_completion_value(wrap("alpha file.txt"),true,false)=="@\"alpha file.txt\""
        @test T.chat_completion_value(wrap("plain"),false,false) isa String
        @test T.chat_completion_file_items(provider,wrap("./a"))==T.chat_completion_file_items(provider,"./a")
    end
end

end
