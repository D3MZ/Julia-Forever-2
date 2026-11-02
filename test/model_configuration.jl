using Test,JuliaForever2,JSON
const MC=JuliaForever2
if !isdefined(MC,:prepare_model_configuration)
    Base.include(MC,joinpath(@__DIR__,"..","src","application","model_configuration.jl"))
end

@testset "Pure catalog-validated model/thinking preparation" begin
    calls=Ref(0);transport=(args...)->(calls[]+=1;(status=200,body=""))
    auth=(args...)->(calls[]+=1;(status=401,body=""))
    policy=MC.CodeModePolicy()
    current=MC.OpenAIProvider("not-read",transport,auth;model="old",policy)
    metadata=Dict{String,Any}("name"=>"Verified model","reasoning"=>true,"contextWindow"=>128000,"thinkingLevelMap"=>Dict("off"=>"none","minimal"=>nothing,"high"=>"xhigh","xhigh"=>"xhigh","max"=>nothing))
    model=MC.ModelSpec(:chatgpt,"new";api="openai-codex-responses",metadata)
    registry=MC.ProviderRegistry()
    factory=MC.ProviderFactory(Returns(current);models=Returns([model]),select=(directory,id)->(calls[]+=1;MC.OpenAIProvider(current,id)))
    MC.register_provider!(registry,MC.ProviderDescriptor(:chatgpt,"ChatGPT",factory))
    @test MC.model_supported_thinking_levels(model)==["off","low","medium","high","xhigh"]
    @test MC.model_clamp_thinking_level(model,"minimal")=="low"
    @test MC.model_clamp_thinking_level(model,"max")=="xhigh"
    @test MC.model_clamp_thinking_level(model,"invalid")=="off"
    result=MC.prepare_model_configuration(current,registry;provider_id=:chatgpt,model_id="new",thinking_level="high",directory="not-read")
    @test result.ok
    preserved=MC.prepare_model_configuration(result.provider,registry;provider_id=:chatgpt,model_id="new",thinking_level=nothing)
    @test preserved.ok && preserved.thinking_level=="high"
    initial=MC.prepare_model_configuration(current,registry;provider_id=:chatgpt,model_id="new",thinking_level=nothing)
    @test initial.ok && initial.thinking_level=="medium"
    @test MC.provider_model_identity(:unconfigured).model_id==""
    @test isnothing(MC.current_thinking_level(:unconfigured))
    @test result.model.metadata!==metadata
    @test calls[]==0
    @test current.model=="old"
    @test isnothing(current.reasoning)
    @test isempty(current.catalog.selected_model)
    @test result.provider.backend.model=="new"
    @test result.provider.backend.reasoning=="xhigh"
    @test result.provider.backend.catalog===current.catalog
    @test result.provider.backend.transport===transport
    @test result.provider.backend.auth_transport===auth
    @test result.provider.backend.policy===policy
    @test MC.provider_protocol(result.provider)===policy
    @test MC.current_thinking_level(result.provider)=="high"
    @test MC.provider_model_identity(result.provider)==(provider_id=:chatgpt,model_id="new")
    @test MC.model_context_window(result.provider)==128000
    @test MC.provider_footer_status(result.provider).thinking=="high"
    request=MC.ModelRequest(MC.Message[],"instructions",nothing,Dict("type"=>"json_object"),policy)
    payload=MC.chatgpt_request_payload(result.provider.backend,request,"new")
    @test payload["model"]=="new"
    @test payload["reasoning"]==Dict("effort"=>"xhigh","summary"=>"auto")
    @test payload["store"]==false && payload["stream"]==true
    @test payload["input"][1]["role"]=="developer"
    @test payload["text"]["format"]==request.response_format
    off=MC.prepare_model_configuration(result.provider,registry;provider_id="openai-codex",model_id="new",thinking_level="off")
    @test off.ok
    @test MC.chatgpt_request_payload(off.provider.backend,request,"new")["reasoning"]["effort"]=="none"
    @test MC.current_thinking_level(off.provider)=="off"
    @test MC.prepare_model_configuration(current,registry;provider_id=:chatgpt,model_id="unknown",thinking_level="high").ok==false
    @test MC.prepare_model_configuration(current,registry;provider_id=:chatgpt,model_id="new",thinking_level="max").ok==false
    @test MC.prepare_model_configuration(current,registry;provider_id=:openrouter,model_id="new",thinking_level="high").ok==false
    @test MC.prepare_model_configuration(MC.DemoProvider(),registry;provider_id="openai-codex",model_id="new",thinking_level="high",allow_provider_change=true).ok==false
    cross=MC.prepare_model_configuration(MC.DemoProvider(),registry;provider_id=:chatgpt,model_id="new",thinking_level="low",allow_provider_change=true)
    @test cross.ok
    @test calls[]==1 # the explicitly selected provider factory, never model/auth transport
    @test current.model=="old"
    direct=MC.OpenAIProvider(current.dir,current.model,current.transport,current.auth_transport,current.policy,current.catalog,current.catalog_ttl)
    @test isnothing(direct.reasoning)
    router=MC.OpenRouterProvider("synthetic-not-real","router",transport;policy)
    rm=MC.ModelSpec(:openrouter,"router";metadata=deepcopy(metadata))
    rb=MC.configure_model_thinking(router,rm,"high")
    @test rb.api_key===router.api_key && rb.transport===transport && rb.policy===policy
    @test MC.openrouter_request_payload(rb,request)["reasoning"]["effort"]=="xhigh"
    @test !occursin("synthetic",sprint(show,rb))
    codex=MC.CodexProvider("not-executed";model="old",reasoning="medium",policy)
    cb=MC.configure_model_thinking(codex,model,"high")
    @test cb.executable==codex.executable && cb.policy===policy
    @test cb.reasoning=="xhigh"
    command=MC.CodexRequest(cb,request,"not-written").command
    @test any(contains("model_reasoning_effort=\"xhigh\""),command.exec)
    @test isfile("not-written/schema.json")==false
    protocol=MC.OpenAIChatProtocol()
    options=Dict{String,Any}("temperature"=>.2,"reasoningEffort"=>"low","maxTokens"=>128)
    creds=Returns(["Authorization"=>"Bearer synthetic"])
    backend=MC.HTTPModelBackend(protocol,"https://fixture.invalid";credentials=creds,transport,options)
    bound=MC.configure_model_thinking(MC.ModelProvider(model,backend),model,"high")
    @test bound.backend.transport===transport && bound.backend.credentials===creds
    @test bound.backend.protocol===protocol && bound.backend.endpoint==backend.endpoint
    selected_options=MC.model_request_options(bound.backend.options,model,request)
    @test selected_options["reasoningEffort"]=="xhigh"
    @test options["reasoningEffort"]=="low"
    @test selected_options["temperature"]==.2
    wire=MC.model_payload(protocol,model,request,selected_options)
    @test wire["reasoning_effort"]=="xhigh"
    @test wire["max_completion_tokens"]==128
    openrouter_protocol=MC.OpenAIChatProtocol(;compatibility=Dict("thinkingFormat"=>"openrouter"))
    fields=MC.configuration_thinking_fields(openrouter_protocol,rm,"high")
    @test MC.model_payload(openrouter_protocol,rm,request,fields)["reasoning"]["effort"]=="xhigh"
    unsupported=MC.OpenAIChatProtocol(;compatibility=Dict("thinkingFormat"=>"deepseek"))
    @test isnothing(MC.configuration_thinking_fields(unsupported,model,"high"))
    nonreasoning=MC.ModelSpec(:chatgpt,"simple";metadata=Dict("reasoning"=>false))
    @test MC.model_supported_thinking_levels(nonreasoning)==["off"]
    plain=MC.configure_model_thinking(current,nonreasoning,"off")
    @test !haskey(MC.chatgpt_request_payload(plain,request,"simple"),"reasoning")
    @test calls[]==1
end

@testset "Anthropic request-specific thinking budgets" begin
    protocol=MC.AnthropicMessagesProtocol()
    model=MC.ModelSpec(:anthropic,"fixture";metadata=Dict{String,Any}("reasoning"=>true,"maxTokens"=>16000))
    request=MC.ModelRequest(MC.Message[],"",nothing,nothing,MC.CodeModePolicy())
    base=Dict{String,Any}("maxTokens"=>4000,"temperature"=>.3)
    backend=MC.HTTPModelBackend(protocol,"https://fixture.invalid";options=base)
    configured=MC.configure_model_backend(backend,model,"high")
    options=MC.model_request_options(configured.options,model,request)
    wire=MC.model_payload(protocol,model,request,options)
    @test wire["thinking"]==Dict("type"=>"enabled","budget_tokens"=>14976,"display"=>"summarized")
    @test wire["max_tokens"]==16000
    @test base==Dict("maxTokens"=>4000,"temperature"=>.3)
    medium=MC.configure_model_backend(configured,model,"medium")
    @test MC.model_request_options(medium.options,model,request)["maxTokens"]==12192
    @test medium.options.original===base
    off=MC.configure_model_backend(backend,model,"off")
    @test MC.model_payload(protocol,model,request,MC.model_request_options(off.options,model,request))["thinking"]==Dict("type"=>"disabled")
    adaptive=MC.ModelSpec(:anthropic,"adaptive";metadata=Dict{String,Any}("reasoning"=>true,"maxTokens"=>16000,"compat"=>Dict("forceAdaptiveThinking"=>true),"thinkingLevelMap"=>Dict("high"=>"max")))
    adapted=MC.configure_model_backend(backend,adaptive,"high")
    aw=MC.model_payload(protocol,adaptive,request,MC.model_request_options(adapted.options,adaptive,request))
    @test aw["thinking"]==Dict("type"=>"adaptive","display"=>"summarized")
    @test aw["output_config"]==Dict("effort"=>"max")
    @test aw["max_tokens"]==4000
end

function configuration_differential(path)
    oracle=JSON.parsefile(path)
    checks=0
    @testset "Original model capability and reasoning-wire projection" begin
        for case in oracle["cases"]
            source=case["model"]
            model=MC.ModelSpec(Symbol(source["provider"]),source["id"];api=source["api"],metadata=source)
            @test MC.model_supported_thinking_levels(model)==case["supported"]
            for (level,expected) in case["clamped"]
                @test MC.model_clamp_thinking_level(model,level)==expected
            end
            request=MC.ModelRequest(MC.Message[],"",nothing,nothing,MC.CodeModePolicy())
            for expected in case["wires"]
                level=expected["level"]
                wire=if case["backend"]=="codex"
                    configured=MC.configure_model_thinking(MC.OpenAIProvider("not-read"),model,level)
                    MC.chatgpt_request_payload(configured,request,model.id)
                else
                    protocol=case["backend"] in ("anthropic","adaptive") ? MC.AnthropicMessagesProtocol() : MC.OpenAIChatProtocol(;compatibility=source["compat"])
                    backend=MC.configure_model_backend(MC.HTTPModelBackend(protocol,"https://fixture.invalid"),model,level)
                    options=MC.model_request_options(backend.options,model,request)
                    MC.model_payload(protocol,model,request,options)
                end
                projection=Dict(key=>get(wire,key,nothing) for key in ("reasoning","reasoning_effort","thinking","output_config","max_tokens"))
                wanted=Dict(key=>expected[key] for key in keys(projection))
                @test projection==wanted
                checks+=1
            end
        end
    end
    println("Matched original reasoning request projections: ",checks)
end
if length(ARGS)==1 && isfile(ARGS[1])
    configuration_differential(ARGS[1])
end

@testset "Configuration preserves independent provider options" begin
    model=MC.ModelSpec(:openrouter,"fixture";metadata=Dict{String,Any}("reasoning"=>true))
    protocol=MC.OpenAIChatProtocol(;compatibility=Dict("thinkingFormat"=>"openrouter"))
    original=Dict{String,Any}("temperature"=>.25,"reasoning"=>Dict{String,Any}("effort"=>"low","exclude"=>true))
    calls=Ref(0)
    source=(m,r)->(calls[]+=1;original)
    backend=MC.HTTPModelBackend(protocol,"https://fixture.invalid";options=source)
    configured=MC.configure_model_backend(backend,model,"high")
    @test calls[]==0
    request=MC.ModelRequest(MC.Message[],"",nothing,nothing,MC.CodeModePolicy())
    options=MC.model_request_options(configured.options,model,request)
    @test calls[]==1
    @test options["reasoning"]==Dict("effort"=>"high","exclude"=>true)
    @test original["reasoning"]==Dict("effort"=>"low","exclude"=>true)
    @test options["temperature"]==.25
end
