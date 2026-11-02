using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const KeyLife=JuliaForever2
const KeyLifeHost=Base.get_extension(KeyLife,:JuliaForever2TerminalExt)
function api_key_host_drain!(app)
    timedwait(15;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
function api_key_host_fixture(action;denied=false)
    mktempdir() do directory
        entered=Channel{Nothing}(1);release=Channel{Nothing}(1);calls=[]
        transport=(url,method,body,headers,context,sink)->begin
            push!(calls,(url,method,body,headers))
            if method=="GET"
                put!(entered,nothing);take!(release)
                (status=denied ? 401 : 200,body=JSON.json(Dict("data"=>[Dict("id"=>"fixture-model")])),reason="")
            else
                write(sink,"data: "*JSON.json(Dict("choices"=>[Dict("delta"=>Dict("content"=>"fixture reply"),"finish_reason"=>"stop")]))*"\n\n")
                write(sink,"data: [DONE]\n\n")
                (status=200,body="",reason="")
            end
        end
        models=[KeyLife.ModelSpec(:fixture,"fixture-model";api="openai-completions")]
        descriptor=KeyLife.api_key_provider_descriptor(:fixture,"Fixture provider";models,
            endpoint="https://fixture.invalid/v1",models_url="https://fixture.invalid/v1/models",transport)
        registry=KeyLife.ProviderRegistry()
        KeyLife.register_provider!(registry,KeyLife.demo_provider_descriptor())
        KeyLife.register_provider!(registry,descriptor)
        app=KeyLifeHost.App(;settings_dir=directory,registry)
        previous=KeyLife.component(app.session.kernel,:provider)
        before=deepcopy(app.transcript.lines)
        KeyLifeHost.dispatch!(app,"/login fixture")
        flow=app.settings.auth_flow
        @test flow isa KeyLife.AuthFlow
        @test timedwait(()->KeyLife.api_key_request_status(descriptor.auth,flow).available || istaskdone(app.settings.auth_task),15)==:ok
        @test KeyLife.api_key_request_status(descriptor.auth,flow).available
        action((;app,flow,descriptor,registry,directory,previous,before,entered,release,calls))
        KeyLifeHost.finish_shutdown!(app)
        close(app.session.kernel)
    end
end
function submit_synthetic_key!(fixture)
    app=fixture.app
    KeyLifeHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:char,'x'),Vector{UInt8}(codeunits("SYNTHETIC_PRIVATE_KEY")))
    KeyLifeHost.page_input!(app,Val(:auth),Tachikoma.KeyEvent(:enter))
    @test timedwait(()->isready(fixture.entered)||istaskdone(app.settings.auth_task),15)==:ok
    @test isready(fixture.entered)
    take!(fixture.entered)
    @test app.busy && app.page==:auth
    @test app.status=="API key received; validating…"
    @test !isfile(joinpath(fixture.directory,"fixture.json"))
end
@testset "Actual host validates, persists, reuses lazily, and logs out without changing the current model at login" begin
    api_key_host_fixture() do f
        submit_synthetic_key!(f)
        put!(f.release,nothing)
        @test api_key_host_drain!(f.app)==:ok
        @test f.app.page==:chat && !f.app.busy
        @test occursin("validated and saved",f.app.status)
        @test KeyLife.component(f.app.session.kernel,:provider)===f.previous
        @test f.app.transcript.lines==f.before
        @test :fixture in KeyLifeHost.configured_model_providers(f.app)
        @test only(filter(option->option.id=="fixture",KeyLifeHost.auth_menu_options(f.app,:login))).status.kind==:api_key
        @test length(f.calls)==1 && only(f.calls)[2]=="GET"
        @test isfile(joinpath(f.directory,"fixture.json"))
        provider=KeyLife.provider_from_name(:fixture;dir=f.directory,registry=f.registry,model="fixture-model")
        request=KeyLife.ModelRequest([Message(:user,"harmless fixture")],"",nothing,nothing,nothing)
        context=KeyLife.ExecutionContext()
        result=KeyLife.respond(provider,request,context)
        @test KeyLife.response_reply(result)==Reply(:answer,"fixture reply")
        @test length(f.calls)==2 && last(f.calls)[1]=="https://fixture.invalid/v1/chat/completions"
        @test ("Authorization"=>"Bearer SYNTHETIC_PRIVATE_KEY") in last(f.calls)[4]
        @test !occursin("SYNTHETIC_PRIVATE_KEY",repr(provider))
        KeyLife.install!(f.app.session.kernel,KeyLife.ComponentSpec(:provider,provider))
        KeyLifeHost.open_menu!(f.app,"logout")
        KeyLifeHost.start_logout!(f.app,"fixture")
        @test api_key_host_drain!(f.app)==:ok
        @test !isfile(joinpath(f.directory,"fixture.json"))
        @test occursin("Stored credentials removed",f.app.status)
        @test !(:fixture in KeyLifeHost.configured_model_providers(f.app))
        @test_throws ErrorException KeyLife.respond(provider,request,context)
        @test length(f.calls)==2
        close(context)
    end
end
@testset "Actual host cancellation, stale provider, stale menu, and credential competition never save a key" begin
    for scenario in (:cancel,:provider,:generation,:credential)
        api_key_host_fixture() do f
            submit_synthetic_key!(f)
            if scenario==:cancel
                KeyLifeHost.page_input!(f.app,Val(:auth),Tachikoma.KeyEvent(:escape))
            elseif scenario==:provider
                KeyLife.register_provider!(f.registry,KeyLife.ProviderDescriptor(:fixture,"replacement",dir->KeyLife.DemoProvider()))
            elseif scenario==:generation
                f.app.menus.generation+=UInt(1)
            else
                KeyLife.save_credentials!(f.directory,:fixture,Dict("key"=>"different-owner"))
            end
            put!(f.release,nothing)
            @test api_key_host_drain!(f.app)==:ok
            @test !occursin("validated and saved",f.app.status)
            if scenario==:credential
                @test KeyLife.load_credentials(f.directory,:fixture)["key"]=="different-owner"
            else
                @test !isfile(joinpath(f.directory,"fixture.json"))
            end
            @test f.app.transcript.lines==f.before
            @test KeyLife.component(f.app.session.kernel,:provider)===f.previous
        end
    end
end
@testset "Denied metadata validation and canceled empty prompt remain truthful" begin
    api_key_host_fixture(;denied=true) do f
        submit_synthetic_key!(f)
        put!(f.release,nothing)
        @test api_key_host_drain!(f.app)==:ok
        @test occursin("rejected",f.app.status)
        @test !isfile(joinpath(f.directory,"fixture.json"))
    end
    api_key_host_fixture() do f
        KeyLifeHost.page_input!(f.app,Val(:auth),Tachikoma.KeyEvent(:escape))
        @test api_key_host_drain!(f.app)==:ok
        @test isempty(f.calls)
        @test !isfile(joinpath(f.directory,"fixture.json"))
        @test f.app.page==:chat
    end
end
