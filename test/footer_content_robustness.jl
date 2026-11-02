using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module FooterContentRobustnessTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function drain!(app)
    timedwait(20;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
@testset "Source token estimator and safe native legacy assistant text" begin
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-footer-content.json"))
    @test fixture["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    if isdir(reference)
        mktempdir() do dir
            path=joinpath(dir,"original.json")
            run(`node $(joinpath(@__DIR__,"differential","pi_footer_content_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
            @test JSON.parsefile(path)==fixture
        end
    end
    compatibility=Dict("empty-string"=>0.0,"legacy-string"=>3.0,"legacy-unicode"=>2.0,"invalid-null"=>0.0,"invalid-number"=>0.0,"invalid-object"=>0.0,"invalid-blocks"=>0.0,"invalid-text"=>0.0)
    for case in fixture["cases"]
        expected=case["nativeTextFallback"] ? compatibility[case["id"]] : case["original"]["tokens"]
        @test T.footer_control_estimate(case["message"])==expected
    end
end

@testset "Actual imported assistant content draws without altering archive payloads" begin
    frames=[]
    for (index,content) in enumerate(Any["plain text","界👩‍💻é","",Any[],[Dict("type"=>"text","text"=>"rich text"),Dict("type"=>"text","text"=>"more text")]])
        mktempdir() do directory
            kernel=JF.Kernel();app=T.App(JF.Session(kernel;working_directory=directory);settings_dir=joinpath(directory,"config"),theme_fallback="dark")
            timeline=JF.SessionTimeline(directory)
            JF.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"Imported archive"))
            JF.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>content))
            original=JF.timeline_entries(timeline);path=joinpath(directory,"legacy.jsonl");write(path,JF.timeline_export_jsonl(timeline))
            original_bytes=read(path);old=app.session
            T.session_action!(app,:import,path)
            @test drain!(app)==:ok
            @test app.session!==old && isopen(app.session)
            @test JF.timeline_entries(app.archive.timeline)==original
            area=Tachikoma.Rect(1,1,60,24);app.area=area;buffer=Tachikoma.Buffer(area)
            frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
            @test_nowarn Tachikoma.view(app,frame)
            @test read(path)==original_bytes
            @test JF.timeline_entries(app.archive.timeline)==original
            rows=T.startup_buffer_rows(buffer,60,24)
            plain=join(join(span.content for span in row) for row in rows)
            content isa String && !isempty(content) && @test occursin(content,plain)
            ansi=[sprint(io->(foreach(span->(Tachikoma.write_style(io,span.style);print(io,span.content)),line);print(io,"\e[0m"))) for line in rows]
            push!(frames,(;id="imported-assistant.$index",width=60,terminalAnsiLines=ansi))
            T.finish_shutdown!(app);close(kernel)
        end
    end
    output=get(ENV,"FOOTER_CONTENT_EVIDENCE","")
    isempty(output)||write(output,JSON.json((;snapshots=frames)))
end
end
