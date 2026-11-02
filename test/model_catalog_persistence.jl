using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const CatalogHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Modern direct ChatGPT discovery accepts standard model-list shape" begin
    provider=JuliaForever2.OpenAIProvider("synthetic-unused-directory")
    result=JuliaForever2.discover!(provider,Dict("data"=>[Dict("id"=>"gpt-fixture"),Dict("id"=>"second-fixture")]))
    @test result.models==["gpt-fixture","second-fixture"]
    @test isempty(result.reason)
    @test JuliaForever2.pi_catalog_provider(:chatgpt)=="openai"
end
@testset "Fresh builtin registry has source-snapshot metadata without grants" begin
    registry=JuliaForever2.builtin_provider_registry()
    models=JuliaForever2.provider_models(registry;provider=:chatgpt)
    @test length(models)==44
    @test all(model->model.kind==:chat && model.api=="openai-responses",models)
end

@testset "Bundled metadata has separately verified source and hydrated snapshot provenance" begin
    path=joinpath(@__DIR__,"..","src","providers","catalog_data","builtin-chat-models.json")
    provenance=JSON.parsefile(replace(path,".json"=>".provenance.json"))
    @test provenance["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test provenance["outputSha256"]==bytes2hex(sha256(read(path)))=="9f9fe73de56df3c7404809cc642954d30b27ab229555a6f4873625f37a88a4e1"
    @test occursin("MIT License",provenance["license"])
    @test occursin("not git-tracked",provenance["method"])
    @test provenance["hydratedManifest"]["generatedAt"]=="2026-11-01T19:55:37.646Z"
    for (file,hash) in provenance["hydratedHashes"]
        @test provenance["hydratedManifest"]["files"][basename(file)]==hash
    end
    oracle=joinpath(@__DIR__,"differential","pi_native_catalog_oracle.mjs")
    @test bytes2hex(sha256(read(oracle)))==provenance["generatorSha256"]
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    if !isempty(reference)
        mktempdir() do directory
            output=joinpath(directory,"catalog.json")
            evidence=joinpath(directory,"provenance.json")
            run(`node $oracle $reference $output $evidence`)
            @test read(output)==read(path)
            @test JSON.parsefile(evidence)==provenance
        end
    end
end

@testset "Modern and legacy discovery reject malformed shape without poisoning last good cache" begin
    for data in (Dict(),Dict("data"=>"bad"),Dict("data"=>[Dict("id"=>nothing)]),Dict("data"=>[Dict("id"=>"")]))
        provider=JuliaForever2.OpenAIProvider("synthetic-unused-directory")
        provider.catalog.models=["retained"]
        result=JuliaForever2.discover!(provider,data)
        @test !isempty(result.reason)
        @test provider.catalog.models==["retained"]
    end
    provider=JuliaForever2.OpenAIProvider("synthetic-unused-directory")
    legacy=JuliaForever2.discover!(provider,Dict("models"=>[Dict("slug"=>"visible","visibility"=>"list"),Dict("slug"=>"hidden","visibility"=>"hidden")]))
    @test legacy.models==["visible"]
    empty!(legacy.models)
    @test provider.catalog.models==["visible"]
end

function catalog_fixture_body(id="fixture-modern-model")
    JSON.json(Dict("models"=>[Dict("id"=>id,"api"=>"openai-responses","type"=>"chat","reasoning"=>true,"contextWindow"=>128000,"maxTokens"=>32000)]))
end
@testset "Owned durable catalog restores before actual App default transaction" begin
    mktempdir() do directory
        firstregistry=JuliaForever2.builtin_provider_registry()
        store=JuliaForever2.FileModelStore(directory)
        response=catalog_fixture_body()
        requests=String[]
        result=JuliaForever2.refresh_pi_model_catalog!(firstregistry,:chatgpt;fetcher=url->(push!(requests,url);response),store)
        @test result.ok
        @test requests==["https://pi.dev/api/models/providers/openai"]
        saved=JuliaForever2.read_model_catalog(store,:chatgpt)
        @test saved["body"]==response
        @test saved["snapshotSha256"]==bytes2hex(sha256(response))
        @test saved["fetchedAt"]>0
        cachefile=JuliaForever2.model_catalog_path(store,:chatgpt)
        @test stat(cachefile).mode & 0o777 == 0o600
        @test stat(store.directory).mode & 0o777 == 0o700
        write(joinpath(directory,"provider"),"chatgpt")
        write(joinpath(directory,"model-settings.json"),JSON.json(Dict("defaultModel"=>"chatgpt/fixture-modern-model","defaultThinking"=>"high")))
        fresh=JuliaForever2.builtin_provider_registry()
        @test isnothing(JuliaForever2.provider_model(fresh,:chatgpt,"fixture-modern-model"))
        app=CatalogHost.terminal_app(;settings_dir=directory,registry=fresh)
        selected=JuliaForever2.component(app.session.kernel,:provider)
        @test JuliaForever2.provider_model_identity(selected)==(provider_id=:chatgpt,model_id="fixture-modern-model")
        @test JuliaForever2.current_thinking_level(selected)=="high"
        @test app.page==:chat
        @test !isfile(joinpath(directory,"chatgpt.json"))
        @test !isfile(joinpath(directory,"credentials.json"))
        @test length(requests)==1
        CatalogHost.finish_shutdown!(app)
        @test !isopen(app.session.kernel)
    end
end

@testset "Metadata cache rejects symlinks, stale writers and modified snapshot bodies" begin
    mktempdir() do directory
        registry=JuliaForever2.builtin_provider_registry()
        first=JuliaForever2.FileModelStore(directory)
        second=JuliaForever2.FileModelStore(directory)
        @test isnothing(JuliaForever2.read_model_catalog(first,:chatgpt))
        @test isnothing(JuliaForever2.read_model_catalog(second,:chatgpt))
        body=catalog_fixture_body()
        entry=Dict("schemaVersion"=>1,"provider"=>"chatgpt","source"=>JuliaForever2.model_catalog_source(:chatgpt),"fetchedAt"=>time(),"snapshotSha256"=>bytes2hex(sha256(body)),"body"=>body)
        JuliaForever2.write_model_catalog!(first,:chatgpt,entry)
        @test_throws TaskFailedException JuliaForever2.write_model_catalog!(second,:chatgpt,entry)
        file=JuliaForever2.model_catalog_path(first,:chatgpt)
        original=read(file,String)
        changed=copy(entry);changed["body"]=catalog_fixture_body("poisoned")
        write(file,JSON.json(changed))
        @test isnothing(JuliaForever2.read_model_catalog(first,:chatgpt))
        @test isempty(JuliaForever2.restore_model_catalogs!(registry,first))
        @test isnothing(JuliaForever2.provider_model(registry,:chatgpt,"poisoned"))
        write(file,original)
        outside=joinpath(directory,"untouched.json")
        mv(file,outside)
        symlink(outside,file)
        @test isnothing(JuliaForever2.read_model_catalog(first,:chatgpt))
        @test_throws TaskFailedException JuliaForever2.write_model_catalog!(first,:chatgpt,entry)
        @test read(outside,String)==original
    end
end

@testset "Metadata cache removal is revision-scoped and separate from credentials" begin
    mktempdir() do directory
        store=JuliaForever2.FileModelStore(directory)
        body=catalog_fixture_body()
        entry=Dict("schemaVersion"=>1,"provider"=>"chatgpt","source"=>JuliaForever2.model_catalog_source(:chatgpt),"fetchedAt"=>time(),"snapshotSha256"=>bytes2hex(sha256(body)),"body"=>body)
        JuliaForever2.write_model_catalog!(store,:chatgpt,entry)
        sentinel=joinpath(directory,"unrelated.txt")
        write(sentinel,"retained")
        JuliaForever2.delete_model_catalog!(store,:chatgpt)
        @test !ispath(JuliaForever2.model_catalog_path(store,:chatgpt))
        @test read(sentinel,String)=="retained"
        @test isnothing(JuliaForever2.read_model_catalog(store,:chatgpt))
    end
end
