using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module SessionCacheMissTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const FIXTURE=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-cache-misses.json"))
@testset "Original cache accounting versus explicit native unknowns" begin
    @test FIXTURE["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    for case in FIXTURE["cases"]
        entries=case["entries"];before=deepcopy(entries)
        actual=JF.session_cache_misses(entries;read_price=Returns(.3e-6))
        @test length(actual)==length(case["misses"])
        for expected in case["misses"]
            miss=actual[expected["id"]]
            @test miss.tokens==expected["missedTokens"]
            @test miss.estimated_cost≈expected["missedCost"]
            @test miss.idle_ms==expected["idleMs"]
            @test miss.model_changed==expected["modelChanged"]
        end
        @test entries==before
    end
    entries=deepcopy(FIXTURE["cases"][3]["entries"])
    delete!(entries[2]["message"]["usage"],"cacheWrite")
    @test isempty(JF.session_cache_misses(entries))
    entries=deepcopy(FIXTURE["cases"][3]["entries"])
    delete!(entries[2]["message"]["usage"],"cost")
    miss=JF.session_cache_misses(entries)["miss"]
    @test isnothing(miss.estimated_cost)
    rows=T.cache_miss_notice_rows(miss,60)
    text=join(span.content for line in rows for span in line)
    @test occursin("cost unavailable",text)
    @test !occursin("re-billed",text)
    @test isempty(JF.session_cache_misses([Dict("type"=>"message","message"=>nothing)]))
    @test isnothing(JF.cache_prompt_tokens(JF.UsageReport(input_tokens=typemax(Int),cache_read_tokens=1,cache_write_tokens=0)))
    @test isnothing(JF.session_cache_misses(FIXTURE["cases"][3]["entries"];read_price=Returns(-1))["miss"].estimated_cost)
    @test isnothing(JF.session_cache_misses(FIXTURE["cases"][3]["entries"];read_price=Returns(NaN))["miss"].estimated_cost)
    @test isempty(T.cache_miss_notice_rows(JF.SessionCacheMiss(1025,nothing,nothing,false),60))
end
function cache_capture(app,id)
    width=80;height=24;area=Tachikoma.Rect(1,1,width,height);buffer=Tachikoma.Buffer(area)
    app.area=area;frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
    Tachikoma.view(app,frame)
    lines=[sprint(io->(foreach(span->(Tachikoma.write_style(io,span.style);print(io,span.content)),line);print(io,"\e[0m"))) for line in T.startup_buffer_rows(buffer,width,height)]
    (;id,width,terminalAnsiLines=lines)
end
@testset "Actual archive display toggle, resume derivation and immutable context" begin
    frames=[]
    mktempdir() do directory
        kernel=JF.Kernel();app=T.App(JF.Session(kernel;working_directory=directory);settings_dir=directory,theme_fallback="dark")
        timeline=app.archive.timeline
        entries=deepcopy(FIXTURE["cases"][3]["entries"])
        for entry in entries
            delete!(entry["message"],"provider");delete!(entry["message"],"model")
            JF.timeline_append_message!(timeline,entry["message"];id=entry["id"],timestamp=entry["timestamp"])
        end
        before=JF.timeline_export_jsonl(timeline);history=copy(app.session.messages)
        text(rows)=join(span.content for line in rows for span in line)
        @test !occursin("Cache miss",text(T.archive_transcript_lines!(app,60)))
        push!(frames,cache_capture(app,"disabled"))
        T.set_setting_value!(app,"cache-miss-notices","true")
        @test T.menu_preference(app,"cache-miss-notices","")=="true"
        shown=text(T.archive_transcript_lines!(app,60))
        @test occursin("Cache miss after 6m idle",shown)
        @test occursin("50000 prompt tokens not read from cache",replace(shown,r"\s+"=>" "))
        @test !occursin("re-billed",shown)
        @test length(app.transcript.notices.notices)<=1
        push!(frames,cache_capture(app,"enabled"))
        @test JF.timeline_export_jsonl(timeline)==before
        @test app.session.messages==history
        @test isfile(JF.save_timeline!(app.archive.store,timeline))
        old=app.session
        T.session_action!(app,:resume,timeline.identity.id)
        status=timedwait(20;pollint=0.002) do
            while isready(app.queue.channel)
                Tachikoma.update!(app,take!(app.queue.channel))
            end
            !app.busy && all(istaskdone,app.operations.watchers)
        end
        @test status==:ok && app.session!==old
        @test occursin("Cache miss after 6m idle",text(T.archive_transcript_lines!(app,60)))
        @test JF.timeline_export_jsonl(app.archive.timeline)==before
        push!(frames,cache_capture(app,"resumed"))
        T.set_setting_value!(app,"cache-miss-notices","false")
        @test T.menu_preference(app,"cache-miss-notices","")=="false"
        @test !occursin("Cache miss after",text(T.archive_transcript_lines!(app,60)))
        @test JF.timeline_export_jsonl(timeline)==before
        push!(frames,cache_capture(app,"disabled-again"))
        T.finish_shutdown!(app);close(kernel)
    end
    output=get(ENV,"CACHE_MISS_EVIDENCE","")
    isempty(output)||write(output,JSON.json((;snapshots=frames)))
end
end
