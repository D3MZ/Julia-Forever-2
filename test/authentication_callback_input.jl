using Test,JuliaForever2,Tachikoma,CommonMark,JSON
isdefined(Main,:AuthHost) || include("authentication_menu_controls.jl")
const CallbackNative=AuthHost
callback_text(input)=String(copy(view(input.bytes,1:input.used)))
callback_render(input,width=60)=join(join(span.content for span in row) for row in CallbackNative.auth_callback_lines(input,width))

@testset "Private callback input masks, bounds, edits and clears synthetic URLs" begin
    secret="http://127.0.0.1:1455/auth/callback?code=synthetic-code&state=synthetic-state&client_id=synthetic-client"
    input=CallbackNative.AuthCallbackInput()
    @test CallbackNative.auth_callback_input!(input,secret)==:handled
    @test callback_text(input)==secret
    @test !occursin("synthetic",callback_render(input))
    @test !occursin("127.0.0.1",callback_render(input))
    @test !occursin("synthetic",repr(input))
    @test !occursin("synthetic",repr(MIME"text/plain"(),input))
    @test length(input.bytes)==8192
    CallbackNative.auth_callback_input!(input,"\x01")
    CallbackNative.auth_callback_input!(input,"x")
    CallbackNative.auth_callback_input!(input,"\x04")
    @test startswith(callback_text(input),"xttp")
    CallbackNative.auth_callback_input!(input,"\x15")
    @test startswith(callback_text(input),"ttp")
    CallbackNative.auth_callback_input!(input,"\x05")
    CallbackNative.auth_callback_input!(input,"\x7f")
    @test endswith(callback_text(input),"synthetic-clien")
    CallbackNative.auth_callback_input!(input,"\x01")
    CallbackNative.auth_callback_input!(input,"\x0b")
    @test input.used==0 && all(iszero,input.bytes)
    CallbackNative.auth_callback_input!(input,repeat("x",8192))
    @test input.used==8192
    CallbackNative.auth_callback_input!(input,"x")
    @test input.warning==:too_long && input.used==0 && all(iszero,input.bytes)
    CallbackNative.auth_callback_input!(input,secret)
    @test CallbackNative.auth_callback_input!(input,"\e")==:cancel
    @test input.used==0 && all(iszero,input.bytes)
    CallbackNative.auth_callback_dispose!(input)
    CallbackNative.auth_callback_input!(input,secret)
    @test input.used==0
end

@testset "Bracketed paste cannot submit, execute controls or grow beyond the bound" begin
    input=CallbackNative.AuthCallbackInput()
    CallbackNative.auth_callback_input!(input,"\e[200~http://synthetic.invalid/callback?code=synthetic")
    @test input.pasting
    @test CallbackNative.auth_callback_input!(input,"\e[20")==:handled
    @test input.pasting
    @test CallbackNative.auth_callback_input!(input,"1~\r")==:handled
    @test !input.pasting && input.used>0
    @test CallbackNative.auth_callback_input!(input,"\r")==:submit
    CallbackNative.auth_callback_clear!(input)
    @test CallbackNative.auth_callback_input!(input,"\e[200~synthetic\r\x03\e[201~")==:handled
    @test input.used==0 && all(iszero,input.bytes) && input.warning==:unsafe_input
    CallbackNative.auth_callback_input!(input,"\e[200~"*repeat("x",9000))
    @test input.used==0 && all(iszero,input.bytes) && input.warning==:too_long
    CallbackNative.auth_callback_input!(input,"\e[201~\r")
    @test !input.pasting && input.used==0
    CallbackNative.auth_callback_input!(input,"世界")
    @test input.warning==:unsafe_input && input.used==0
end

@testset "Callback receipt is not login success and received intake cannot be repeated" begin
    input=CallbackNative.AuthCallbackInput()
    calls=String[]
    submit=value->begin
        push!(calls,value)
        (ok=true,reason="ignored server text")
    end
    CallbackNative.auth_callback_input!(input,"synthetic-callback")
    @test CallbackNative.auth_callback_submit!(input,submit)==(ok=true,reason=:received)
    @test calls==["synthetic-callback"]
    @test all(iszero,input.bytes) && input.used==0
    @test input.received
    @test occursin("verifying sign-in",callback_render(input))
    @test !occursin("signed in",lowercase(callback_render(input)))
    CallbackNative.auth_callback_input!(input,"synthetic-replay")
    @test !CallbackNative.auth_callback_submit!(input,submit).ok
    @test length(calls)==1
    @test CallbackNative.auth_callback_input!(input,"\e")==:cancel
    rejected=CallbackNative.AuthCallbackInput()
    CallbackNative.auth_callback_input!(rejected,"synthetic-reject")
    @test !CallbackNative.auth_callback_submit!(rejected,Returns((ok=false,reason="do not display synthetic-secret"))).ok
    @test all(iszero,rejected.bytes) && rejected.warning==:rejected
    @test !occursin("synthetic-secret",callback_render(rejected))
end

@testset "Real host callback route preserves transcript and waits for verified completion" begin
    mktempdir() do directory
        app=AuthHost.Owner.App(;settings_dir=directory)
        received=String[]
        available=Ref(true)
        starter=(app,id;action)->begin
            app.settings.auth_flow=JuliaForever2.AuthFlow()
            app.page=:auth
            app.busy=true
            nothing
        end
        submit=(flow,value)->begin
            push!(received,value)
            available[]=false
            (ok=true,reason="synthetic service accepted intake only")
        end
        control=AuthHost.auth_menu_open!(app,"login";on_login=starter,on_manual_available=flow->available[],on_manual_submit=submit)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test AuthHost.auth_menu_manual_active(app,control)
        before_input=app.input
        before_value=copy(app.input.buffer)
        before_cursor=app.input.cursor
        before_transcript=deepcopy(app.transcript.lines)
        packet=Vector{UInt8}(codeunits("\e[200~synthetic-callback\e[201~"))
        @test AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:char,'x'),packet)
        @test isempty(received)
        @test !occursin("synthetic-callback",repr(control))
        @test !occursin("synthetic-callback",join(join(span.content for span in row) for row in AuthHost.auth_menu_manual_lines(app,control,50)))
        @test !isnothing(AuthHost.auth_menu_manual_cursor(control))
        @test AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test received==["synthetic-callback"]
        @test app.input===before_input
        @test app.input.buffer==before_value && app.input.cursor==before_cursor
        @test app.transcript.lines==before_transcript
        @test app.page==:auth && app.busy
        @test app.status=="Callback received; verifying sign-in…"
        @test !isfile(joinpath(directory,"chatgpt.json"))
        @test all(iszero,control.callback_input.bytes)
        @test isnothing(AuthHost.auth_menu_manual_cursor(control))
        AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test length(received)==1
        flow=control.flow
        app.busy=false
        app.settings.auth_flow=nothing
        AuthHost.auth_menu_finish!(app,control,flow;ok=false)
        @test app.page==:pi_menu && control.stage==:providers
        @test control.callback_input.disposed
        @test !AuthHost.auth_menu_manual_active(app,control)
        close(flow)
        close(app.session)
    end
end

@testset "Callback expiry, stale navigation and cancellation wipe private input" begin
    mktempdir() do directory
        app=AuthHost.Owner.App(;settings_dir=directory)
        starter=(app,id;action)->begin
            app.settings.auth_flow=JuliaForever2.AuthFlow()
            app.page=:auth
            app.busy=true
            nothing
        end
        available=Ref(true)
        calls=Ref(0)
        submit=(flow,value)->begin
            calls[]+=1
            (ok=true,reason="synthetic receipt")
        end
        control=AuthHost.auth_menu_open!(app,"login";on_login=starter,on_manual_available=flow->available[],on_manual_submit=submit)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        packet=Vector{UInt8}(codeunits("synthetic-private-input"))
        AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:char,'x'),packet)
        available[]=false
        @test !AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test calls[]==0 && all(iszero,control.callback_input.bytes)
        available[]=true
        AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:char,'x'),packet)
        app.menus.generation+=UInt(1)
        @test !AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test calls[]==0 && all(iszero,control.callback_input.bytes)
        app.menus.generation-=UInt(1)
        AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:char,'x'),packet)
        @test AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:escape))
        @test all(iszero,control.callback_input.bytes) && control.callback_input.disposed
        @test !JuliaForever2.active_auth(control.flow)
        @test !AuthHost.auth_menu_manual_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test app.page==:auth && app.busy
        @test calls[]==0
        close(control.flow)
        close(app.session)
    end
end
