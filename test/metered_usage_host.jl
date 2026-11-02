using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module ActualMeteredHostTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JF,:JuliaForever2TerminalExt)
function drain!(app)
    timedwait(30;pollint=0.001) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy
    end
end
@testset "Actual native metering is archived, restored, shown and absent from provider prompts" begin
    cases=JSON.parsefile(joinpath(dirname(pathof(JF)),"..","test","fixtures","metered-usage.json"))["cases"]
    fixture=only(filter(item->item["id"]=="openai-complete-zero",cases))
    requests=String[]
    transport=(url,method,body,headers,context,sink)->begin
        push!(requests,body)
        write(sink,replace(fixture["response"],"Fixture response"=>escape_string(JSON.json((kind="answer",content="Fixture response")))))
        (status=200,reason="Synthetic local transport")
    end
    metadata=fixture["model"]
    model=JF.ModelSpec(:fixture,metadata["id"];api=metadata["api"],metadata)
    backend=JF.HTTPModelBackend(JF.OpenAIChatProtocol(;compatibility=metadata["compat"]),"https://not-called.invalid";
        transport,credentials=Returns(Pair{String,String}[]))
    provider=JF.ConfiguredModelProvider(JF.ModelProvider(model,backend),model,"off")
    kernel=JF.Kernel(provider)
    directory=mktempdir()
    app=T.App(Session(kernel);settings_dir=directory,registry=JF.ProviderRegistry(),theme_fallback="dark")
    @test T.submit_literal_input!(app,"First harmless fixture request").ok
    @test drain!(app)==:ok
    entries=JF.timeline_entries(app.archive.timeline)
    assistant=last(filter(entry->entry["type"]=="message" && get(entry["message"],"role",nothing)=="assistant",entries))["message"]
    @test haskey(assistant,"jf2") && haskey(assistant["jf2"],"usageProvenance")
    accounting=JF.message_usage_accounting(assistant)
    @test accounting.provenance==:native
    @test accounting.cost_source==:catalog_estimate
    @test accounting.report.input_tokens==0 && accounting.report.output_tokens==0
    @test accounting.report.cost==0
    footer=T.footer_control_snapshot(app)
    @test "Cost estimate" in last.(footer.statuses)
    @test !any(label->occursin("Usage unreported",label),last.(footer.statuses))
    id=app.archive.timeline.identity.id
    T.session_action!(app,:resume,id)
    @test drain!(app)==:ok
    @test app.session.usage.reported
    @test app.session.usage.input_tokens==0 && app.session.usage.output_tokens==0
    @test T.submit_literal_input!(app,"Second harmless fixture request").ok
    @test drain!(app)==:ok
    @test length(requests)==2
    @test all(body->!occursin("usageProvenance",body),requests)
    @test occursin("Fixture response",last(requests))
    @test all(body->!occursin("observedFields",body),requests)
    T.finish_shutdown!(app);close(kernel)
end
end
