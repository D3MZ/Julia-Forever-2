using Test, JuliaForever2, Tachikoma, CommonMark, JSON, SHA
const SRJ=JuliaForever2
const SRT=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
for (name,file) in ((:SessionTimeline,"session_timeline.jl"),(:TimelineContextProjection,"session_context.jl"),(:TimelineDisplayOverlay,"session_display.jl"))
    isdefined(SRJ,name) || Base.include(SRJ,joinpath(@__DIR__,"..","src/core",file))
end
isdefined(SRT,:SessionDisplayState) || Base.include(SRT,joinpath(@__DIR__,"..","ext/terminal/session_display_render.jl"))
const SESSION_RENDER_CAPTURE=read(joinpath(@__DIR__,"fixtures","pi-session-render.json"),String)
session_render_oracle()=isempty(get(ENV,"JF2_SESSION_RENDER_ORACLE","")) ? JSON.parse(SESSION_RENDER_CAPTURE) : JSON.parsefile(ENV["JF2_SESSION_RENDER_ORACLE"])
function session_render_fixture(oracle,frame)
    fixture=only(filter(case->case["name"]==frame["fixture"],oracle["cases"]))
    settings=frame["state"]
    state=SRT.SessionDisplayState(;show_usage=get(fixture,"showUsage",false),retry_attempt=get(fixture,"retryAttempt",0))
    SRT.session_display_transition!(state,settings["expanded"] ? :expand_all : :collapse_all)
    SRT.session_display_transition!(state,settings["hideThinking"] ? :hide_thinking : :show_thinking)
    state.output_padding=settings["padding"]
    projection=SRJ.timeline_display_projection(fixture["entries"];mode=Symbol(get(fixture,"mode","pi")))
    custom=get(fixture,"customRenderer",false) ? (item,width,state)->SRT.session_display_text_rows("Custom "*item.payload["customType"],width,0) : nothing
    SRT.session_display_lines(projection,frame["width"];state,custom_entry_renderer=custom)
end
session_render_color(::Tachikoma.NoColor)=(0,-1)
session_render_color(c::Tachikoma.ColorRGB)=(50331648,Int(c.r)*65536+Int(c.g)*256+Int(c.b))
session_render_color(c::Tachikoma.Color256)=(16777216,Int(c.code))
function session_render_digest(rows,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(rows))))
    for (index,row) in enumerate(rows)
        SRT.draw_session_display_line!(buffer,1,index,width,row)
    end
    canonical=sprint() do io
        for index in eachindex(rows),column in 1:width
            cell=buffer.content[(index-1)*width+column]
            style=cell.style
            values=(string(cell.char,cell.suffix),session_render_color(style.fg)...,session_render_color(style.bg)...,
                Int(style.bold),Int(style.dim),Int(style.italic),Int(style.underline),Int(style.strikethrough))
            print(io,join(values,'\0'),'\n')
        end
    end
    bytes2hex(SHA.sha256(canonical))
end
@testset "Original Pi transcript cells and native transition inputs" begin
    oracle=session_render_oracle()
    @test oracle["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    matched=0
    for frame in oracle["snapshots"]
        @testset "$(frame["id"]) @ $(frame["width"])" begin
            rows=session_render_fixture(oracle,frame)
            @test length(rows)==frame["rowCount"]
            @test session_render_digest(rows,frame["width"])==frame["cellsSha256"]
            matched+=1
        end
    end
    @test matched==length(oracle["snapshots"])
end
@testset "Display transitions and unsupported content cannot mutate context" begin
    state=SRT.SessionDisplayState()
    @test SRT.session_display_transition!(state,:toggle,"item")===state
    @test "item" in state.expanded
    SRT.session_display_transition!(state,:toggle,"item")
    @test isempty(state.expanded)
    SRT.session_display_transition!(state,:expand,"item")
    @test SRT.session_display_expanded(state,"item")
    SRT.session_display_transition!(state,:collapse,"item")
    @test !SRT.session_display_expanded(state,"item")
    @test_throws ErrorException SRT.session_display_transition!(state,:execute,"item")
    @test SRT.session_display_safe("safe\e[31mRED\e[0m\e]52;c;ZXZpbA==\a\x01") == "safeRED�"
    fixture=only(filter(x->x["name"]=="rich-text-tools",session_render_oracle()["cases"]))
    timeline=SRJ.timeline_from_rows([Dict("type"=>"session","version"=>3,"id"=>"display-safe","cwd"=>pwd(),"timestamp"=>"2026-11-01T21:00:00.123Z");fixture["entries"]])
    before=SRJ.timeline_entries(timeline)
    context=SRJ.timeline_context(timeline)
    projection=SRJ.timeline_display_projection(timeline)
    state.expand_all=true
    rows=SRT.session_display_lines(projection,30;state)
    @test !isempty(rows)
    @test SRJ.timeline_entries(timeline)==before
    @test SRJ.timeline_context(timeline)==context
    @test_throws ErrorException SRT.session_display_lines(projection,0;state)
    state.output_padding=8
    @test_throws ErrorException SRT.session_display_lines(projection,30;state)
end

@testset "Malformed and unimplemented blocks are visible without executing terminal controls" begin
    for content in ([Dict("type"=>"audio","data"=>"opaque")],[42],[Dict("type"=>"text","text"=>42)])
        timeline=SRJ.SessionTimeline(pwd())
        SRJ.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>content))
        original=SRJ.timeline_entries(timeline)
        rows=SRT.session_display_lines(SRJ.timeline_display_projection(timeline),60)
        text=join(span.content for row in rows for span in row)
        @test occursin("Unsupported",text)
        @test SRJ.timeline_entries(timeline)==original
    end
    timeline=SRJ.SessionTimeline(pwd())
    original=Message(:assistant,"original",:code)
    id=SRJ.timeline_append_message!(timeline,SRJ.timeline_archive_message(original))
    marker=Dict("format"=>"JuliaForever2.context-edit.v1","display"=>true)
    SRJ.timeline_append!(timeline,Dict("type"=>"context_edit","targetId"=>id,"replacement"=>Dict("content"=>"actual edit"),"jf2"=>marker))
    rows=SRT.session_display_lines(SRJ.timeline_display_projection(timeline),60)
    @test occursin("actual edit",join(span.content for row in rows for span in row))
    @test SRJ.timeline_entry(timeline,id)["message"]["content"][1]["text"]=="original"
end

@testset "Per-item collapse remains effective after a global expand transition" begin
    state=SRT.SessionDisplayState()
    SRT.session_display_transition!(state,:expand_all)
    @test SRT.session_display_expanded(state,"summary")
    SRT.session_display_transition!(state,:toggle,"summary")
    @test !SRT.session_display_expanded(state,"summary")
    @test SRT.session_display_expanded(state,"other")
    SRT.session_display_transition!(state,:toggle,"summary")
    @test SRT.session_display_expanded(state,"summary")
    SRT.session_display_transition!(state,:collapse_all)
    @test !SRT.session_display_expanded(state,"summary")
    @test isempty(state.expanded) && isempty(state.collapsed)
end
