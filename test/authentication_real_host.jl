using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const RealAuthHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)

function real_auth_fixture(action)
    mktempdir() do directory
        registry=JuliaForever2.ProviderRegistry()
        JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(:chatgpt,"Synthetic ChatGPT",dir->JuliaForever2.DemoProvider();auth=Returns(nothing)))
        app=RealAuthHost.App(;settings_dir=directory,registry)
        received=String[]
        starter=(app,id;action)->begin
            app.settings.auth_flow=JuliaForever2.AuthFlow()
            app.settings.auth_provider=id
            app.page=:auth
            app.busy=true
            nothing
        end
        submit=(flow,value)->begin
            push!(received,value)
            (ok=true,reason="Synthetic callback receipt, not a grant")
        end
        control=RealAuthHost.auth_menu_open!(app,"login";on_login=starter,on_manual_available=Returns(true),on_manual_submit=submit)
        app.menus.auth_menu_control=control
        RealAuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        RealAuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        action(app,control,received)
        close(control.flow)
        close(app.session)
    end
end

@testset "Actual terminal namespace privately handles callback backspace" begin
    real_auth_fixture() do app,control,received
        before=deepcopy(app.transcript.lines)
        RealAuthHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits("synthetic-valueX")))
        @test control.callback_input.used==16
        RealAuthHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:backspace))
        @test control.callback_input.used==15
        @test control.callback_input.bytes[16]==0
        @test isempty(received)
        @test app.transcript.lines==before
        @test !occursin("synthetic-value",repr(control))
    end
end

@testset "Actual terminal namespace privately submits callback receipt only" begin
    real_auth_fixture() do app,control,received
        before=deepcopy(app.transcript.lines)
        RealAuthHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits("synthetic-value")))
        RealAuthHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:enter))
        @test received==["synthetic-value"]
        @test control.callback_input.received
        @test all(iszero,control.callback_input.bytes)
        @test control.callback_input.used==0
        @test app.page==:auth && app.busy
        @test app.transcript.lines==before
        @test app.status=="Callback received; verifying sign-in…"
        @test !isfile(joinpath(app.settings.directory,"chatgpt.json"))
    end
end

@testset "Actual auth owner tolerates disposed selector and absent provider safely" begin
    real_auth_fixture() do app,control,received
        control.selector=nothing
        control.stage=:providers
        app.page=:pi_menu
        @test isnothing(RealAuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter)))
        @test isempty(RealAuthHost.auth_menu_lines(app,control,80))
        app.page=:auth
        control.stage=:auth
        app.settings.auth_provider=:removed_provider
        frame=RealAuthHost.auth_dialog_layout(app,control,80)
        text=join(join(span.content for span in line) for line in frame.lines)
        @test occursin("Login to removed_provider",text)
        @test isempty(received)
        app.menus.auth_menu_control=nothing
        @test RealAuthHost.auth_dialog_input!(app,nothing,Tachikoma.KeyEvent(:backspace))
        @test isempty(received)
        @test !isempty(RealAuthHost.auth_dialog_layout(app,nothing,80).lines)
    end
end
