using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module ChatEditorTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
for (name,symbol) in (("state",:ChatEditorState),("words",:chat_icu_segments),("layout",:chat_editor_lines),("input",:chat_editor_input!),("controls",:chat_editor_escape!))
    isdefined(T,symbol) || Base.include(T,joinpath(@__DIR__,"..","ext","terminal","chat_editor_"*name*".jl"))
end
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
@testset "Pinned original multiline editor state and native rendered transitions" for fixture in (haskey(ENV,"CHAT_EDITOR_FIXTURE") ? [ENV["CHAT_EDITOR_FIXTURE"]] : ["pi-chat-editor-oracle.json","pi-chat-editor-extended-oracle.json"])
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures",fixture))
    evidence=joinpath(get(ENV,"CHAT_EDITOR_EVIDENCE",mktempdir()),fixture);mkpath(evidence)
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        path=joinpath(mktempdir(evidence),"original-fresh.json")
        oracle=occursin("extended",fixture) ? "pi_chat_editor_extended_oracle.mjs" : "pi_chat_editor_oracle.mjs"
        run(`node $(joinpath(@__DIR__,"differential",oracle)) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
        fresh=JSON.parsefile(path)
        @test fresh["cases"]==original["cases"]
        @test fresh["snapshots"]==original["snapshots"]
        original=fresh
    end
    frames=Any[];states=Any[];differences=Any[]
    runtime=T.ThemeRuntime(T.ThemeCatalog(;directory=mktempdir(),appearance=:dark);setting="dark")
    for case in original["cases"]
        editor=T.ChatEditorState();editor.focused=true
        T.chat_add_history!(editor,"oldest");T.chat_add_history!(editor,"newest");T.chat_set_text!(editor,case["initial"])
        events=Any[];hardware=false
        for (index,step) in enumerate(case["steps"])
            if index>1
                action=case["inputs"][index-1]
                response=if action isa AbstractString
                    T.chat_editor_input!(editor,action)
                else
                    if haskey(action,"set")
                        T.chat_set_text!(editor,action["set"])
                    elseif haskey(action,"disabled")
                        editor.disable_submit=action["disabled"]
                    elseif haskey(action,"hardware")
                        hardware=action["hardware"]
                    elseif haskey(action,"focused")
                        editor.focused=action["focused"]
                    elseif haskey(action,"mouse")
                        mouse=action["mouse"]
                        T.chat_editor_mouse!(editor,Symbol(mouse["type"]),Symbol(mouse["button"]),mouse["x"],mouse["y"],get(step,"frameWidth",case["width"]);padding=get(step,"padding",0))
                    end
                    (action=:handled,text="")
                end
                if response.action==:submit
                    push!(events,Dict("kind"=>"submit","text"=>response.text));T.chat_accept!(editor)
                elseif response.action in (:exit,:interrupt)
                    push!(events,Dict("kind"=>response.action==:exit ? "exit" : "interrupt"))
                end
            end
            width=get(step,"frameWidth",case["width"])
            rendered=T.chat_editor_lines(editor,width,32;runtime,padding=get(step,"padding",0),hardware_cursor=hardware)
            position=T.chat_position(editor)
            logical=split(T.chat_text(editor),'\n';keepempty=true)
            state=Dict("text"=>T.chat_text(editor),"expanded"=>T.chat_expanded_text(editor),"cursorLine"=>position.line-1,
                "cursorCol"=>T.chat_utf16(T.chat_prefix(logical[position.line],position.col)),"scrollOffset"=>editor.scroll,
                "historyIndex"=>editor.history_index,"pastes"=>[[key,value] for (key,value) in sort(collect(editor.pastes))],"events"=>copy(events))
            expected=Dict(key=>value for (key,value) in step["state"] if key!="cursor")
            @test state==expected
            cursor=step["state"]["cursor"]
            @test rendered.cursor_row==(isnothing(cursor) ? nothing : cursor["row"]+1)
            @test rendered.cursor_col==(isnothing(cursor) ? nothing : cursor["col"]+1)
            state==expected || push!(differences,Dict("id"=>step["frameId"],"width"=>width,"expected"=>expected,"actual"=>state))
            push!(states,Dict("id"=>step["frameId"],"width"=>width,"state"=>state,"cursor_row"=>rendered.cursor_row,"cursor_col"=>rendered.cursor_col))
            push!(frames,Dict("id"=>step["frameId"],"width"=>width,"terminalAnsiLines"=>buffer_lines(rendered.lines,width)))
        end
    end
    write(joinpath(evidence,"native.json"),JSON.json(Dict("snapshots"=>frames,"states"=>states)))
    write(joinpath(evidence,"differences.json"),JSON.json(differences))
    @test isempty(differences)
end
@testset "Actual session selectors obey source double-Escape timing and preserve active operations" begin
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-editor-owner-oracle.json"))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        path=joinpath(mktempdir(),"owner-original-fresh.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_editor_owner_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
        @test JSON.parsefile(path)==original
    end
    for case in original["cases"]
        directory=mktempdir();write(joinpath(directory,"terminal-settings.json"),JSON.json(Dict("double-escape-action"=>case["setting"])))
        app=T.App(Session(Kernel((messages,session)->error("Owner fixture must not call a model")));settings_dir=directory,registry=JuliaForever2.ProviderRegistry(),theme_fallback="dark")
        editor=T.ChatEditorState(app.input);events=String[]
        for (step,state) in zip(case["steps"],case["states"])
            haskey(step,"text") && T.chat_set_text!(editor,step["text"])
            result=T.chat_editor_escape!(app,editor;now_ms=step["now"])
            @test result.ok
            result.action!=:none && push!(events,String(result.action))
            @test events==state["events"]
            @test editor.last_escape_ms==state["lastEscape"]
            @test T.chat_text(editor)==state["text"]
            if result.action!=:none
                @test app.page==:pi_menu
                @test app.menus.path==[String(result.action)]
                @test result.action==:tree ? !isnothing(app.menus.tree_menu) : !isnothing(app.menus.fork_menu)
            end
        end
        before=editor.last_escape_ms;app.busy=true
        @test !T.chat_editor_escape!(app,editor;now_ms=before+20).ok
        @test editor.last_escape_ms==before
        app.busy=false;kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
    end
end

@testset "Native dictionary ownership and acceptance retain shared editor state" begin
    @test isempty(JuliaForever2.WordSegmentation.segments(""))
    records=JuliaForever2.WordSegmentation.segments("hi 👩‍💻 café")
    @test join(record.text for record in records)=="hi 👩‍💻 café"
    @test all(record.start<record.stop for record in records)
    @test last(records).stop==length("hi 👩‍💻 café")
    input=Tachikoma.TextInput(;label="");editor=T.ChatEditorState(input)
    T.chat_set_text!(editor,"not accepted")
    requested=T.chat_editor_input!(editor,"\r")
    @test requested==(action=:submit,text="not accepted")
    @test T.chat_text(editor)=="not accepted"
    @test editor.input===input
    T.chat_add_history!(editor,requested.text);T.chat_accept!(editor)
    @test isempty(T.chat_text(editor))
    @test editor.history==["not accepted"]
    Tachikoma.set_text!(input,"external 👩‍💻 draft");T.chat_sync!(editor)
    @test T.chat_text(editor)=="external 👩‍💻 draft"
    @test editor.observed==Tachikoma.text(input)
end

end
