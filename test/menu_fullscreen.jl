# Actual App scenes and raw-key routing; model/auth/persistence callbacks are fixture-only.
using Test,JSON,SHA,JuliaForever2,Tachikoma,CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
module FullMenuSceneTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function serialize(buffer,width,height)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style);print(io,span.content)
        end
        print(io,"\e[0m")
    end for line in T.startup_buffer_rows(buffer,width,height)]
end
function replay(original;emphasis=false)
    frames=Any[];states=Any[]
    mktempdir() do temporary
    for (index,case) in enumerate(original["cases"])
        kind=case["kind"];width=case["width"];height=case["height"]
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=temporary);settings_dir=joinpath(temporary,string(index)),theme_fallback="dark")
        app.settings.workspace="/fixture/project";app.directory="/fixture/project";app.menus.startup.document.quiet=true
        T.refresh_footer_controls!(app;models=JuliaForever2.ModelSpec[],branch=nothing,home=nothing)
        catalog=T.theme_catalog("";preserve_extras=false);catalog.bold=emphasis
        runtime=T.ThemeRuntime(catalog;setting="dark");app.menus.theme_runtime=runtime;T.activate_theme_runtime!(runtime)
        app.page=:pi_menu;app.menus.path=[kind=="scoped" ? "scoped-models" : kind]
        callbacks=Any[]
        closemenu=()->begin
            push!(callbacks,(kind="cancel",))
            kind=="fork" ? T.close_session_selectors!(app) : T.close_model_controls!(app)
            app.page=:chat
        end
        if kind=="thinking"
            app.menus.thinking_menu=T.thinking_menu("medium",T.THINKING_MENU_LEVELS;on_select=identity,on_cancel=closemenu,on_default=identity,default_level="high",focused=true)
        elseif kind=="theme"
            app.menus.theme_menu=T.theme_menu(runtime;standalone=true,available=String.(original["themes"]),
                on_event=(action,setting,result)->begin
                    push!(callbacks,(kind=String(action),value=setting));T.theme_control_event!(app,action,setting,result)
                end)
        elseif kind in ("model","scoped")
            models=[T.SelectorModel(m["provider"],m["id"];name=m["name"],payload=m) for m in original["models"]]
            if kind=="model"
                menu=T.ModelMenu(models;current="demo/alpha",default="demo/beta")
                T.model_menu_refresh!(menu,models);app.menus.model_menu=menu
            else
                app.menus.scoped_menu=T.ScopedModelMenu(models;enabled=nothing)
            end
        else
            messages=[T.ForkMessage(;id=m["id"],text=m["text"]) for m in original["messages"]]
            app.menus.fork_menu=T.fork_menu(messages;on_select=identity,on_cancel=closemenu,bold=runtime.catalog.bold)
        end
        for (step,expected) in enumerate(case["steps"])
            if step>1
                packet=case["inputs"][step-1]
                T.page_input!(app,Val(:pi_menu),Tachikoma.KeyEvent(:unknown),collect(codeunits(packet)))
            end
            area=Tachikoma.Rect(1,1,width,height);buffer=Tachikoma.Buffer(area);frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
            T.default_view!(app,frame)
            push!(frames,(id=expected["id"],width,terminalAnsiLines=serialize(buffer,width,height)))
            push!(states,(id=expected["id"],width,page=String(app.page),source_page=expected["page"],cursor=app.settings.output.cursor,source_cursor=expected["cursor"],events=copy(callbacks),buffer))
        end
        T.close_session_selectors!(app);close(app.session)
    end
end
    (;frames,states)
end
end

@testset "Original fullscreen menu geometry, styles and cancel destinations" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    mktempdir() do temporary
        for (name,emphasis) in (("plain",false),("emphasis",true))
            path=joinpath(@__DIR__,"fixtures","pi-full-menu-"*name*".json")
            cells_path=joinpath(@__DIR__,"fixtures","pi-full-menu-"*name*"-cells.json")
            original=JSON.parsefile(path);cells=JSON.parsefile(cells_path)
            @test cells["sourceSha256"]==bytes2hex(sha256(read(path)))
            @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
            @test length(original["reference"]["sourceHashes"])==513
            if isdir(reference)
                oracle=joinpath(@__DIR__,"differential","pi_full_menu_oracle.mjs")
                provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
                freshpath=joinpath(temporary,"original-"*name*".json")
                withenv("FORCE_COLOR"=>(emphasis ? "3" : "0")) do
                    run(`node $oracle $reference $provenance $freshpath`)
                end
                @test JSON.parsefile(freshpath)==original
            end
            result=FullMenuSceneTests.replay(original;emphasis)
            @test length(result.frames)==198
            for state in result.states
                expected_page=state.source_page=="chat" ? "chat" : "pi_menu"
                @test state.page==expected_page
                expected_cursor=isnothing(state.source_cursor) ? nothing : (state.source_cursor["col"]+1,state.source_cursor["row"]+1)
                @test state.cursor==expected_cursor
                @test isempty(TerminalCellFixture.differences(state.buffer,cells,state.id,state.width))
            end
            if isdir(reference)
                native=joinpath(temporary,"native-"*name*".json");report=joinpath(temporary,"cells-"*name*".json")
                write(native,JSON.json((snapshots=result.frames,)))
                comparator=joinpath(@__DIR__,"..","parity","compare_terminal_cells.mjs")
                run(`node $comparator $path $native $report`)
                @test JSON.parsefile(report)["matching"]==198
            end
        end
    end
end
