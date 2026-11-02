# Actual native model component replay against immutable original-source fixtures.
using JuliaForever2, Tachikoma, JSON, Test
include("../ext/terminal/menu_search_input.jl")
include("../ext/terminal/menu_models.jl")
function ansi(spans)
    io=IOBuffer()
    for span in spans
        Tachikoma.write_style(io,span.style)
        print(io,span.content)
        print(io,"\e[0m")
    end
    String(take!(io))
end
record(m)=SelectorModel(m["provider"],m["id"];name=m["name"],payload=m)
state(menu::ModelMenu)=Dict("selected"=>menu.cursor-1,"scope"=>String(menu.scope),"query"=>menu.search.value,"filtered"=>selector_key.(menu.filtered),"closed"=>menu.closed)
state(menu::ScopedModelMenu)=Dict("selected"=>menu.cursor-1,"query"=>menu.search.value,"filtered"=>menu.filtered,"enabled"=>menu.enabled,"dirty"=>menu.dirty)
function replay(source,out)
    oracle=JSON.parsefile(source)
    frames=Any[]; mismatches=Any[]
    for case in oracle["cases"]
        models=record.(case["models"])
        modelcase=case["kind"]=="model"
        menu=modelcase ? ModelMenu(models;scoped=[m for id in case["scoped"] for m in models if selector_key(m)==id],current=case["current"],default=case["default"]) : ScopedModelMenu(models;enabled=case["enabled"],status="Refreshing model catalogs…")
        events=Any[]
        function capture(step)
            for width in oracle["widths"]
                id=case["id"]*"."*step
                reference=only(filter(f->f["id"]==id && f["width"]==width,oracle["snapshots"]))
                current=state(menu)
                if current!=reference["state"] || events!=reference["events"]
                    push!(mismatches,Dict("id"=>id,"width"=>width,"reference"=>reference["state"],"candidate"=>current,"events"=>copy(events),"expectedEvents"=>reference["events"]))
                end
                lines=modelcase ? model_menu_lines(menu,width) : scoped_models_lines(menu,width)
                push!(frames,Dict("id"=>id,"width"=>width,"ansiLines"=>ansi.(lines),"state"=>deepcopy(current),"events"=>copy(events)))
            end
            empty!(events)
        end
        capture("open")
        for (i,packet) in enumerate(get(case,"preEvents",[]))
            action=model_menu_input!(menu,packet)
            if action.kind!=:none
                push!(events,Dict("kind"=>String(action.kind),"value"=>action.value))
            end
            capture("pre"*string(i-1))
        end
        if modelcase
            refresh=case["refresh"]
            model_menu_refresh!(menu,models;timed_out=refresh=="timeout",errors=refresh=="one-error" ? ["demo"] : refresh=="many-errors" ? ["demo","other"] : String[],reason=refresh=="exception" ? "fixture failed" : "",runtime_error=refresh=="runtime-error" ? "Invalid fixture model configuration" : "")
        else
            scoped_models_status!(menu,"Model catalogs refreshed.",:success)
        end
        capture("refreshed")
        for (i,packet) in enumerate(case["events"])
            action=modelcase ? model_menu_input!(menu,packet) : scoped_models_input!(menu,packet)
            if action.kind!=:none
                value=action.value isa SelectorModel ? selector_key(action.value) : action.value
                push!(events,Dict("kind"=>String(action.kind),"value"=>value))
                if action.kind==:persist
                    scoped_models_saved!(menu)
                end
            end
            capture(string(i-1))
        end
    end
    open(out,"w") do io
        JSON.print(io,Dict("snapshots"=>frames,"mismatches"=>mismatches))
    end
    println("Frames: ",length(frames)," state/action mismatches: ",length(mismatches))
    @test isempty(mismatches)
end
if length(ARGS)==2
    replay(ARGS...)
end

@testset "Native model and scoped-model contracts" begin
    native=JuliaForever2.ModelSpec(:demo,"native";metadata=Dict("name"=>"Native Model"))
    @test ModelMenu([native]).models[1].name=="Native Model"
    @test ScopedModelMenu([native]).models[1].payload===native
    alpha=SelectorModel("demo","alpha";name="Alpha Reasoning",payload=:alpha_backend)
    beta=SelectorModel("demo","beta";name="Beta Fast",payload=:beta_backend)
    gamma=SelectorModel("other","gamma";name="Gamma Limited",payload=:gamma_backend)
    models=[alpha,beta,gamma]
    menu=ModelMenu(models;current="other/gamma",default="demo/beta")
    @test selector_key.(menu.filtered)==["other/gamma","demo/beta","demo/alpha"]
    selected=model_menu_input!(menu,"\r")
    @test selected.kind==:select
    @test selected.value.payload==:gamma_backend
    @test menu.closed
    before=deepcopy(menu.models)
    model_menu_refresh!(menu,SelectorModel[];reason="late failure")
    @test menu.models==before
    @test isempty(menu.error)
    refreshed=ModelMenu(models)
    model_menu_refresh!(refreshed,models;timed_out=true)
    @test refreshed.error=="Model refresh timed out; showing cached models."
    @test isempty(refreshed.status)
    @test length(refreshed.models)==3
    disabled=ModelMenu(models;can_save=false)
    @test model_menu_input!(disabled,"\x13").kind==:none
    @test !disabled.closed
    scoped=ScopedModelMenu(models;enabled=["other/gamma","demo/alpha","gone/missing"])
    @test scoped.filtered==["other/gamma","demo/alpha","gone/missing","demo/beta"]
    result=scoped_models_input!(scoped,"\x1b[1;3B")
    @test result.kind==:change
    @test scoped.enabled==["demo/alpha","other/gamma","gone/missing"]
    @test scoped.cursor==2
    @test scoped.dirty
    requested=scoped_models_input!(scoped,"\x13")
    @test requested.kind==:persist
    @test scoped.dirty # only successful persistence acknowledgement clears dirty state
    push!(requested.value,"unrelated/copy")
    @test !("unrelated/copy" in scoped.enabled)
    scoped_models_saved!(scoped)
    @test !scoped.dirty
    scoped_models_update!(scoped,[alpha,beta])
    @test scoped.filtered[scoped.cursor]=="other/gamma"
    @test isnothing(scoped_models_model(scoped,"other/gamma"))
    scoped_models_input!(scoped,"demo")
    scoped_models_input!(scoped,"\x18")
    @test scoped.enabled==["other/gamma","gone/missing"]
    scoped_models_input!(scoped,"\x01")
    @test scoped.enabled==["other/gamma","gone/missing","demo/beta","demo/alpha"]
    @test scoped_models_input!(scoped,"\x03").kind==:none
    @test isempty(scoped.search.value)
    @test scoped_models_input!(scoped,"\x03").kind==:cancel
    pasted=ModelMenu(models)
    @test model_menu_input!(pasted,"\e[200~gamma\r\e[201~").kind==:none
    @test !pasted.closed
    @test pasted.search.value=="gamma"
    for width in (1,2,10,30,60,100)
        @test all(row->sum(span->menu_search_width(span.content),row;init=0)<=width,model_menu_lines(pasted,width))
        @test all(row->sum(span->menu_search_width(span.content),row;init=0)<=width,scoped_models_lines(scoped,width))
    end
end
