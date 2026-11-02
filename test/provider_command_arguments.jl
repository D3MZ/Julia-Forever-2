using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const ProviderCommandsHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function provider_command_fixture(action)
    mktempdir() do directory
        calls=Ref(0)
        transport=(args...)->(calls[]+=1;error("No external calls in command fixture"))
        backend=JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),"https://fixture.invalid";transport)
        models=[JuliaForever2.ModelSpec(:alpha,id;api="openai-completions",metadata=Dict("reasoning"=>true)) for id in ("old","new")]
        provider=JuliaForever2.ConfiguredModelProvider(JuliaForever2.ModelProvider(first(models),backend),first(models),"low")
        factory=JuliaForever2.ProviderFactory(Returns(provider);models=Returns(models),select=(dir,id)->JuliaForever2.ModelProvider(only(filter(m->m.id==id,models)),backend))
        registry=JuliaForever2.ProviderRegistry()
        JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(:alpha,"Alpha",factory))
        app=ProviderCommandsHost.App(Session(JuliaForever2.default_kernel(provider));settings_dir=directory,registry)
        action(app,calls)
        ProviderCommandsHost.finish_shutdown!(app)
        close(app.session.kernel)
    end
end
@testset "Actual slash model arguments select instead of opening empty menu" begin
    provider_command_fixture() do app,calls
        ProviderCommandsHost.dispatch!(app,"/model alpha/new")
        @test app.busy
        handle=app.operations.active
        if !isnothing(handle)
            wait(handle)
            ProviderCommandsHost.model_configuration_finished!(app,handle)
        end
        selected=JuliaForever2.component(app.session.kernel,:provider)
        @test JuliaForever2.provider_model_identity(selected).model_id=="new"
        @test !isfile(ProviderCommandsHost.model_settings_path(app))
        @test app.page==:chat
        @test calls[]==0
    end
end
@testset "Actual slash thinking arguments commit supported level without persisting default" begin
    provider_command_fixture() do app,calls
        ProviderCommandsHost.dispatch!(app,"/thinking HIGH")
        @test app.busy
        handle=app.operations.active
        if !isnothing(handle)
            wait(handle)
            ProviderCommandsHost.model_configuration_finished!(app,handle)
        end
        selected=JuliaForever2.component(app.session.kernel,:provider)
        @test JuliaForever2.current_thinking_level(selected)=="high"
        @test !isfile(ProviderCommandsHost.model_settings_path(app))
        @test app.page==:chat
        @test calls[]==0
    end
end

function command_original_fixture()
    fixture=joinpath(@__DIR__,"fixtures","pi-provider-commands-original.json")
    oracle=joinpath(@__DIR__,"differential","pi_provider_commands_oracle.mjs")
    provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
    original=JSON.parsefile(fixture)
    @test bytes2hex(sha256(read(fixture)))=="cf0744b8f9effd035c5ba25718a609b059efad5fb177de4bea2174746e6ddbcb"
    @test original["reference"]==JSON.parsefile(provenance)["reference"]
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test original["runnerSha256"]==bytes2hex(sha256(read(oracle)))
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    if !isempty(reference)
        mktempdir() do directory
            output=joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $output`)
            @test JSON.parsefile(output)==original
        end
    end
    original
end
command_spec(row)=JuliaForever2.ModelSpec(Symbol(row["provider"]),row["id"];api="openai-completions",metadata=Dict("reasoning"=>true,"thinkingLevelMap"=>Dict("minimal"=>nothing)))
function command_case_fixture(action,case)
    mktempdir() do directory
        calls=Ref(0)
        transport=(args...)->(calls[]+=1;error("No external model requests"))
        backend=JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),"https://fixture.invalid";transport)
        models=command_spec.(case["models"])
        registry=JuliaForever2.ProviderRegistry()
        for id in unique(model.provider for model in models)
            subset=filter(model->model.provider==id,models)
            factory=JuliaForever2.ProviderFactory(Returns(JuliaForever2.ModelProvider(first(subset),backend));models=Returns(subset),select=(dir,model)->JuliaForever2.ModelProvider(only(filter(m->m.id==model,subset)),backend))
            JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(id,String(id),factory))
        end
        current=JuliaForever2.ConfiguredModelProvider(JuliaForever2.ModelProvider(first(models),backend),first(models),"low")
        app=ProviderCommandsHost.App(Session(JuliaForever2.default_kernel(current));settings_dir=directory,registry)
        scoped=get(case,"scoped",[])
        app.menus.enabled_models=isempty(scoped) ? nothing : [row["provider"]*"/"*row["id"] for row in scoped]
        action(app,calls,backend)
        ProviderCommandsHost.finish_shutdown!(app)
        close(app.session.kernel)
    end
end
function command_drain!(app)
    pending=true
    while pending
        foreach(wait,copy(app.operations.watchers))
        while isready(app.queue.channel)
            ProviderCommandsHost.update!(app,take!(app.queue.channel))
        end
        pending=any(!istaskdone,app.operations.watchers) || isready(app.queue.channel)
    end
end
function command_fixture_refresh(case,backend,count)
    snapshot->begin
        count[]+=1
        fresh=command_spec.(get(case,"fresh",case["models"]))
        for original in snapshot.originals
            subset=filter(model->model.provider==original.id,fresh)
            factory=JuliaForever2.ProviderFactory(original.create.create;models=Returns(subset),select=(dir,id)->JuliaForever2.ModelProvider(only(filter(m->m.id==id,subset)),backend))
            JuliaForever2.register_provider!(snapshot.registry,JuliaForever2.ProviderDescriptor(original,factory))
        end
        (registry=snapshot.registry,originals=snapshot.originals,errors=String.(get(case,"errors",[])))
    end
end

@testset "Pinned original model command actions and refreshed/scoped exact resolver" begin
    original=command_original_fixture()
    for case in filter(case->case["kind"]=="model",original["cases"])
        command_case_fixture(case) do app,calls,backend
            before=deepcopy(app.menus.model_preferences)
            count=Ref(0)
            ProviderCommandsHost.model_command!(app,case["query"];refresh=command_fixture_refresh(case,backend,count))
            if case["refreshes"]>0
                @test app.status=="Refreshing model catalogs…"
                @test app.page==:chat
            end
            command_drain!(app)
            @test count[]==case["refreshes"]
            action=last(filter(a->a["kind"] in ("model","model-menu"),case["actions"]))
            if action["kind"]=="model"
                identity=JuliaForever2.provider_model_identity(JuliaForever2.component(app.session.kernel,:provider))
                @test String(identity.provider_id)==action["provider"]
                @test identity.model_id==action["id"]
                @test app.page==:chat
            else
                @test app.page==:pi_menu
                @test app.menus.path==["model"]
                @test app.menus.model_menu.search.value==action["query"]
            end
            @test app.menus.model_preferences==before
            @test !isfile(ProviderCommandsHost.model_settings_path(app))
            @test calls[]==0
        end
    end
end

@testset "Original thinking arguments validate actual supported levels" begin
    original=command_original_fixture()
    for case in filter(case->case["kind"]=="thinking",original["cases"])
        input=Dict("models"=>[Dict("provider"=>"alpha","id"=>"old")])
        command_case_fixture(input) do app,calls,backend
            ProviderCommandsHost.thinking_command!(app,case["query"])
            command_drain!(app)
            expected=only(case["actions"])
            if expected["kind"]=="error"
                @test app.status==expected["text"]
                @test JuliaForever2.current_thinking_level(JuliaForever2.component(app.session.kernel,:provider))=="low"
            elseif expected["kind"]=="thinking-menu"
                @test app.page==:pi_menu
                @test !isnothing(app.menus.thinking_menu)
            else
                @test JuliaForever2.current_thinking_level(JuliaForever2.component(app.session.kernel,:provider))==expected["level"]
                @test app.page==:chat
            end
            @test !isfile(ProviderCommandsHost.model_settings_path(app))
            @test calls[]==0
        end
    end
end

@testset "Original exact login ids, names, ambiguity, search and cancel with real host owner" begin
    original=command_original_fixture()
    for case in filter(case->case["kind"]=="login",original["cases"])
        mktempdir() do directory
            registry=JuliaForever2.ProviderRegistry()
            for row in case["providers"]
                JuliaForever2.register_provider!(registry,JuliaForever2.ProviderDescriptor(Symbol(row["id"]),row["name"],Returns(JuliaForever2.DemoProvider());auth=Returns(nothing)))
            end
            app=ProviderCommandsHost.App(;settings_dir=directory,registry)
            starts=Symbol[]
            starter=(app,id;action)->begin
                push!(starts,id)
                app.settings.auth_flow=JuliaForever2.AuthFlow()
                app.settings.auth_provider=id
                app.busy=true
                app.page=:auth
            end
            ProviderCommandsHost.login_command!(app,case["query"];on_login=starter)
            control=app.menus.auth_menu_control
            expected=only(case["actions"])
            if expected["kind"]=="login"
                @test starts==[Symbol(expected["id"])]
                @test control.stage==:auth
                @test control.direct
                flow=control.flow
                app.busy=false
                ProviderCommandsHost.auth_menu_finish!(app,control,flow;ok=false)
                @test app.page==:chat
                @test !control.active
                close(flow)
            elseif expected["kind"]=="login-methods"
                @test control.stage==:methods
                @test isempty(starts)
                ProviderCommandsHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:escape))
                @test app.page==:chat
            else
                @test control.stage==:providers
                @test control.scope==:all
                @test control.selector.search.value==expected["query"]
                @test isempty(starts)
                ProviderCommandsHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:escape))
                @test app.page==:chat
            end
            @test isempty(filter(name->endswith(name,".json") && name in ("chatgpt.json","openrouter.json"),readdir(directory)))
            ProviderCommandsHost.finish_shutdown!(app)
            close(app.session.kernel)
        end
    end
end

@testset "Command refresh cancellation, deadline and replacement never commit a late model" begin
    for scenario in (:navigate,:newcommand,:busy,:timeout,:failure)
        provider_command_fixture() do app,calls
            release=Channel{Nothing}(1)
            worked=Channel{Nothing}(1)
            refresh=snapshot->begin
                take!(release)
                put!(worked,nothing)
                scenario==:failure && error("synthetic catalog failure")
                (registry=snapshot.registry,originals=snapshot.originals,errors=String[])
            end
            old=JuliaForever2.component(app.session.kernel,:provider)
            ProviderCommandsHost.model_command!(app,"missing";refresh,timeout=scenario==:timeout ? 0.005 : 15.0)
            lookup=app.menus.model_command
            if scenario==:navigate
                ProviderCommandsHost.open_menu!(app,"settings")
            elseif scenario==:newcommand
                ProviderCommandsHost.dispatch!(app,"/thinking invalid")
            elseif scenario==:busy
                app.busy=true
            end
            if scenario!=:timeout
                put!(release,nothing)
            end
            command_drain!(app)
            if scenario==:timeout
                @test app.page==:pi_menu
                @test app.menus.model_menu.search.value=="missing"
                @test app.status=="Model refresh timed out; searching cached models."
                put!(release,nothing)
            elseif scenario==:failure
                @test app.page==:pi_menu
                @test occursin("Could not refresh",app.status)
            elseif scenario==:navigate
                @test app.menus.path==["settings"]
            elseif scenario==:newcommand
                @test occursin("Unknown thinking level",app.status)
            end
            take!(worked)
            @test JuliaForever2.component(app.session.kernel,:provider)===old
            @test !isfile(ProviderCommandsHost.model_settings_path(app))
            @test calls[]==0
            app.busy=false
        end
    end
end
