using Test, JSON, JuliaForever2, Tachikoma, CommonMark
const RSJ=JuliaForever2
const RST=Base.get_extension(RSJ,:JuliaForever2TerminalExt)
Base.@kwdef mutable struct RuntimeSettingsFixtureProvider
    model::RSJ.ModelSpec = RSJ.ModelSpec(:fixture,"runtime-settings";metadata=Dict("contextWindow"=>1000))
    mode::Symbol = :success
    calls::Vector{Symbol} = Symbol[]
    observed_idle::Vector{Any} = Any[]
end
function RSJ.respond(provider::RuntimeSettingsFixtureProvider,request::RSJ.ModelRequest,context::ExecutionContext)
    kind=occursin("Summarize",request.instructions) ? :summary : :reply
    push!(provider.calls,kind)
    observed=isdefined(RSJ.HTTPTransport,:http_idle_timeout_ms) ? RSJ.HTTPTransport.http_idle_timeout_ms() : nothing
    push!(provider.observed_idle,observed)
    response=if kind==:summary&&provider.mode==:cancel_summary
        RSJ.cancel!(context)
        Answer("Must not commit cancelled summary")
    elseif kind==:summary&&provider.mode==:deny_summary
        Failure("Fixture summary denied")
    else
        Answer(kind==:summary ? "Fixture condensed history" : "Fixture reply")
    end
    response
end
function runtime_settings_app(directory;mode=:success)
    provider=RuntimeSettingsFixtureProvider(;mode)
    kernel=Kernel(provider)
    session=Session(kernel;working_directory=directory,compaction=RSJ.CompactionSettings(reserve_tokens=100,keep_recent_tokens=0),
        messages=[Message(:user,repeat("older context ",500)),Message(:assistant,"prior result")])
    app=RST.App(session;settings_dir=directory,registry=RSJ.ProviderRegistry())
    (;app,provider,kernel)
end
function runtime_settings_close(fixture)
    RST.finish_shutdown!(fixture.app)
    close(fixture.kernel)
    nothing
end
@testset "Runtime settings actual consumers" begin
@testset "Auto-compact setting reaches actual pre-request provider and survives restore" begin
    for enabled in (true,false)
        mktempdir() do directory
            fixture=runtime_settings_app(directory)
            RST.set_setting_value!(fixture.app,"autocompact",string(enabled))
            @test RSJ.session_compaction_settings(fixture.app.session).enabled==enabled
            @test run_turn!(fixture.app.session,"next prompt").ok
            @test fixture.provider.calls==(enabled ? [:summary,:reply] : [:reply])
            @test isnothing(RSJ.compaction_snapshot(fixture.app.session))==!enabled
            runtime_settings_close(fixture)
            restored=runtime_settings_app(directory)
            @test RSJ.session_compaction_settings(restored.app.session).enabled==enabled
            @test run_turn!(restored.app.session,"restored prompt").ok
            @test restored.provider.calls==(enabled ? [:summary,:reply] : [:reply])
            runtime_settings_close(restored)
        end
    end
end
@testset "Auto-compact cancellation cannot start the next model call" begin
    mktempdir() do directory
        fixture=runtime_settings_app(directory;mode=:cancel_summary)
        RST.set_setting_value!(fixture.app,"autocompact","true")
        result=run_turn!(fixture.app.session,"next prompt")
        @test !result.ok
        @test fixture.provider.calls==[:summary]
        @test isnothing(RSJ.compaction_snapshot(fixture.app.session))
        runtime_settings_close(fixture)
    end
end
@testset "Auto-compact denial does not claim or persist a summary" begin
    mktempdir() do directory
        fixture=runtime_settings_app(directory;mode=:deny_summary)
        @test run_turn!(fixture.app.session,"next prompt").ok
        @test fixture.provider.calls==[:summary,:reply]
        @test isnothing(RSJ.compaction_snapshot(fixture.app.session))
        runtime_settings_close(fixture)
    end
end
@testset "HTTP idle timeout settings reach actual provider request scope" begin
    for (label,milliseconds) in (("30 sec",30000),("1 min",60000),("2 min",120000),("5 min",300000),("disabled",0))
        mktempdir() do directory
            fixture=runtime_settings_app(directory)
            RST.set_setting_value!(fixture.app,"autocompact","false")
            RST.set_setting_value!(fixture.app,"http-idle-timeout",label)
            @test RST.menu_preference(fixture.app,"http-idle-timeout","")==label
            @test run_turn!(fixture.app.session,"next prompt").ok
            @test fixture.provider.observed_idle==[milliseconds]
            runtime_settings_close(fixture)
            restored=runtime_settings_app(directory)
            @test run_turn!(restored.app.session,"restored request").ok
            @test restored.provider.observed_idle==[milliseconds]
            runtime_settings_close(restored)
        end
    end
end

end

@testset "Original source-pinned idle choices and compaction threshold" begin
    source=JSON.parsefile(joinpath(@__DIR__,"fixtures/pi-runtime-settings.json"))
    @test source["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test length(source["sourceHashes"])==513
    @test source["defaultTimeoutMs"]==RSJ.HTTPTransport.DEFAULT_HTTP_IDLE_TIMEOUT_MS
    for entry in source["fixtures"]
        if entry["kind"]=="http-idle-timeout"
            mktempdir() do directory
                fixture=runtime_settings_app(directory)
                RST.set_setting_value!(fixture.app,"http-idle-timeout",entry["label"])
                @test component(fixture.kernel,:http_idle_timeout)==entry["value"]
                @test entry["value"]==entry["headersTimeout"]==entry["bodyTimeout"]
                runtime_settings_close(fixture)
            end
        else
            for threshold in entry["thresholds"]
                @test threshold["compact"]==(entry["enabled"]&&threshold["tokens"]>900)
            end
        end
    end
end

@testset "Rejected settings effects restore persisted and actual request policies" begin
    mktempdir() do directory
        fixture=runtime_settings_app(directory)
        RST.set_setting_value!(fixture.app,"autocompact","false")
        RST.set_setting_value!(fixture.app,"http-idle-timeout","1 min")
        install!(fixture.kernel,ComponentSpec(:terminal_setting_changed,
            (name,value,app)->(ok=value!="disabled"&&!(name=="autocompact"&&value=="true"),reason="fixture rejection")))
        RST.set_setting_value!(fixture.app,"http-idle-timeout","disabled")
        RST.set_setting_value!(fixture.app,"autocompact","true")
        @test component(fixture.kernel,:http_idle_timeout)==60000
        @test !RSJ.session_compaction_settings(fixture.app.session).enabled
        @test RST.menu_preference(fixture.app,"http-idle-timeout","")=="1 min"
        @test run_turn!(fixture.app.session,"after rollback").ok
        @test fixture.provider.calls==[:reply]
        @test fixture.provider.observed_idle==[60000]
        runtime_settings_close(fixture)
        restored=runtime_settings_app(directory)
        @test component(restored.kernel,:http_idle_timeout)==60000
        @test !RSJ.session_compaction_settings(restored.app.session).enabled
        runtime_settings_close(restored)
    end
end
