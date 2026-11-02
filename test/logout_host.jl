using Test,JuliaForever2,Tachikoma,CommonMark
module LogoutHostTests
using Test,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JF,:JuliaForever2TerminalExt)
function fixture(;selected=:openrouter)
    directory=mktempdir()
    JF.save_credentials!(directory,:openrouter,Dict("key"=>"fixture-router"))
    JF.save_credentials!(directory,:chatgpt,Dict("access_token"=>"fixture-subscription"))
    calls=Ref(0);transport=(args...)->(calls[]+=1;error("No external calls in logout fixture"))
    router=JF.OpenRouterProvider("fixture-router","fixture-model",transport;reasoning="high")
    chat=JF.OpenAIProvider(directory,transport,transport;model="fixture-chat",reasoning="low")
    chat.catalog.models=["account-private-model"]
    registry=JF.ProviderRegistry()
    for (id,provider) in ((:openrouter,router),(:chatgpt,chat))
        JF.register_provider!(registry,JF.ProviderDescriptor(id,String(id),Returns(provider);auth=Returns(nothing)))
    end
    app=T.App(Session(JF.default_kernel(selected==:openrouter ? router : chat));settings_dir=directory,registry)
    (;app,directory,calls,router,chat)
end
function close_fixture(f)
    kernel=f.app.session.kernel;T.finish_shutdown!(f.app);close(kernel)
end
function drain!(app)
    timedwait(5;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
@testset "Real logout selection removes only its stored access and active cache" begin
    withenv("OPENROUTER_API_KEY"=>nothing) do
        f=fixture();app=f.app
        before=JF.timeline_entries(app.archive.timeline)
        T.open_menu!(app,"logout")
        @test Set(x["id"] for x in T.menu_page_items(app))==Set(["openrouter","chatgpt"])
        T.menu_select!(app,"openrouter")
        @test app.busy
        @test drain!(app)==:ok
        @test isnothing(JF.load_credentials(f.directory,:openrouter))
        @test !isnothing(JF.load_credentials(f.directory,:chatgpt))
        replacement=JF.component(app.session.kernel,:provider)
        @test isempty(replacement.api_key)
        @test replacement.model==f.router.model
        @test replacement.reasoning==f.router.reasoning
        @test replacement.transport===f.router.transport
        @test !(:openrouter in T.configured_model_providers(app))
        @test JF.timeline_entries(app.archive.timeline)==before
        @test app.page==:chat
        @test occursin("Stored credentials removed",app.status)
        @test f.calls[]==0
        close_fixture(f)
    end
end
@testset "Logout preserves environment fallback and resets subscription catalog" begin
    withenv("OPENROUTER_API_KEY"=>"fixture-environment") do
        f=fixture();T.open_menu!(f.app,"logout");T.menu_select!(f.app,"openrouter")
        @test drain!(f.app)==:ok
        @test JF.component(f.app.session.kernel,:provider).api_key=="fixture-environment"
        @test :openrouter in T.configured_model_providers(f.app)
        @test ENV["OPENROUTER_API_KEY"]=="fixture-environment"
        close_fixture(f)
    end
    f=fixture(;selected=:chatgpt);T.open_menu!(f.app,"logout");T.menu_select!(f.app,"chatgpt")
    @test drain!(f.app)==:ok
    replacement=JF.component(f.app.session.kernel,:provider)
    @test isempty(replacement.catalog.models)
    @test replacement.model==f.chat.model && replacement.reasoning==f.chat.reasoning
    @test !isnothing(JF.load_credentials(f.directory,:openrouter))
    @test isnothing(JF.load_credentials(f.directory,:chatgpt))
    @test f.calls[]==0
    close_fixture(f)
end
@testset "Cancel, stale credential selection, and busy state never delete" begin
    f=fixture();T.open_menu!(f.app,"logout")
    T.page_input!(f.app,Val(:pi_menu),KeyEvent(:escape))
    @test f.app.page==:chat
    @test !isnothing(JF.load_credentials(f.directory,:openrouter))
    T.open_menu!(f.app,"logout")
    JF.save_credentials!(f.directory,:openrouter,Dict("key"=>"fixture-rotated"))
    T.menu_select!(f.app,"openrouter")
    @test drain!(f.app)==:ok
    @test JF.load_credentials(f.directory,:openrouter)["key"]=="fixture-rotated"
    @test occursin("Credentials changed",f.app.status)
    T.open_menu!(f.app,"logout");f.app.busy=true
    T.menu_select!(f.app,"openrouter")
    @test !isnothing(JF.load_credentials(f.directory,:openrouter))
    f.app.busy=false
    @test f.calls[]==0
    close_fixture(f)
end
@testset "Unsafe storage and competing writes never falsely report logout" begin
    withenv("OPENROUTER_API_KEY"=>nothing) do
        f=fixture();path=joinpath(f.directory,"openrouter.json")
        rm(path);outside=joinpath(f.directory,"external.json");write(outside,"untouched")
        symlink(outside,path)
        T.open_menu!(f.app,"logout")
        @test !haskey(f.app.menus.logout_revisions,"openrouter")
        @test occursin("unsafe or unavailable",f.app.status)
        @test read(outside,String)=="untouched"
        close_fixture(f)
        f=fixture();T.open_menu!(f.app,"logout")
        claim=joinpath(f.directory,"openrouter.json.lock");mkdir(claim)
        T.menu_select!(f.app,"openrouter")
        @test drain!(f.app)==:ok
        @test !isnothing(JF.load_credentials(f.directory,:openrouter))
        @test isdir(claim)
        @test isempty(JF.component(f.app.session.kernel,:provider).api_key)
        @test !occursin("Stored credentials removed",f.app.status)
        @test f.calls[]==0
        rm(claim);close_fixture(f)
    end
end
end
