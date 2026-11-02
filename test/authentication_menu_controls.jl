using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module AuthHostNativeTests
using JuliaForever2,Tachikoma,CommonMark,JSON
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const MenuSearchInput=Owner.MenuSearchInput
const menu_search_set! = Owner.menu_search_set!
const menu_search_input! = Owner.menu_search_input!
const menu_search_spans=Owner.menu_search_spans
const menu_search_prefix=Owner.menu_search_prefix
const menu_search_width=Owner.menu_search_width
const menu_search_slice=Owner.menu_search_slice
const selector_filter=Owner.selector_filter
const model_menu_wrap=Owner.model_menu_wrap
const provider_descriptors=JuliaForever2.provider_descriptors
const provider_descriptor=JuliaForever2.provider_descriptor
const theme_style=Owner.theme_style
const menu_packet=Owner.menu_packet
const start_sign_in! = Owner.start_sign_in!
const start_logout! = Owner.start_logout!
const open_logout_controls! = Owner.open_logout_controls!
const cancel_auth! = JuliaForever2.cancel_auth!
include(joinpath(@__DIR__,"..","ext","terminal","authentication_selectors.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","authentication_callback_input.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","authentication_menu_controls.jl"))
end
const AuthHost=AuthHostNativeTests

@testset "Native authentication menus own real host navigation without grants" begin
    mktempdir() do directory
        app=AuthHost.Owner.App(;settings_dir=directory)
        log=[]
        function login(app,id;action)
            push!(log,(id,action))
            app.settings.auth_flow=JuliaForever2.AuthFlow()
            app.busy=true
            app.page=:auth
            nothing
        end
        control=AuthHost.auth_menu_open!(app,"login";on_login=login)
        @test AuthHost.auth_menu_active(app,control)
        @test [item.label for item in control.selector.options]==["Sign in with an account","Sign in with an API key","Provider-specific sign in"]
        @test isempty(log)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test control.stage==:providers
        @test [item.id for item in control.selector.options]==["chatgpt","openrouter"]
        @test all(item->item.kind==:oauth,control.selector.options)
        @test !last(control.selector.options).subscription
        @test AuthHost.auth_menu_cursor(control)==(x=2,y=4)
        @test !isempty(AuthHost.auth_menu_lines(app,control,60))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:escape))
        @test control.stage==:methods
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test only(log)[1]==:chatgpt
        @test only(log)[2]===JuliaForever2.provider_descriptor(app.settings.registry,:chatgpt).auth
        @test app.page==:auth && app.busy && control.stage==:auth
        flow=control.flow
        @test AuthHost.auth_menu_cancel_auth!(app,control)
        @test !JuliaForever2.active_auth(flow)
        app.settings.auth_flow=nothing
        app.busy=false
        app.status="Sign-in cancelled."
        AuthHost.auth_menu_finish!(app,control,flow;ok=false)
        @test app.page==:pi_menu && control.stage==:providers
        @test app.status=="Sign-in cancelled."
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:escape))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:escape))
        @test app.page==:chat && !control.active
        @test !isfile(joinpath(directory,"chatgpt.json"))
        close(flow)
        close(app.session)
    end
end

@testset "Auth selection preserves native extras and rejects stale ownership" begin
    mktempdir() do directory
        app=AuthHost.Owner.App(;settings_dir=directory)
        called=Ref(false)
        control=AuthHost.auth_menu_open!(app,"login";on_login=(app,id;action)->(called[]=true))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:down))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:down))
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test [option.id for option in control.selector.options]==["codex"]
        @test only(control.selector.options).method_name=="Sign in using the Codex CLI"
        app.menus.generation+=UInt(1)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test !called[]
        @test !AuthHost.auth_menu_active(app,control)
        AuthHost.auth_menu_dispose!(control)
        close(app.session)
    end
end

@testset "Logout menu uses actual stored revisions and never removes environment credentials" begin
    mktempdir() do directory
        app=AuthHost.Owner.App(;settings_dir=directory)
        JuliaForever2.save_credentials!(directory,:chatgpt,Dict("fixture"=>"not a credential"))
        requests=String[]
        logout=(app,id)->begin
            push!(requests,id)
            app.busy=true
            nothing
        end
        control=AuthHost.auth_menu_open!(app,"logout";on_logout=logout)
        @test haskey(app.menus.logout_revisions,"chatgpt")
        @test [item.id for item in control.selector.options]==["chatgpt"]
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test requests==["chatgpt"]
        @test control.stage==:removing && app.busy && app.page==:chat
        @test isfile(joinpath(directory,"chatgpt.json"))
        app.busy=false
        app.status="Fixture callback finished; no real credentials removed."
        AuthHost.auth_menu_logout_finish!(app,control)
        @test app.page==:chat && !control.active
        @test isfile(joinpath(directory,"chatgpt.json"))
        close(app.session)
    end
end

@testset "Auth host fails closed for unsafe storage and changed providers" begin
    mktempdir() do directory
        registry=JuliaForever2.ProviderRegistry(;descriptors=JuliaForever2.provider_descriptors())
        app=AuthHost.Owner.App(;settings_dir=directory,registry)
        calls=Ref(0)
        starter=(app,id;action)->begin
            calls[]+=1
            app.settings.auth_flow=JuliaForever2.AuthFlow()
            app.page=:auth
            app.busy=true
            nothing
        end
        control=AuthHost.auth_menu_open!(app,"login";on_login=starter)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        app.busy=true
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test calls[]==0
        @test control.stage==:providers
        app.busy=false
        JuliaForever2.unregister_provider!(registry,:chatgpt)
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test calls[]==0
        @test [option.id for option in control.selector.options]==["openrouter"]
        AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
        @test calls[]==1
        flow=control.flow
        app.busy=false
        app.settings.auth_flow=nothing
        AuthHost.auth_menu_finish!(app,control,flow;ok=true)
        @test app.page==:chat && !control.active
        close(flow)
        # An untrusted symlink cannot become an apparent unconfigured/overwriteable provider row.
        write(joinpath(directory,"fixture.json"),"{}")
        symlink(joinpath(directory,"fixture.json"),joinpath(directory,"openrouter.json"))
        second=AuthHost.auth_menu_open!(app,"login";on_login=starter)
        @test !any(option->option.id=="oauth",second.selector.options)
        @test occursin("unsafe or unavailable",app.status)
        @test calls[]==1
        AuthHost.auth_menu_dispose!(second)
        close(app.session)
    end
end
