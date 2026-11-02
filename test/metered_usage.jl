using Test,JSON,SHA,JuliaForever2
const Metered=JuliaForever2
function metered_completion(fixture)
    metadata=fixture["model"]
    model=Metered.ModelSpec(:fixture,metadata["id"];api=metadata["api"],metadata)
    protocol=fixture["protocol"]=="anthropic" ? Metered.AnthropicMessagesProtocol() : Metered.OpenAIChatProtocol(;compatibility=metadata["compat"])
    requests=Any[]
    transport=(url,method,body,headers,context,sink)->begin
        push!(requests,JSON.parse(body))
        bytes=codeunits(fixture["response"])
        for first in 1:7:length(bytes)
            write(sink,bytes[first:min(first+6,end)])
        end
        (status=200,reason="fixture")
    end
    backend=Metered.HTTPModelBackend(protocol,"https://fixture.invalid";transport,credentials=Returns(Pair{String,String}[]))
    events=Any[]
    context=ExecutionContext(;event_sink=event->event.kind==:model_stream && push!(events,deepcopy(event.data)))
    request=ModelRequest([Message(:user,"Fixture prompt")],"",nothing,nothing,nothing)
    result=Metered.respond_model(backend,model,request,context)
    close(context)
    message=deepcopy(result.message)
    delete!(message,"timestamp");delete!(message,"durationMs")
    (;message,events,report=result.usage,requests,provenance=Metered.response_usage_provenance(result))
end
@testset "Source-equivalent rich output and truthful metering are separate contracts" begin
    reference=get(ENV,"PI_REFERENCE","")
    evidence=get(ENV,"METERED_EVIDENCE",mktempdir());mkpath(evidence)
    runner=joinpath(@__DIR__,"differential","metered_usage_oracle.mjs")
    fixture_path=joinpath(@__DIR__,"fixtures","metered-usage.json")
    provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
    output=joinpath(evidence,"original.json")
    saved=joinpath(@__DIR__,"fixtures","pi-metered-usage-original.json")
    @test bytes2hex(sha256(read(saved)))=="ed38b8f6a5cdfedc56a21183ada23fa5095c8a1ab27ac70fd2b17e6c9d05cdcd"
    original=JSON.parsefile(saved)
    @test original["provenance"]["fixtureSha256"]==bytes2hex(sha256(read(fixture_path)))
    @test original["provenance"]["runnerSha256"]==bytes2hex(sha256(read(runner)))
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    if isdir(reference)
        run(`node $runner $reference $provenance $output $fixture_path`)
        fresh=JSON.parsefile(output)
        @test fresh==original
        original=fresh
    end
    @test original["provenance"]["checkedSourceFiles"]==513
    fixtures=JSON.parsefile(fixture_path)["cases"]
    actual=Any[]
    for (fixture,expected) in zip(fixtures,original["cases"])
        result=metered_completion(fixture)
        @test fixture["id"]==expected["id"]
        @test length(result.requests)==length(expected["requests"])==1
        @test result.message==expected["message"]
        @test result.events==expected["events"]
        report=Dict(String(name)=>getfield(result.report,name) for name in fieldnames(typeof(result.report)))
        for (name,value) in fixture["expectedReport"]
            actual_value=get(report,name,nothing)
            @test isnothing(value) ? isnothing(actual_value) : name=="cost" ? !isnothing(actual_value) && isapprox(actual_value,value) : actual_value==value
        end
        @test result.provenance["format"]=="JuliaForever2.usage-provenance.v1"
        @test result.provenance["costSource"]==(isnothing(result.report.cost) ? "unknown" : "catalog-estimate")
        push!(actual,(id=fixture["id"],message=result.message,events=result.events,report=report,provenance=result.provenance))
    end
    write(joinpath(evidence,"native.json"),JSON.json((cases=actual,)))
end

@testset "Validated observations, defensive provenance and unknown catalog costs" begin
    rates=Dict{String,Any}("input"=>1,"output"=>2,"cacheRead"=>0.25,"cacheWrite"=>1.5)
    model=Metered.ModelSpec(:fixture,"native";metadata=Dict("cost"=>rates))
    context=ExecutionContext()
    state=Metered.ModelStreamState(model,context)
    @test Metered.model_reported_usage(state)==Metered.UsageReport()
    for invalid in (nothing,true,false,-1,1.5,Inf,NaN,"0",big(typemax(Int))+1)
        Metered.openai_metered_usage!(state,Dict("prompt_tokens"=>invalid,"completion_tokens"=>invalid,
            "prompt_tokens_details"=>Dict("cached_tokens"=>invalid,"cache_write_tokens"=>invalid)))
        report=Metered.model_reported_usage(state)
        @test all(isnothing,(report.input_tokens,report.output_tokens,report.cache_read_tokens,report.cache_write_tokens,report.cost))
    end
    Metered.openai_metered_usage!(state,Dict("prompt_tokens"=>10,"completion_tokens"=>0,"prompt_cache_hit_tokens"=>nothing,
        "cached_tokens"=>3,"prompt_tokens_details"=>Dict("cached_tokens"=>nothing,"cache_write_tokens"=>0)))
    @test Metered.model_reported_usage(state)==Metered.UsageReport(7,0,7.75e-6,3,0)
    Metered.openai_metered_usage!(state,Dict())
    @test Metered.model_reported_usage(state)==Metered.UsageReport()
    Metered.anthropic_metered_usage!(state,Dict("input_tokens"=>12,"output_tokens"=>0,
        "cache_read_input_tokens"=>0,"cache_creation_input_tokens"=>0);initial=true)
    Metered.anthropic_metered_usage!(state,Dict("output_tokens"=>3))
    report=Metered.model_reported_usage(state)
    @test (report.input_tokens,report.output_tokens,report.cache_read_tokens,report.cache_write_tokens)==(12,3,0,0)
    Metered.anthropic_metered_usage!(state,Dict("input_tokens"=>nothing))
    @test Metered.model_reported_usage(state).input_tokens===nothing
    @test Metered.model_reported_usage(state).output_tokens==3
    @test Metered.model_reported_usage(state).cost===nothing
    Metered.anthropic_metered_usage!(state,Dict();initial=true)
    @test Metered.model_reported_usage(state)==Metered.UsageReport()
    zero=Metered.ModelUsageMeter(;input=0,output=0,cache_read=0,cache_write=0)
    @test Metered.model_metered_cost(zero,Dict("cost"=>rates))==0.0
    @test Metered.model_metered_cost(zero,Dict())===nothing
    @test Metered.model_metered_cost(zero,Dict("cost"=>Dict("input"=>0)))===nothing
    for invalid in (nothing,true,-1,Inf,NaN,"0")
        changed=copy(rates);changed["output"]=invalid
        @test Metered.model_metered_cost(zero,Dict("cost"=>changed))===nothing
    end
    writer=Metered.ModelUsageMeter(;input=0,output=0,cache_read=0,cache_write=10)
    hourly=merge(rates,Dict("cacheWrite1h"=>3))
    @test Metered.model_metered_cost(writer,Dict("cost"=>hourly))===nothing
    writer.cache_write_1h=0
    @test Metered.model_metered_cost(writer,Dict("cost"=>hourly))≈15e-6
    writer.cache_write_1h=5
    @test Metered.model_metered_cost(writer,Dict("cost"=>hourly))≈22.5e-6
    state.metering=zero
    request=ModelRequest(Message[],"",nothing,nothing,nothing)
    state.message["stopReason"]="stop"
    completion=Metered.StreamedCompletion(state,request)
    provenance=Metered.response_usage_provenance(completion)
    @test provenance["usage"]==Dict("input"=>0,"output"=>0,"cacheRead"=>0,"cacheWrite"=>0,"cost"=>0.0)
    provenance["usage"]["input"]=999
    empty!(provenance["observedFields"])
    @test Metered.response_usage_provenance(completion)["usage"]["input"]==0
    @test length(Metered.response_usage_provenance(completion)["observedFields"])==4
    @test !haskey(completion.message,"jf2") && !haskey(completion.message,"provenance")
    legacy=Metered.StreamedCompletion(Reply(:answer,"legacy"),Metered.UsageReport(),Dict())
    @test Metered.response_usage_provenance(legacy)===nothing
    @test Metered.response_usage_provenance(nothing)===nothing
    close(context)
end

@testset "Shared archive reader distinguishes observed fields from legacy declarations" begin
    report=Metered.UsageReport(0,0,0.0,0,0)
    marker=Metered.model_usage_provenance(report)
    wire=Dict{String,Any}("usage"=>Dict("input"=>999,"output"=>999,"cacheRead"=>999,"cacheWrite"=>999,"cost"=>Dict("total"=>999)),
        "jf2"=>Dict("usageProvenance"=>marker,"untouched"=>true))
    before=deepcopy(wire)
    accounting=Metered.message_usage_accounting(wire)
    @test accounting.report==report
    @test accounting.provenance==:native && accounting.cost_source==:catalog_estimate
    @test wire==before
    empty!(marker["observedFields"])
    accounting=Metered.message_usage_accounting(wire)
    @test accounting.report==Metered.UsageReport() && accounting.provenance==:native && accounting.cost_source==:unknown
    marker["observedFields"]=["input"]
    marker["usage"]["input"]=true
    @test Metered.message_usage_accounting(wire).report.input_tokens===nothing
    marker["usage"]["input"]=0
    @test Metered.message_usage_accounting(wire).report.input_tokens==0
    @test Metered.message_usage_accounting(wire).report.cost===nothing
    delete!(wire,"jf2")
    legacy=Metered.message_usage_accounting(wire)
    @test legacy.provenance==:legacy && legacy.cost_source==:legacy_declared
    @test legacy.report.input_tokens==999 && legacy.report.cost==999
    @test Metered.message_usage_accounting(Dict()).provenance==:absent
    @test Metered.message_usage_accounting(nothing).report==Metered.UsageReport()
    wire["jf2"]=Dict("usageProvenance"=>Dict("format"=>"unknown-future-version"))
    @test Metered.message_usage_accounting(wire)==legacy
end

@testset "Denied and pre-cancelled requests never claim initialized zero as metered" begin
    for cancelled in (false,true)
        calls=Ref(0)
        transport=(args...)->(calls[]+=1;(status=403,reason="fixture denial"))
        backend=Metered.HTTPModelBackend(Metered.OpenAIChatProtocol(),"https://fixture.invalid";transport)
        model=Metered.ModelSpec(:fixture,"denied";metadata=Dict("cost"=>Dict("input"=>0,"output"=>0,"cacheRead"=>0,"cacheWrite"=>0)))
        context=ExecutionContext()
        cancelled && Metered.cancel!(context)
        response=Metered.respond_model(backend,model,ModelRequest(Message[],"",nothing,nothing,nothing),context)
        @test response.usage==Metered.UsageReport()
        @test isempty(Metered.response_usage_provenance(response)["observedFields"])
        @test Metered.response_usage_provenance(response)["costSource"]=="unknown"
        @test response.message["stopReason"]==(cancelled ? "aborted" : "error")
        @test calls[]==(cancelled ? 0 : 1)
        close(context)
    end
end
