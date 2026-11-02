using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const BuiltinKeyUIHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
isdefined(@__MODULE__,:BuiltinKeyUIFixture) || include("differential/builtin_key_ui_fixture.jl")
function builtin_key_buffer(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
    BuiltinKeyUIHost.draw_menu_lines!(buffer,1,1,width,lines)
    buffer
end
function builtin_key_buffer_ansi(buffer,width,rows)
    [sprint() do io
        for column in 1:width
            cell=buffer.content[(row-1)*width+column]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style)
                print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for row in 1:rows]
end
@testset "Actual App private key dialog follows original source transitions without revealing input" begin
    mktempdir() do temporary
        evidence=get(ENV,"BUILTIN_KEY_UI_EVIDENCE",temporary);mkpath(evidence)
        original,cells=BuiltinKeyUIFixture.load(get(ENV,"PI_REFERENCE",""),joinpath(evidence,"source-original.json"))
        native=[];projected=[];states=[];rawmatches=0
        for case in original["cases"]
            mktempdir() do directory
                release=Channel{Nothing}(1)
                validator=(id,key,context)->begin
                    take!(release)
                    JuliaForever2.APIKeyValidation(;ok=true,model_ids=["fixture-model"])
                end
                method=JuliaForever2.APIKeyAuthMethod(;provider=Symbol(case["provider"]),name=case["keyName"],validate=validator)
                registry=JuliaForever2.ProviderRegistry()
                JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(Symbol(case["provider"]),case["name"],dir->JuliaForever2.DemoProvider();auth=method))
                app=BuiltinKeyUIHost.App(;settings_dir=directory,registry)
                catalog=BuiltinKeyUIHost.theme_catalog("";preserve_extras=false)
                catalog.bold=true
                app.menus.theme_runtime=BuiltinKeyUIHost.ThemeRuntime(catalog;setting=case["theme"])
                control=BuiltinKeyUIHost.auth_menu_open!(app,"login")
                app.menus.auth_menu_control=control
                flow=JuliaForever2.AuthFlow(;timeout=120)
                app.settings.auth_flow=flow;app.settings.auth_provider=Symbol(case["provider"]);app.busy=true;app.page=:auth
                control.key_method=method;control.flow=flow;control.stage=:auth
                task=nothing
                transcript=deepcopy(app.transcript.lines)
                for (index,stage) in enumerate([Dict("op"=>"open","after"=>case["initial"]);case["transitions"]])
                    op=stage["op"]
                    if op=="prompt"
                        ready=Channel{Nothing}(1)
                        task=@async method(flow,Symbol(case["provider"]),directory;notify=()->put!(ready,nothing))
                        timedwait(()->isready(ready)||istaskdone(task),10)==:ok && isready(ready) || error("Key prompt not ready")
                        take!(ready)
                    elseif op=="input"
                        BuiltinKeyUIHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits(stage["data"])))
                    end
                    frame=BuiltinKeyUIHost.auth_dialog_layout(app,control,case["width"])
                    id=case["theme"]*"."*case["id"]*"."*string(index)
                    buffer=builtin_key_buffer(frame.lines,case["width"])
                    @test length(frame.lines)==length(stage["after"]["privacyProjectedAnsiLines"])
                    @test isempty(TerminalCellFixture.differences(buffer,cells,id*".private",case["width"]))
                    rawmatches+=isempty(TerminalCellFixture.differences(buffer,cells,id,case["width"]))
                    cursor=stage["after"]["cursor"]
                    @test frame.cursor==(isnothing(cursor) ? nothing : (x=cursor["col"],y=cursor["row"]))
                    @test control.callback_input.received==any(event->event["kind"]=="intake",stage["after"]["state"]["callbacks"])
                    @test app.transcript.lines==transcript
                    text=join(join(span.content for span in line) for line in frame.lines)
                    @test !occursin("SYNTHETIC",text)
                    @test !isfile(joinpath(directory,case["provider"]*".json"))
                    push!(native,(id,width=case["width"],ansiLines=builtin_key_buffer_ansi(buffer,case["width"],length(frame.lines)),event=op))
                    push!(projected,(id,width=case["width"],terminalAnsiLines=stage["after"]["privacyProjectedAnsiLines"],event=op))
                    push!(states,(id,width=case["width"],cursor=frame.cursor,received=control.callback_input.received,status=app.status))
                end
                put!(release,nothing)
                @test fetch(task).ok
                @test isfile(joinpath(directory,case["provider"]*".json"))
                close(flow);close(app.session)
            end
        end
        write(joinpath(evidence,"native-buffer.json"),JSON.json((snapshots=native,)))
        write(joinpath(evidence,"privacy-projected-reference.json"),JSON.json((snapshots=projected,)))
        write(joinpath(evidence,"states.json"),JSON.json(states))
        @test length(native)==48
        @test rawmatches==16
    end
end
