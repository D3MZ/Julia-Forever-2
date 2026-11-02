using Test,JuliaForever2,JSON,SHA
const BuiltinKeys=JuliaForever2
function key_registration_original()
    path=joinpath(@__DIR__,"fixtures","pi-builtin-key-actions.json")
    original=JSON.parsefile(path)
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        mktempdir() do temporary
            generator=joinpath(@__DIR__,"differential","pi_builtin_keys_oracle.mjs")
            run(`node $generator $reference $(joinpath(temporary,"data.json")) $(joinpath(temporary,"provenance.json")) $(joinpath(temporary,"actions.json"))`)
            @test read(joinpath(temporary,"actions.json"))==read(path)
        end
    end
    provenance=JSON.parsefile(joinpath(@__DIR__,"..","src","providers","catalog_data","builtin-key-models.provenance.json"))
    @test bytes2hex(sha256(read(joinpath(@__DIR__,"..","src","providers","catalog_data","builtin-key-models.json"))))==provenance["outputSha256"]
    @test provenance["generatorSha256"]==original["generatorSha256"]
    @test bytes2hex(sha256(read(path)))=="29b87abcfdda35348e2019585a8af03e9ec460ff075173a36c6c47144655ce3c"
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test original["generatorSha256"]==bytes2hex(sha256(read(joinpath(@__DIR__,"differential","pi_builtin_keys_oracle.mjs"))))
    original
end
@testset "Original callable API-key registrations exist in the native built-in registry" begin
    original=key_registration_original()
    registry=BuiltinKeys.builtin_provider_registry()
    for row in original["registrations"]
        descriptor=BuiltinKeys.provider_descriptor(registry,Symbol(row["id"]))
        @test !isnothing(descriptor)
        if !isnothing(descriptor)
            @test descriptor.label==row["name"]
            @test descriptor.auth isa BuiltinKeys.APIKeyAuthMethod
            @test descriptor.auth.name==row["apiKeyName"]
            models=BuiltinKeys.provider_models(registry;provider=descriptor.id)
            @test [m.id for m in models]==[case["modelId"] for case in original["cases"] if case["provider"]==row["id"]]
        end
    end
end
@testset "Every original registered model and thinking suboption prepares a real native backend" begin
    original=key_registration_original()
    registry=BuiltinKeys.builtin_provider_registry()
    mktempdir() do directory
        current=BuiltinKeys.DemoProvider()
        request=BuiltinKeys.ModelRequest([Message(:user,"Harmless fixture")],"",nothing,nothing,nothing)
        for case in original["cases"]
            id=Symbol(case["provider"])
            model=BuiltinKeys.provider_model(registry,id,case["modelId"])
            @test !isnothing(model)
            @test BuiltinKeys.model_supported_thinking_levels(model)==case["levels"]
            for wire in case["wires"]
                result=BuiltinKeys.prepare_model_configuration(current,registry;provider_id=id,model_id=model.id,
                    thinking_level=wire["level"],directory,allow_provider_change=true)
                @test result.ok
                if result.ok
                    backend=result.provider.backend.backend
                    options=BuiltinKeys.model_request_options(backend.options,model,request)
                    payload=BuiltinKeys.model_payload(backend.protocol,model,request,options)
                    for field in ("reasoning_effort","thinking","output_config","fallbacks")
                        @test get(payload,field,nothing)==get(wire["payload"],field,nothing)
                    end
                    if id==:anthropic
                        @test payload["messages"]==wire["payload"]["messages"]
                        @test BuiltinKeys.anthropic_beta_features(model,options,request)==get(wire["payload"],"betas",String[])
                    end
                    @test backend.credentials isa BuiltinKeys.APIKeyCredentialResolver
                    @test payload["model"]==model.id
                end
            end
        end
    end
end
@testset "Catalog refresh updates real key factories and validators rather than only visible rows" begin
    registry=BuiltinKeys.builtin_provider_registry()
    before=BuiltinKeys.provider_descriptor(registry,:groq)
    original=first(BuiltinKeys.provider_models(registry;provider=:groq))
    extra=BuiltinKeys.ModelSpec(:groq,"synthetic-new-model";api=original.api,metadata=deepcopy(original.metadata))
    BuiltinKeys.install_model_catalog!(registry,before,[extra])
    after=BuiltinKeys.provider_descriptor(registry,:groq)
    @test after!==before
    @test "synthetic-new-model" in after.auth.validate.known_models
    mktempdir() do directory
        provider=BuiltinKeys.provider_from_name(:groq;dir=directory,registry,model="synthetic-new-model")
        @test provider isa BuiltinKeys.ModelProvider
        @test provider.model.id=="synthetic-new-model"
        @test provider.backend.endpoint=="https://api.groq.com/openai/v1"
        @test provider.backend.credentials isa BuiltinKeys.APIKeyCredentialResolver
        store=BuiltinKeys.FileModelStore(directory)
        @test BuiltinKeys.cache_installed_catalog!(store,after).ok
        fresh=BuiltinKeys.builtin_provider_registry()
        @test :groq in BuiltinKeys.restore_model_catalogs!(fresh,BuiltinKeys.FileModelStore(directory))
        restored=BuiltinKeys.provider_from_name(:groq;dir=directory,registry=fresh,model="synthetic-new-model")
        @test restored isa BuiltinKeys.ModelProvider
        @test restored.model.id=="synthetic-new-model"
        @test "synthetic-new-model" in BuiltinKeys.provider_descriptor(fresh,:groq).auth.validate.known_models
    end
end
@testset "Anthropic model pagination stays on its declared endpoint and fails closed on malformed or partial results" begin
    for scenario in (:ok,:cycle,:unsafe,:denied,:cancel,:limit)
        calls=String[]
        context=BuiltinKeys.ExecutionContext()
        transport=(url,method,body,headers,ctx,sink)->begin
            push!(calls,url)
            if length(calls)==1
                (status=200,body=JSON.json(Dict("data"=>[Dict("id"=>"page-one")],"has_more"=>true,"last_id"=>"page-one")),reason="")
            elseif scenario==:denied
                (status=401,body="",reason="")
            else
                scenario==:cancel && BuiltinKeys.cancel!(ctx)
                cursor=scenario==:cycle ? "page-one" : scenario==:unsafe ? "https://bad.invalid/?key=unsafe" : "known"
                (status=200,body=JSON.json(Dict("data"=>[Dict("id"=>cursor)],"has_more"=>scenario in (:cycle,:unsafe),"last_id"=>cursor)),reason="")
            end
        end
        client=BuiltinKeys.APIKeyCatalogValidator(;provider=:anthropic,url="https://api.anthropic.com/v1/models",
            header=:anthropic,known_models=["known"],transport,paginate=true,max_pages=scenario==:limit ? 1 : 32)
        result=client(:anthropic,"SYNTHETIC_ONLY",context)
        @test result.ok==(scenario==:ok)
        @test all(url->startswith(url,"https://api.anthropic.com/v1/models"),calls)
        @test length(calls)==(scenario==:limit ? 1 : scenario==:unsafe ? 3 : 2)
        @test !occursin("SYNTHETIC_ONLY",repr(result))
        close(context)
    end
    transport=BuiltinKeys.APIKeyHTTPTransport(;urls=["https://api.anthropic.com/v1/models"],pagination_urls=["https://api.anthropic.com/v1/models"])
    @test BuiltinKeys.api_key_endpoint_allowed(transport,"https://api.anthropic.com/v1/models?after_id=known-1")
    @test !BuiltinKeys.api_key_endpoint_allowed(transport,"https://api.anthropic.com/v1/models?after_id=known&next=https://bad.invalid")
    @test !BuiltinKeys.api_key_endpoint_allowed(transport,"https://bad.invalid/v1/models?after_id=known")
end
@testset "Managed effort source histories retain actual provider boundaries, switching and disabled semantics" begin
    original=key_registration_original();registry=BuiltinKeys.builtin_provider_registry()
    mktempdir() do directory
        for case in original["historyCases"]
            model=BuiltinKeys.provider_model(registry,:anthropic,case["modelId"])
            provider=BuiltinKeys.prepare_model_configuration(BuiltinKeys.DemoProvider(),registry;provider_id=:anthropic,
                model_id=model.id,thinking_level=case["level"],directory,allow_provider_change=true).provider
            backend=provider.backend.backend
            request=BuiltinKeys.ModelRequest(case["messages"],"",nothing,nothing,nothing)
            options=BuiltinKeys.model_request_options(backend.options,model,request)
            payload=BuiltinKeys.model_payload(backend.protocol,model,request,options)
            @test payload["messages"]==case["payload"]["messages"]
            @test payload["thinking"]==case["payload"]["thinking"]
            @test get(payload,"output_config",nothing)==get(case["payload"],"output_config",nothing)
            @test BuiltinKeys.anthropic_beta_features(model,options,request)==get(case["payload"],"betas",String[])
        end
    end
end
