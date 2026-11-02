using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const KeyHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Real key method appears in the actual native login menu" begin
    mktempdir() do directory
        validator=(provider,key,context)->JuliaForever2.APIKeyValidation(;ok=true,model_ids=["fixture-model"])
        method=JuliaForever2.APIKeyAuthMethod(;provider=:fixture,name="Fixture API key",validate=validator)
        registry=JuliaForever2.ProviderRegistry()
        JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(:fixture,"Fixture provider",dir->JuliaForever2.DemoProvider();auth=method))
        app=KeyHost.App(;settings_dir=directory,registry)
        control=KeyHost.auth_menu_open!(app,"login")
        app.menus.auth_menu_control=control
        options=KeyHost.auth_menu_options(app,:login)
        original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-api-key-original.json"))
        source_kind=Symbol(only(original["cases"][1]["transitions"][end]["after"]["state"]["callbacks"])["value"]["type"])
        @test only(options).kind==source_kind
        @test occursin("Sign in with an API key",join(join(span.content for span in row) for row in KeyHost.auth_menu_lines(app,control,80)))
        close(app.session)
    end
end
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
isdefined(@__MODULE__,:APIKeyFixture) || include("differential/api_key_fixture.jl")
function key_buffer(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
    KeyHost.draw_menu_lines!(buffer,1,1,width,lines)
    buffer
end
function key_buffer_ansi(buffer,width,rows)
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
        evidence=get(ENV,"API_KEY_EVIDENCE",temporary);mkpath(evidence)
        original,cells=APIKeyFixture.load(get(ENV,"PI_REFERENCE",""),joinpath(evidence,"source-original.json"))
        native=[];projected=[];states=[];rawmatches=0
        for case in original["cases"]
            mktempdir() do directory
                release=Channel{Nothing}(1)
                validator=(id,key,context)->begin
                    take!(release)
                    JuliaForever2.APIKeyValidation(;ok=true,model_ids=["fixture-model"])
                end
                method=JuliaForever2.APIKeyAuthMethod(;provider=:fixture,name="Fixture API key",validate=validator)
                registry=JuliaForever2.ProviderRegistry()
                JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(:fixture,"Fixture provider",dir->JuliaForever2.DemoProvider();auth=method))
                app=KeyHost.App(;settings_dir=directory,registry)
                catalog=KeyHost.theme_catalog("";preserve_extras=false)
                catalog.bold=true
                app.menus.theme_runtime=KeyHost.ThemeRuntime(catalog;setting=case["theme"])
                control=KeyHost.auth_menu_open!(app,"login")
                app.menus.auth_menu_control=control
                flow=JuliaForever2.AuthFlow(;timeout=120)
                app.settings.auth_flow=flow;app.settings.auth_provider=:fixture;app.busy=true;app.page=:auth
                control.key_method=method;control.flow=flow;control.stage=:auth
                task=nothing
                transcript=deepcopy(app.transcript.lines)
                for (index,stage) in enumerate([Dict("op"=>"open","after"=>case["initial"]);case["transitions"]])
                    op=stage["op"]
                    if op=="prompt"
                        ready=Channel{Nothing}(1)
                        task=@async method(flow,:fixture,directory;notify=()->put!(ready,nothing))
                        timedwait(()->isready(ready)||istaskdone(task),10)==:ok && isready(ready) || error("Key prompt not ready")
                        take!(ready)
                    elseif op=="input"
                        KeyHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits(stage["data"])))
                    end
                    frame=KeyHost.auth_dialog_layout(app,control,case["width"])
                    id=case["theme"]*"."*case["id"]*"."*string(index)
                    buffer=key_buffer(frame.lines,case["width"])
                    @test length(frame.lines)==length(stage["after"]["privacyProjectedAnsiLines"])
                    @test isempty(TerminalCellFixture.differences(buffer,cells,id*".private",case["width"]))
                    rawmatches+=isempty(TerminalCellFixture.differences(buffer,cells,id,case["width"]))
                    cursor=stage["after"]["cursor"]
                    @test frame.cursor==(isnothing(cursor) ? nothing : (x=cursor["col"],y=cursor["row"]))
                    @test control.callback_input.received==any(event->event["kind"]=="intake",stage["after"]["state"]["callbacks"])
                    @test app.transcript.lines==transcript
                    text=join(join(span.content for span in line) for line in frame.lines)
                    @test !occursin("SYNTHETIC",text)
                    @test !isfile(joinpath(directory,"fixture.json"))
                    push!(native,(id,width=case["width"],ansiLines=key_buffer_ansi(buffer,case["width"],length(frame.lines)),event=op))
                    push!(projected,(id,width=case["width"],terminalAnsiLines=stage["after"]["privacyProjectedAnsiLines"],event=op))
                    push!(states,(id,width=case["width"],cursor=frame.cursor,received=control.callback_input.received,status=app.status))
                end
                put!(release,nothing)
                @test fetch(task).ok
                @test isfile(joinpath(directory,"fixture.json"))
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
