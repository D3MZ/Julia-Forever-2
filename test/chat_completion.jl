using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module ChatCompletionTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
for (name,symbol) in (("editor_state",:ChatEditorState),("editor_words",:chat_icu_segments),("editor_layout",:chat_editor_lines),("editor_input",:chat_editor_input!),("completion_provider",:ChatCompletionProvider),("completion_state",:ChatCompletionState),("completion_render",:chat_completion_lines),("completion_controls",:chat_completion_provider))
    isdefined(T,symbol) || Base.include(T,joinpath(@__DIR__,"..","ext","terminal","chat_"*name*".jl"))
end
function flush_work(state)
    timer=state.timer
    isnothing(timer) || wait(timer)
    yield()
    worker=state.worker
    isnothing(worker) || wait(worker;throw=false)
end
itemdict(item)=Dict("value"=>item.value,"label"=>item.label,(isnothing(item.description) ? Pair{String,Any}[] : ["description"=>item.description])...)
resultdict(::Nothing)=nothing
resultdict(result::T.ChatCompletionResult)=Dict("prefix"=>result.prefix,"items"=>itemdict.(result.items))
function buffer_lines(rows,width)
    backend=TestBackend(width,max(1,length(rows)));T.session_draw_lines!(backend.buf,1,1,width,rows)
    [sprint() do io
        for x in 1:width
            cell=backend.buf.content[(y-1)*width+x]
            if cell.char!=Tachikoma.WIDE_CHAR_PAD
                print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for y in 1:length(rows)]
end
@testset "Pinned completion provider and actual editor list transitions" for fixture_name in ("pi-chat-completion-oracle.json","pi-chat-attachment-oracle.json","pi-chat-completion-navigation-oracle.json")
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures",fixture_name))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        freshpath=joinpath(mktempdir(),"original-fresh.json")
        script=occursin("attachment",fixture_name) ? "pi_chat_attachment_oracle.mjs" : occursin("navigation",fixture_name) ? "pi_chat_completion_navigation_oracle.mjs" : "pi_chat_completion_oracle.mjs"
        command=`node $(joinpath(@__DIR__,"differential",script)) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $freshpath`
        if occursin("attachment",fixture_name)
            command=`$command $(T.chat_completion_find_fd())`
        end
        run(command)
        fresh=JSON.parsefile(freshpath)
        @test fresh["cases"]==fixture["cases"]
        @test fresh["providerCases"]==fixture["providerCases"]
        @test fresh["snapshots"]==fixture["snapshots"]
    end
    directory=mktempdir()
    for file in fixture["files"]
        path=joinpath(directory,file);mkpath(dirname(path));write(path,get(get(fixture,"contents",Dict()),file,"fixture"))
    end
    commands=[T.ChatCompletionCommand(;name=record["name"],description=get(record,"description",""),argument_hint=get(record,"argumentHint",nothing),arguments=record["name"]=="test" ? prefix->[T.ChatCompletionItem(;value,label=value,description="actual argument "*value) for value in ["all","unit","smoke"] if startswith(value,prefix)] : nothing) for record in fixture["commands"]]
    provider=T.ChatCompletionProvider(;commands=()->commands,directory,finder=get(ENV,"CHAT_COMPLETION_FD",T.chat_completion_find_fd()))
    for case in fixture["providerCases"]
        snapshot=(text=case["text"],cursor=length(case["text"]))
        result=T.chat_completion_suggest(provider,snapshot,case["force"],Threads.Atomic{Bool}(false))
        @test resultdict(result)==case["result"]
        for action in case["applied"]
            item=action["item"];record=T.ChatCompletionItem(;value=item["value"],label=item["label"],description=get(item,"description",nothing))
            applied=T.chat_completion_apply(provider,snapshot,record,case["result"]["prefix"])
            @test applied.text==join(action["result"]["lines"],'\n')
            @test applied.cursor==action["result"]["cursorCol"]
        end
    end
    frames=Any[];states=Any[];differences=Any[]
    runtime=T.ThemeRuntime(T.ThemeCatalog(;directory=mktempdir(),appearance=:dark);setting="dark")
    for case in fixture["cases"]
        editor=T.ChatEditorState();editor.focused=true;T.chat_set_text!(editor,case["initial"])
        controller=T.ChatCompletionState(editor,provider;max_visible=case["maxVisible"]);events=Any[]
        for (index,step) in enumerate(case["steps"])
            if index>1
                input=case["inputs"][index-1]
                response=if input isa AbstractString
                    T.chat_completion_input!(controller,input)
                else
                    mouse=input["mouse"];T.chat_completion_mouse!(controller,Symbol(mouse["type"]),Symbol(mouse["button"]),mouse["x"],mouse["y"],case["width"])
                    (action=:handled,text="")
                end
                flush_work(controller)
                if response.action==:submit
                    push!(events,Dict("kind"=>"submit","text"=>response.text));T.chat_accept!(editor)
                elseif response.action==:interrupt
                    push!(events,Dict("kind"=>"interrupt"))
                end
            end
            position=T.chat_position(editor);logical=split(T.chat_text(editor),'\n';keepempty=true)
            state=Dict("text"=>T.chat_text(editor),"cursorLine"=>position.line-1,"cursorCol"=>T.chat_utf16(T.chat_prefix(logical[position.line],position.col)),"mode"=>controller.mode==:none ? nothing : String(controller.mode),"prefix"=>controller.prefix,"selected"=>controller.mode==:none ? nothing : controller.selected-1,"items"=>itemdict.(controller.items),"events"=>copy(events))
            @test state==step["state"]
            state==step["state"] || push!(differences,Dict("id"=>step["frameId"],"width"=>case["width"],"expected"=>step["state"],"actual"=>state))
            rendered=T.chat_completion_lines(controller,case["width"],32;runtime)
            push!(frames,Dict("id"=>step["frameId"],"width"=>case["width"],"terminalAnsiLines"=>buffer_lines(rendered.lines,case["width"])))
            push!(states,state)
        end
        T.chat_completion_close!(controller)
    end
    evidence=joinpath(get(ENV,"CHAT_COMPLETION_EVIDENCE",mktempdir()),fixture_name);mkpath(evidence)
    write(joinpath(evidence,"native.json"),JSON.json(Dict("snapshots"=>frames,"states"=>states)))
    write(joinpath(evidence,"differences.json"),JSON.json(differences))
end
struct DeferredProvider
    calls::Vector{Any}
    results::Vector{Channel{Any}}
end
function T.chat_completion_suggest(provider::DeferredProvider,snapshot,force,cancelled)
    channel=Channel{Any}(1);push!(provider.calls,(;snapshot,cancelled));push!(provider.results,channel)
    take!(channel)
end
await_calls(provider,count)=Base.timedwait(()->length(provider.calls)>=count,5;pollint=0.001)
@testset "Actual asynchronous stale and cancelled requests cannot publish" begin
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-chat-completion-async-oracle.json"))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        freshpath=joinpath(mktempdir(),"original-async-fresh.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_chat_completion_async_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $freshpath`)
        @test JSON.parsefile(freshpath)==fixture
    end
    provider=DeferredProvider(Any[],Channel{Any}[]);editor=T.ChatEditorState();state=T.ChatCompletionState(editor,provider)
    trace=Any[]
    capture(id)=push!(trace,Dict("id"=>id,"text"=>T.chat_text(editor),"calls"=>[Dict("text"=>call.snapshot.text,"aborted"=>call.cancelled[]) for call in provider.calls],"mode"=>state.mode==:none ? nothing : String(state.mode),"items"=>[item.value for item in state.items]))
    T.chat_completion_set_text!(state,"/old");T.chat_completion_input!(state,"\t");@test await_calls(provider,1)==:ok;capture("first-started")
    T.chat_completion_set_text!(state,"/new");T.chat_completion_input!(state,"\t");yield();@test length(provider.calls)==1;capture("new-waits-for-old")
    put!(provider.results[1],T.ChatCompletionResult(;prefix="/old",items=[T.ChatCompletionItem(;value="old")]))
    @test await_calls(provider,2)==:ok;capture("stale-old-rejected")
    put!(provider.results[2],T.ChatCompletionResult(;prefix="/new",items=[T.ChatCompletionItem(;value="new")]))
    flush_work(state);capture("new-published")
    T.chat_completion_set_text!(state,"/cancel");T.chat_completion_input!(state,"\t");@test await_calls(provider,3)==:ok;T.chat_completion_cancel!(state);capture("cancel-pending")
    put!(provider.results[3],T.ChatCompletionResult(;prefix="/cancel",items=[T.ChatCompletionItem(;value="cancel")]))
    flush_work(state);capture("cancel-cannot-publish")
    @test trace==fixture["trace"]
    T.chat_completion_close!(state)
end

struct FailingCompletionProvider end
T.chat_completion_suggest(::FailingCompletionProvider,snapshot,force,cancelled)=error("Denied completion fixture")
struct ImmediateCompletionProvider end
T.chat_completion_suggest(::ImmediateCompletionProvider,snapshot,force,cancelled)=T.ChatCompletionResult(;prefix="@",items=[T.ChatCompletionItem(;value="@actual.txt")])
@testset "Completion failures, external replacement, debounce, close and real registered commands" begin
    editor=T.ChatEditorState();state=T.ChatCompletionState(editor,FailingCompletionProvider())
    T.chat_completion_set_text!(state,"/denied");T.chat_completion_input!(state,"\t");flush_work(state)
    @test state.error=="Denied completion fixture"
    @test T.chat_text(editor)=="/denied"
    @test state.mode==:none
    T.chat_completion_close!(state)
    editor=T.ChatEditorState();state=T.ChatCompletionState(editor,ImmediateCompletionProvider())
    T.chat_completion_set_text!(state,"@");T.chat_completion_request!(state)
    @test !isnothing(state.timer)
    @test isnothing(state.worker)
    flush_work(state)
    @test state.mode==:regular
    @test only(state.items).value=="@actual.txt"
    Tachikoma.set_text!(editor.input,"changed externally");T.chat_completion_lines(state,30,32)
    @test state.mode==:none
    T.chat_completion_set_text!(state,"@");T.chat_completion_request!(state);timer=state.timer
    T.chat_completion_close!(state)
    @test !isopen(timer)
    @test state.closed
    before=T.chat_text(editor)
    T.chat_completion_input!(state,"not inserted")
    @test T.chat_text(editor)==before
    @test !T.chat_completion_mouse!(state,:click,:left,1,1,30).handled
    @test state.mode==:none
    for (value,expected) in ((2,3),(30,20),(NaN,5),(5.9,5))
        T.chat_completion_set_visible!(state,value);@test state.max_visible==expected
    end
    workspace=mktempdir();write(joinpath(workspace,"actual.txt"),"content never read")
    session=Session(Kernel((messages,session)->error("No model calls"));working_directory=workspace)
    app=T.App(session;settings_dir=mktempdir(),registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
    T.register_command!(app,T.CommandSpec("completion-proof","Real registered action",(app,args)->nothing))
    provider=T.chat_completion_provider(app)
    @test provider.directory==workspace
    result=T.chat_completion_suggest(provider,(text="/completion-proof",cursor=17),false,Threads.Atomic{Bool}(false))
    @test !isnothing(result)
    @test any(item->item.value=="completion-proof",result.items)
    T.remove_command!(app,"completion-proof")
    result=T.chat_completion_suggest(provider,(text="/completion-proof",cursor=17),false,Threads.Atomic{Bool}(false))
    @test isnothing(result)
    result=T.chat_completion_suggest(provider,(text="./act",cursor=5),true,Threads.Atomic{Bool}(false))
    @test only(result.items).value=="./actual.txt"
    kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end

@testset "Installed fd ownership and missing, failed, cancelled searches" begin
    finder=JuliaForever2.FileSearchTools.installed_fd()
    @test !isnothing(finder)
    @test read(`$finder --version`,String)=="fd 10.5.0\n"
    @test isnothing(JuliaForever2.FileSearchTools.installed_fd(;manifest=joinpath(mktempdir(),"absent.toml")))
    directory=mktempdir();provider=T.ChatCompletionProvider(;commands=()->T.ChatCompletionCommand[],directory,finder=nothing)
    editor=T.ChatEditorState();state=T.ChatCompletionState(editor,provider)
    T.chat_completion_set_text!(state,"@file");T.chat_completion_input!(state,"\t");flush_work(state)
    @test occursin("requires an installed fd",something(state.error,""))
    @test T.chat_text(editor)=="@file"
    @test state.mode==:none
    failed=Sys.which("false")
    @test !isnothing(failed)
    failure=T.preference_attempt(()->T.chat_completion_fd_entries(failed,directory,"",Threads.Atomic{Bool}(false)))
    @test !failure.ok
    @test occursin("file finder failed",failure.reason)
    marker=joinpath(directory,"started");script=joinpath(directory,"slow-fd")
    write(script,"#!/usr/bin/env python3\nimport pathlib,time\npathlib.Path("*repr(marker)*").write_text('started')\ntime.sleep(10)\n")
    chmod(script,0o700);cancelled=Threads.Atomic{Bool}(false)
    worker=@async T.chat_completion_fd_entries(script,directory,"",cancelled)
    @test Base.timedwait(()->isfile(marker),5;pollint=0.002)==:ok
    cancelled[]=true
    @test Base.timedwait(()->istaskdone(worker),5;pollint=0.002)==:ok
    @test isempty(fetch(worker))
    write(joinpath(directory,"--help"),"literal filename")
    rows=T.chat_completion_fd_entries(finder,directory,"--help",Threads.Atomic{Bool}(false))
    @test any(row->basename(row.path)=="--help",rows)
    @test T.chat_completion_label("safe \e[31m label") == "safe \\e[31m label"
    @test T.chat_completion_label("α界") == "α界"
    write(joinpath(directory,"line\nname"),"literal multiline filename")
    rows=T.chat_completion_fd_entries(finder,directory,"line",Threads.Atomic{Bool}(false))
    @test length(rows)==1
    @test endswith(only(rows).path,"line\nname")
    T.chat_completion_close!(state)
end

end
