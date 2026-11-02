using Test,JSON,Tachikoma,JuliaForever2,CommonMark

module DefaultThinkingNativeTests
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const App=Owner.App
const KeyEvent=Tachikoma.KeyEvent
const pi_style=Owner.pi_style
const menu_token_score=Owner.menu_token_score
include(joinpath(@__DIR__,"..","ext","terminal","menu_search_input.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_thinking.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_colors.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_system.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_runtime.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_theme.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_thinking_defaults.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_thinking_defaults_render.jl"))
end
const NativeDefaultThinkingTests=DefaultThinkingNativeTests

module DefaultThinkingParentRenderer
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const App=Owner.App
const KeyEvent=Tachikoma.KeyEvent
const MenuSearchInput=Owner.MenuSearchInput
const menu_search_spans=Owner.menu_search_spans
const menu_preference=Owner.menu_preference
const thinking_defaults_summary=Owner.thinking_defaults_summary
const current=Ref{Any}(nothing)
pi_style(key::Symbol)=Main.NativeDefaultThinkingTests.theme_style(current[],key)
include(joinpath(dirname(dirname(pathof(JuliaForever2))),"ext","terminal","menu_settings.jl"))
end

"""Serialize actual native spans, leaving normalization to an independent terminal engine."""
function default_thinking_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,span.content,"\e[0m")
        end
    end for line in lines]
end

"""Use the real existing native settings renderer after its child returns; palette binding is test-only."""
function default_thinking_test_parent_lines(app,menu,width)
    app.menus.path=["settings"]
    app.menus.preferences["theme"]=menu.runtime.committed
    app.menus.model_preferences["thinkingDefaults"]=deepcopy(menu.overrides)
    DefaultThinkingParentRenderer.current[]=menu.runtime
    lines=DefaultThinkingParentRenderer.settings_lines(app,width)
    # Original SettingsList.cursor is constructed once; only its text/value callbacks are dynamic.
    for row in lines
        if !isempty(row) && startswith(first(row).content,"→ ")
            first_span=popfirst!(row)
            pushfirst!(row,Tachikoma.Span(first_span.content[5:end],first_span.style))
            pushfirst!(row,NativeDefaultThinkingTests.theme_span("→ ",menu.original_parent_theme,:accent))
        end
    end
    lines
end

"""Expose the independently owned frontend state and observed real-save callback invocations."""
function default_thinking_state(menu,callbacks)
    active=menu.open
    items=active ? [Dict("value"=>item.value,"label"=>NativeDefaultThinkingTests.thinking_defaults_label(menu,item),"description"=>item.description) for item in menu.items[menu.filtered]] : []
    (open=active,step=active ? String(menu.step) : nothing,context=active ? copy(menu.context) : Dict(),
        query=active && menu.step==:model ? NativeDefaultThinkingTests.menu_search_text(menu.search) : "",
        selectedIndex=active ? menu.cursor-1 : nothing,items,overrides=copy(menu.overrides),callbacks=deepcopy(callbacks),summary=menu.summary)
end

"""Exercise the actual host buffer writer before independently decoding terminal cells."""
function default_thinking_buffer_ansi(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
    DefaultThinkingNativeTests.Owner.draw_menu_lines!(buffer,1,1,width,lines)
    [sprint() do io
        for column in 1:width
            cell=buffer.content[(row-1)*width+column]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style)
                print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for row in eachindex(lines)]
end

@testset "Per-model thinking defaults: original source states and real native rows" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle=joinpath(@__DIR__,"differential","pi_thinking_defaults_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output=joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original=JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"]==513
            failures=[];native=[];expected_rows=[];buffer_native=[];buffer_expected=[]
            for case in original["cases"]
                config=case["config"];width=case["width"];id=case["id"]
                catalog=NativeDefaultThinkingTests.theme_catalog("";preserve_extras=false)
                runtime=NativeDefaultThinkingTests.ThemeRuntime(catalog;setting="dark")
                models=[NativeDefaultThinkingTests.ThinkingDefaultsModel(model["provider"],model["id"];reasoning=model["reasoning"],thinking_level_map=get(model,"thinkingLevelMap",Dict())) for model in config["availableDefaultModels"]]
                current_model=get(config,"currentModel",nothing)
                current=isnothing(current_model) ? nothing : current_model["provider"]*"/"*current_model["id"]
                callbacks=[];path=joinpath(directory,"actual-defaults.json")
                write(path,JSON.json(config["modelThinkingLevels"]))
                function change(provider,id,level)
                    values=JSON.parsefile(path);values[provider*"/"*id]=level;write(path,JSON.json(values))
                    push!(callbacks,Dict("kind"=>"set","provider"=>provider,"id"=>id,"level"=>level))
                    (ok=JSON.parsefile(path)[provider*"/"*id]==level,reason="")
                end
                function remove(provider,id)
                    values=JSON.parsefile(path);delete!(values,provider*"/"*id);write(path,JSON.json(values))
                    push!(callbacks,Dict("kind"=>"remove","provider"=>provider,"id"=>id))
                    (ok=!haskey(JSON.parsefile(path),provider*"/"*id),reason="")
                end
                menu=NativeDefaultThinkingTests.thinking_defaults_menu(runtime,models;on_set=change,on_remove=remove,on_cancel=summary->nothing,
                    overrides=config["modelThinkingLevels"],current,default_model=config["defaultModel"],global_level=config["thinkingLevel"])
                app=DefaultThinkingNativeTests.Owner.App(;settings_dir=mktempdir())
                app.menus.path=["settings"]
                app.menus.cursor=findfirst(item->item.id=="model-thinking",DefaultThinkingParentRenderer.settings_definitions(false))
                for (key,value) in case["initial"]["parentValues"]
                    app.menus.preferences[key]=value
                end
                stages=[(index=-1,event=nothing,after=case["initial"],dispatch=nothing);[(index=step["index"],event=step["event"],after=step["after"],dispatch=step["dispatch"]) for step in case["transitions"]]]
                for stage in stages
                    if !isnothing(stage.event)
                        if stage.event["kind"]=="mouse"
                            result=NativeDefaultThinkingTests.thinking_defaults_mouse!(menu,2,get(stage.event,"y",5);action=Symbol(stage.event["type"]),wheel_delta=get(stage.event,"wheelDelta",0))
                            if result!=stage.dispatch
                                push!(failures,(id,width,index=stage.index,field="mouse",actual=result,expected=stage.dispatch))
                            end
                        else
                            NativeDefaultThinkingTests.thinking_defaults_input!(menu,stage.event["data"])
                        end
                    end
                    actual=JSON.parse(JSON.json(default_thinking_state(menu,callbacks)))
                    for (field,value) in actual
                        if value!=stage.after[field]
                            push!(failures,(id,width,index=stage.index,field,actual=value,expected=stage.after[field]))
                        end
                    end
                    @test JSON.parsefile(path)==menu.overrides
                    rows=menu.open ? NativeDefaultThinkingTests.thinking_defaults_lines(menu,width) : default_thinking_test_parent_lines(app,menu,width)
                    frameid=stage.index<0 ? id*".initial" : id*".step-$(stage.index)"
                    push!(native,(id=frameid,width,ansiLines=default_thinking_test_ansi(rows)))
                    push!(expected_rows,(id=frameid,width,terminalAnsiLines=stage.after["terminalAnsiLines"]))
                    if width>=30
                        push!(buffer_native,(id=frameid,width,ansiLines=default_thinking_buffer_ansi(rows,width)))
                        push!(buffer_expected,last(expected_rows))
                    end
                end
                close(app.session)
            end
            evidence=get(ENV,"DEFAULT_THINKING_EVIDENCE_DIR",directory);mkpath(evidence)
            write(joinpath(evidence,"native.json"),JSON.json((snapshots=native,)))
            write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected_rows,)))
            write(joinpath(evidence,"states.json"),JSON.json((frames=length(native),failures)))
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            foreach(println,first(failures,min(8,length(failures))))
            @test isempty(failures)
            @test length(native)==original["summary"]["frames"]
            comparator=joinpath(dirname(dirname(pathof(JuliaForever2))),"parity","compare_terminal_cells.mjs")
            reference_path,native_path,cells_path=(joinpath(evidence,name) for name in ("reference.json","native.json","cells.json"))
            run(`node $comparator $reference_path $native_path $cells_path`)
            cells=JSON.parsefile(cells_path)
            @test cells["checked"]==length(native) && cells["matching"]==length(native)
            native_path=joinpath(evidence,"native-buffer.json");reference_path=joinpath(evidence,"reference-buffer.json");cells_path=joinpath(evidence,"buffer-cells.json")
            write(native_path,JSON.json((snapshots=buffer_native,)));write(reference_path,JSON.json((snapshots=buffer_expected,)))
            run(`node $comparator $reference_path $native_path $cells_path`)
            cells=JSON.parsefile(cells_path)
            @test cells["checked"]==length(buffer_native) && cells["matching"]==length(buffer_native)
        end
    end
end
@testset "Per-model defaults require confirmed save and retain independent runtime" begin
    N=NativeDefaultThinkingTests
    runtime=N.ThemeRuntime(N.theme_catalog("";preserve_extras=false);setting="dark")
    palette=runtime.active
    values=Dict("demo/alpha"=>"high","unavailable/old"=>"low")
    model=N.ThinkingDefaultsModel("demo","alpha";thinking_level_map=Dict("max"=>"max"))
    events=[]
    menu=N.thinking_defaults_menu(runtime,[model];overrides=values,current="demo/alpha",global_level="medium",
        on_set=(provider,id,level)->(push!(events,(:set,provider,id,level));(ok=false,reason="default store denied")),
        on_remove=(provider,id)->(push!(events,(:remove,provider,id));(ok=false,reason="remove denied")),
        on_cancel=summary->push!(events,(:back,summary)))
    @test N.thinking_defaults_summary(menu)=="2 configured"
    N.thinking_defaults_input!(menu,"\r")
    @test menu.step==:level
    menu.cursor=findfirst(item->item.value=="max",menu.items)
    outcome=N.thinking_defaults_input!(menu,"\r")
    @test outcome.kind==:set && !outcome.outcome.ok
    @test menu.open && menu.step==:level && menu.last_error=="default store denied"
    @test menu.overrides==values && menu.overrides!==values
    @test runtime.active===palette && runtime.committed=="dark"
    menu.cursor=findfirst(item->item.value=="__clear__",menu.items)
    outcome=N.thinking_defaults_input!(menu,"\r")
    @test outcome.kind==:remove && !outcome.outcome.ok
    @test menu.overrides==values && menu.last_error=="remove denied"
    N.thinking_defaults_input!(menu,"\e")
    @test menu.step==:model && menu.open
    N.thinking_defaults_input!(menu,"\e")
    @test !menu.open && menu.summary=="2 configured"
    @test last(events)==(:back,"2 configured")
    before=copy(events)
    @test isnothing(N.thinking_defaults_input!(menu,"\r"))
    @test events==before
    @test isnothing(N.thinking_defaults_mouse!(menu,0,0;action=:click))
    absent=N.thinking_defaults_menu(runtime,[model];on_set=(args...)->nothing,on_remove=(args...)->nothing,on_cancel=summary->nothing)
    N.thinking_defaults_input!(absent,"\r");N.thinking_defaults_input!(absent,"\r")
    @test absent.step==:level && isempty(absent.overrides)
    @test absent.last_error=="Owner did not confirm saving the default"
    sorted=N.thinking_defaults_menu(runtime,[N.ThinkingDefaultsModel("system","a"),N.ThinkingDefaultsModel("alpha","b")];on_set=(args...)->nothing,on_remove=(args...)->nothing,on_cancel=summary->nothing)
    @test first(sorted.items).value=="alpha/b"
end
