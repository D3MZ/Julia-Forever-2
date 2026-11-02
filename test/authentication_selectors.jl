using Test,JSON,SHA,Tachikoma,JuliaForever2,CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
isdefined(@__MODULE__,:AuthenticationFixture) || include("differential/authentication_fixture.jl")
module AuthSelectorNativeTests
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const MenuSearchInput=Owner.MenuSearchInput
const menu_search_set! = Owner.menu_search_set!
const menu_search_input! = Owner.menu_search_input!
const menu_search_spans = Owner.menu_search_spans
const menu_search_width = Owner.menu_search_width
const selector_filter=Owner.selector_filter
const model_menu_wrap=Owner.model_menu_wrap
include(joinpath(@__DIR__,"..","ext","terminal","authentication_selectors.jl"))
end
const NativeAuth=AuthSelectorNativeTests
function auth_test_option(value)
    status=get(value,"status",nothing)
    observed=isnothing(status) ? nothing : NativeAuth.AuthProviderStatus(;kind=Symbol(status["type"]),source=get(status,"source",""))
    NativeAuth.AuthProviderOption(;id=value["id"],name=value["name"],kind=Symbol(value["authType"]),method_name=get(get(value,"method",Dict()),"name",""),subscription=get(value,"subscription",true),status=observed)
end
function auth_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,span.content,"\e[0m")
        end
    end for line in lines]
end
"""Capture actual Tachikoma buffer output rather than an intended layout description."""
function auth_test_buffer(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
    NativeAuth.Owner.draw_menu_lines!(buffer,1,1,width,lines)
    buffer
end
function auth_test_buffer_ansi(lines,width)
    buffer=auth_test_buffer(lines,width)
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
function auth_test_state(menu::NativeAuth.AuthProviderMenu,callbacks)
    (selected=menu.cursor-1,query=menu.search.value,filtered=[option.id*"/"*String(option.kind) for option in menu.filtered],callbacks=deepcopy(callbacks))
end
auth_test_state(menu::NativeAuth.AuthMethodMenu,callbacks)=(selected=menu.cursor-1,query="",filtered=[option.label for option in menu.options],callbacks=deepcopy(callbacks))

@testset "Original Pi auth selector rendering and input transitions" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    begin
        mktempdir() do directory
            oracle=joinpath(@__DIR__,"differential","pi_auth_selectors_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            original_path=joinpath(directory,"original.json")
            original,cell_fixture=AuthenticationFixture.load(:selectors,reference,original_path)
            evidence=get(ENV,"AUTH_SELECTOR_EVIDENCE",directory)
            mkpath(evidence)
            cp(original_path,joinpath(evidence,"reference-full.json");force=true)
            frames=[];expected=[];failures=[];buffer_frames=[]
            for case in original["cases"]
                config=case["config"]
                catalog=NativeAuth.Owner.theme_catalog("";preserve_extras=false)
                catalog.bold=original["capabilities"]["bold"]
                runtime=NativeAuth.Owner.ThemeRuntime(catalog;setting=case["theme"])
                style=token->token==:default ? Tachikoma.Style() : NativeAuth.Owner.theme_style(runtime,token)
                callbacks=[]
                cancelled=()->push!(callbacks,Dict("kind"=>"cancel"))
                provider=case["kind"]=="provider"
                menu=if provider
                    NativeAuth.AuthProviderMenu(auth_test_option.(config["providers"]);style,bold=runtime.active.bold,on_select=option->push!(callbacks,Dict("kind"=>"select","id"=>option.id,"type"=>String(option.kind))),on_cancel=cancelled,mode=Symbol(config["mode"]),query=get(config,"query",""))
                else
                    NativeAuth.AuthMethodMenu(config["title"],[NativeAuth.AuthMethodOption(;id=string(index),label) for (index,label) in enumerate(config["options"])];style,bold=runtime.active.bold,on_select=option->push!(callbacks,Dict("kind"=>"select","value"=>option.label)),on_cancel=cancelled,description=get(config,"description",""))
                end
                for (index,stage) in enumerate([Dict("after"=>case["initial"]);case["transitions"]])
                    if haskey(stage,"data")
                        NativeAuth.auth_selector_input!(menu,stage["data"])
                    end
                    actual=JSON.parse(JSON.json(auth_test_state(menu,callbacks)))
                    if actual!=stage["after"]["state"]
                        push!(failures,(id=case["id"],theme=case["theme"],width=case["width"],index,actual,expected=stage["after"]["state"]))
                    end
                    id=case["theme"]*"."*case["id"]*"."*string(index)
                    rows=NativeAuth.auth_selector_lines(menu,case["width"])
                    @test length(rows)==length(stage["after"]["terminalAnsiLines"])
                    buffer=auth_test_buffer(rows,case["width"])
                    mismatches=TerminalCellFixture.differences(buffer,cell_fixture,id,case["width"])
                    @test isempty(mismatches)
                    push!(frames,(id,width=case["width"],ansiLines=auth_test_ansi(rows),event=get(stage,"data","open")))
                    push!(expected,(id,width=case["width"],terminalAnsiLines=stage["after"]["terminalAnsiLines"],event=get(stage,"data","open")))
                    push!(buffer_frames,(id,width=case["width"],ansiLines=auth_test_buffer_ansi(rows,case["width"]),event=get(stage,"data","open")))
                end
                NativeAuth.auth_selector_dispose!(menu)
            end
            write(joinpath(evidence,"native.json"),JSON.json((snapshots=frames,)))
            write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected,)))
            write(joinpath(evidence,"states.json"),JSON.json((frames=length(frames),failures)))
            foreach(println,first(failures,min(3,length(failures))))
            @test isempty(failures)
            write(joinpath(evidence,"native-buffer.json"),JSON.json((snapshots=buffer_frames,)))
            comparator=joinpath(@__DIR__,"..","parity","compare_terminal_cells.mjs")
            reference_path,native_path,cells_path=(joinpath(evidence,name) for name in ("reference.json","native.json","cells.json"))
            if isdir(reference)
            run(pipeline(`node $comparator $reference_path $native_path $cells_path`;stdout=devnull))
            cells=JSON.parsefile(cells_path)
            println("Auth selector frames: ",cells["checked"]," matched: ",cells["matching"]," mismatched: ",cells["differing"])
            @test cells["matching"]==length(frames)
            @test isempty(cells["missingFrames"])
            native_path=joinpath(evidence,"native-buffer.json")
            cells_path=joinpath(evidence,"buffer-cells.json")
            write(native_path,JSON.json((snapshots=buffer_frames,)))
            run(pipeline(`node $comparator $reference_path $native_path $cells_path`;stdout=devnull))
            buffer_cells=JSON.parsefile(cells_path)
            println("Auth selector actual buffer frames: ",buffer_cells["matching"],"/",length(buffer_frames))
            @test buffer_cells["matching"]==length(buffer_frames)
            end
            @test length(buffer_frames)==700
        end
    end
end

@testset "Native authentication callbacks are requests, not grants" begin
    style=Returns(Tachikoma.Style())
    requests=[];cancelled=Ref(0)
    supported=NativeAuth.AuthProviderOption(;id="actual-provider",name="Actual provider",kind=:oauth)
    menu=NativeAuth.AuthProviderMenu([supported];style,on_select=option->push!(requests,option),on_cancel=()->(cancelled[]+=1))
    NativeAuth.auth_selector_input!(menu,"\r")
    @test only(requests)===supported
    @test isnothing(only(menu.options).status)
    @test !occursin("✓",join(join(span.content for span in row) for row in NativeAuth.auth_selector_lines(menu,100)))
    NativeAuth.auth_selector_replace!(menu,NativeAuth.AuthProviderOption[])
    NativeAuth.auth_selector_input!(menu,"\r")
    @test length(requests)==1
    NativeAuth.auth_selector_input!(menu,"\e")
    @test cancelled[]==1
    NativeAuth.auth_selector_dispose!(menu)
    NativeAuth.auth_selector_input!(menu,"\e")
    NativeAuth.auth_selector_replace!(menu,[supported])
    @test cancelled[]==1
    @test isempty(menu.options)
end
