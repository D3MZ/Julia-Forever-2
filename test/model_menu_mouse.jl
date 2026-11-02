module NativeModelMouseTests
using JuliaForever2,Tachikoma,JSON,Test
include("../ext/terminal/menu_search_input.jl")
include("../ext/terminal/menu_models.jl")
function ansi(spans)
    io=IOBuffer()
    for span in spans
        Tachikoma.write_style(io,span.style);print(io,span.content,"\e[0m")
    end
    String(take!(io))
end
record(m)=SelectorModel(m["provider"],m["id"];name=m["name"],payload=m)
function state(menu)
    prefix=join(menu_search_graphemes(menu.search.value)[1:menu.search.cursor])
    Dict("query"=>menu.search.value,"cursor"=>length(transcode(UInt16,prefix)),"selected"=>menu.cursor-1,
        "enabled"=>menu isa ScopedModelMenu ? menu.enabled : nothing,"closed"=>menu isa ModelMenu ? menu.closed : false,"searchRow"=>menu.search_row,"height"=>menu.height)
end
function replay(source,out)
    oracle=JSON.parsefile(source);snapshots=Any[];failures=Any[]
    for case in oracle["cases"]
        models=record.(case["models"]);kind=case["kind"];width=case["width"]
        menu=kind=="model" ? ModelMenu(models;current="demo/alpha",default="demo/beta") : ScopedModelMenu(models;enabled=case["enabled"],status="Model catalogs refreshed.")
        if menu isa ModelMenu
            model_menu_refresh!(menu,models)
        else
            scoped_models_status!(menu,"Model catalogs refreshed.",:success)
        end
        events=Any[];step=0
        function capture(result=nothing)
            lines=model_selector_lines(menu,width)
            id=case["id"]*"."*string(step);step+=1
            reference=only(filter(f->f["id"]==id,oracle["snapshots"]))
            response=isnothing(result) ? nothing : Dict(string(key)=>getproperty(result,key) for key in (:handled,:focus,:capture,:render,:target,:focusTarget))
            snapshot=Dict("id"=>id,"width"=>width,"ansiLines"=>ansi.(lines),"state"=>deepcopy(state(menu)),"events"=>copy(events),"result"=>response)
            if snapshot["state"]!=reference["state"] || events!=reference["events"] || response!=reference["result"]
                push!(failures,Dict("id"=>id,"reference"=>reference,"candidate"=>snapshot))
            end
            push!(snapshots,snapshot);empty!(events)
        end
        capture()
        for event in case["steps"]
            response=nothing
            if event["type"]=="key"
                action=menu isa ModelMenu ? model_menu_input!(menu,event["data"]) : scoped_models_input!(menu,event["data"])
                if action.kind!=:none
                    value=action.value isa SelectorModel ? selector_key(action.value) : action.value
                    push!(events,Dict("kind"=>String(action.kind),"value"=>value))
                end
            else
                row=event["row"]
                y=row=="search" ? menu.search_row : row=="list" ? menu.search_row+2 : row=="above" ? -1 : row=="below" ? menu.height : event["y"]
                dispatch=menu isa ModelMenu ? model_menu_mouse! : scoped_models_mouse!
                response=dispatch(menu,event["x"],y;action=Symbol(event["action"]),button=Symbol(get(event,"button","left")),wheel_delta=get(event,"wheelDelta",0),bounded=get(event,"bounded",true))
            end
            capture(response)
        end
    end
    open(out,"w") do io
        JSON.print(io,Dict("snapshots"=>snapshots,"failures"=>failures))
    end
    @test isempty(failures)
    println("Mouse state/action/result frames: ",length(snapshots),"; mismatches: ",length(failures))
end
@testset "Native model mouse bounds and ownership" begin
    models=[SelectorModel("demo","alpha"),SelectorModel("demo","beta")]
    for menu in (ModelMenu(models),ScopedModelMenu(models))
        model_selector_lines(menu,30)
        menu_search_set!(menu.search,"abcdef";at_end=true)
        model_selector_lines(menu,30)
        dispatch=menu isa ModelMenu ? model_menu_mouse! : scoped_models_mouse!
        cursor=menu.cursor
        @test isnothing(dispatch(menu,5,menu.search_row+2;action=:press))
        @test isnothing(dispatch(menu,5,menu.search_row+2;action=:wheel,wheel_delta=1))
        @test menu.cursor==cursor
        @test dispatch(menu,3,menu.search_row).focusTarget=="selector"
        @test menu.search.cursor==1
        @test isnothing(dispatch(menu,3,menu.search_row;action=:release))
        @test isnothing(dispatch(menu,3,menu.search_row;action=:click))
        @test isnothing(dispatch(menu,3,menu.search_row;button=:right))
        @test isnothing(dispatch(menu,-1,menu.search_row))
        @test isnothing(dispatch(menu,30,menu.search_row))
        @test isnothing(dispatch(menu,3,-1))
        @test isnothing(dispatch(menu,3,menu.height))
        @test isnothing(dispatch(menu,3,menu.search_row;height=menu.search_row))
        @test dispatch(menu,-1,menu.search_row;bounded=false).handled
        @test menu.search.cursor==0
        model_selector_lines(menu,10)
        @test menu.width==10
        @test dispatch(menu,3,menu.search_row).handled
    end
end
if length(ARGS)==2 && isfile(ARGS[1])
    replay(ARGS...)
end
end
