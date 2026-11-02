using Test, JSON, JuliaForever2, Tachikoma, CommonMark
const ImageLayoutTerminal = Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const IMAGE_LAYOUT_CASE = first(JSON.parsefile(joinpath(@__DIR__,"fixtures","session_images","png-cases.json")))
image_layout_block(;mime="image/png",data=IMAGE_LAYOUT_CASE["data"]) = Dict{String,Any}("type"=>"image","mimeType"=>mime,"data"=>data)
image_layout_text(rows) = join((join(span.content for span in row) for row in rows),"\n")
function image_layout_projection(;name="read",blocks=[image_layout_block()],text="Fixture result",second=false)
    timeline = JuliaForever2.SessionTimeline(pwd())
    JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"Inspect image"))
    for id in (second ? ("one","two") : ("one",))
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>[Dict("type"=>"toolCall","id"=>id,"name"=>name,"arguments"=>Dict("path"=>"not-opened.png","command"=>"must-not-execute"))]))
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"toolResult","toolCallId"=>id,"toolName"=>name,"content"=>[Dict("type"=>"text","text"=>text);blocks],"isError"=>false))
    end
    timeline,JuliaForever2.timeline_display_projection(timeline)
end
function image_layout_frame(width=40,height=40)
    backend=Tachikoma.TestBackend(width,height)
    Tachikoma.Frame(backend.buf,backend.buf.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
end
@testset "Typed transcript image layout retains source and actual reservations" begin
    T=ImageLayoutTerminal
    timeline,projection=image_layout_projection(;second=true)
    before=JuliaForever2.timeline_entries(timeline)
    context=JuliaForever2.timeline_context(timeline)
    options=T.SessionImageOptions(;max_width_cells=12)
    registry=T.SessionBuiltinToolRenderers()
    plan=T.session_display_plan(projection,40;options,tool_renderers=registry,protocol=:kitty,cell_pixels=(w=9,h=18))
    @test plan isa T.SessionDisplayPlan
    @test length(plan.placements)==2
    @test all(p->p.image.state==:raster,plan.placements)
    @test all(p->p.column==1,plan.placements)
    @test map(p->p.tool_call_id,plan.placements)==["one","two"]
    @test plan.placements[2].row>plan.placements[1].row+plan.placements[1].image.rows
    @test !occursin("Image:",image_layout_text(plan.rows))
    @test !occursin("Unsupported image",image_layout_text(plan.rows))
    @test !occursin("Fixture result",image_layout_text(plan.rows)) # read collapsed, images are separate children
    for p in plan.placements
        @test isempty(strip(image_layout_text(plan.rows[p.row-1:p.row+p.image.rows-1])))
    end
    @test JuliaForever2.timeline_entries(timeline)==before
    @test JuliaForever2.timeline_context(timeline)==context
    @test JuliaForever2.timeline_display_records(projection).tools[1].result["content"][2]["type"]=="image"
    expanded=T.SessionDisplayState(;expand_all=true)
    open_plan=T.session_display_plan(projection,40;state=expanded,options,tool_renderers=registry,protocol=:kitty)
    @test occursin("Fixture result",image_layout_text(open_plan.rows))
    @test length(open_plan.placements)==2
    for protocol in (:none,:iterm2)
        fallback=T.session_display_plan(projection,40;state=expanded,options,tool_renderers=registry,protocol)
        @test isempty(fallback.placements)
        @test occursin("[Image: [image/png] 2x2]",image_layout_text(fallback.rows))
    end
    hidden_options=T.SessionImageOptions(;show_images=false)
    hidden=T.session_display_plan(projection,40;state=expanded,options=hidden_options,tool_renderers=registry,protocol=:kitty)
    @test isempty(hidden.placements)
    @test occursin("[Image: [image/png] 2x2]",image_layout_text(hidden.rows))
    collapsed_hidden=T.session_display_plan(projection,40;options=hidden_options,tool_renderers=registry,protocol=:kitty)
    @test !occursin("Image:",image_layout_text(collapsed_hidden.rows))
    _,unsupported=image_layout_projection(;blocks=[image_layout_block(;mime="image/jpeg")])
    fallback=T.session_display_plan(unsupported,40;options,tool_renderers=registry,protocol=:kitty)
    @test isempty(fallback.placements)
    @test occursin("[Image: [image/jpeg]]",image_layout_text(fallback.rows))
    _,bad=image_layout_projection(;blocks=[image_layout_block(;data="invalid")])
    fallback=T.session_display_plan(bad,40;options,tool_renderers=registry,protocol=:kitty)
    @test isempty(fallback.placements)
    @test occursin("[Image: [image/png]]",image_layout_text(fallback.rows))
    _,plain=image_layout_projection(;blocks=Dict{String,Any}[])
    plainplan=T.session_display_plan(plain,40;tool_renderers=registry)
    @test plainplan.rows==T.session_display_lines(plain,40;tool_renderers=registry)
    @test isempty(plainplan.placements)
end
@testset "Pi omits user and assistant image payloads without losing archive" begin
    T=ImageLayoutTerminal
    for role in ("user","assistant")
        timeline=JuliaForever2.SessionTimeline(pwd())
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>role,"content"=>[image_layout_block()]))
        original=JuliaForever2.timeline_entries(timeline)
        plan=T.session_display_plan(JuliaForever2.timeline_display_projection(timeline),40;protocol=:kitty)
        @test isempty(plan.rows)
        @test isempty(plan.placements)
        @test JuliaForever2.timeline_entries(timeline)==original
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>role,"content"=>[Dict("type"=>"text","text"=>"Visible text"),image_layout_block()]))
        rows=T.session_display_plan(JuliaForever2.timeline_display_projection(timeline),40;protocol=:kitty).rows
        @test occursin("Visible text",image_layout_text(rows))
        @test !occursin("Image",image_layout_text(rows))
        @test !occursin("Unsupported",image_layout_text(rows))
    end
end
@testset "Real transcript Frame draws, viewport crop and explicit invalidation" begin
    T=ImageLayoutTerminal
    original=(protocol=Tachikoma.GRAPHICS_PROTOCOL[],cell=Tachikoma.CELL_PX[],px=Tachikoma.TEXT_AREA_PX[],cells=Tachikoma.TEXT_AREA_CELLS[],sixel=Tachikoma.SIXEL_AREA_PX[],scale=Tachikoma.SIXEL_SCALE[],shm=Tachikoma._KITTY_SHM_AVAILABLE[])
    Tachikoma.CELL_PX[]=(w=9,h=18)
    Tachikoma.TEXT_AREA_PX[]=(w=0,h=0)
    Tachikoma.TEXT_AREA_CELLS[]=(w=0,h=0)
    Tachikoma.SIXEL_AREA_PX[]=(w=0,h=0)
    Tachikoma.SIXEL_SCALE[]=(w=1.0,h=1.0)
    Tachikoma._KITTY_SHM_AVAILABLE[]=false
    _,projection=image_layout_projection()
    options=T.SessionImageOptions(;max_width_cells=12)
    for backend_protocol in (Tachikoma.gfx_kitty,Tachikoma.gfx_sixel)
        Tachikoma.GRAPHICS_PROTOCOL[]=backend_protocol
        plan=T.session_display_plan(projection,40;options,tool_renderers=T.SessionBuiltinToolRenderers())
        p=only(plan.placements)
        frame=image_layout_frame(44,44)
        viewport=Tachikoma.Rect(3,2,40,40)
        outcomes=T.draw_session_images!(plan,frame,viewport)
        @test only(outcomes).status==:rendered
        @test only(outcomes).tool_call_id=="one"
        @test length(frame.gfx_regions)==1 && length(frame.pixel_snapshots)==1
        @test only(frame.pixel_snapshots)[1:2]==(p.row+1,3)
        @test only(frame.pixel_snapshots)[3][1,1]==Tachikoma.ColorRGBA(255,0,0,255)
        cropped=image_layout_frame()
        hidden=fld(p.image.rows,2)
        outcomes=T.draw_session_images!(plan,cropped,Tachikoma.Rect(1,1,40,2);first_row=p.row+hidden)
        @test only(outcomes).status==:rendered
        @test only(cropped.pixel_snapshots)[1:2]==(1,1)
        @test only(cropped.pixel_snapshots)[3][1,1].b==0xff
        offscreen=image_layout_frame()
        @test isempty(T.draw_session_images!(plan,offscreen,Tachikoma.Rect(1,1,40,2);first_row=p.row+p.image.rows))
        @test isempty(offscreen.gfx_regions)
        short=image_layout_frame()
        @test only(T.draw_session_images!(plan,short,Tachikoma.Rect(1,1,40,1);first_row=p.row)).status==:rendered
        @test size(only(short.pixel_snapshots)[3],1)==18
        @test_throws ErrorException T.draw_session_images!(plan,image_layout_frame(),Tachikoma.Rect(1,1,40,1);first_row=0)
        @test_throws ErrorException T.draw_session_images!(plan,image_layout_frame(),Tachikoma.Rect(2,1,40,1))
        for viewport2 in (Tachikoma.Rect(1,1,39,30),Tachikoma.Rect(1,1,40,30))
            stale=image_layout_frame()
            hidden_options=T.SessionImageOptions(;show_images=false)
            @test only(T.draw_session_images!(plan,stale,viewport2;options=hidden_options)).status==:reprepare
            @test isempty(stale.gfx_regions)
        end
        Tachikoma.GRAPHICS_PROTOCOL[]=Tachikoma.gfx_none
        stale=image_layout_frame()
        @test only(T.draw_session_images!(plan,stale,Tachikoma.Rect(1,1,40,40))).status==:reprepare
        @test isempty(stale.gfx_regions)
        Tachikoma.GRAPHICS_PROTOCOL[]=backend_protocol
        Tachikoma.CELL_PX[]=(w=10,h=20)
        @test only(T.draw_session_images!(plan,image_layout_frame(),Tachikoma.Rect(1,1,40,40))).status==:reprepare
        Tachikoma.CELL_PX[]=(w=9,h=18)
        hidden=T.session_display_plan(projection,40;options=T.SessionImageOptions(;show_images=false),tool_renderers=T.SessionBuiltinToolRenderers())
        hidden_frame=image_layout_frame()
        @test isempty(T.draw_session_images!(hidden,hidden_frame,Tachikoma.Rect(1,1,40,40)))
        @test isempty(hidden_frame.gfx_regions)
    end
    Tachikoma.GRAPHICS_PROTOCOL[]=original.protocol
    Tachikoma.CELL_PX[]=original.cell
    Tachikoma.TEXT_AREA_PX[]=original.px
    Tachikoma.TEXT_AREA_CELLS[]=original.cells
    Tachikoma.SIXEL_AREA_PX[]=original.sixel
    Tachikoma.SIXEL_SCALE[]=original.scale
    Tachikoma._KITTY_SHM_AVAILABLE[]=original.shm
end

@testset "Transcript plans bound total retained decoded pixels before allocation" begin
    T = ImageLayoutTerminal
    timeline, projection = image_layout_projection(;blocks=fill(image_layout_block(),3),second=true)
    original = JuliaForever2.timeline_entries(timeline)
    options = T.SessionImageOptions(;limits=T.SessionImageLimits(;plan_pixels=8))
    plan = T.session_display_plan(projection,80;options,protocol=:kitty)
    @test length(plan.placements)==2
    @test sum(length(item.image.pixels) for item in plan.placements)==8
    @test occursin("display pixel budget exhausted",image_layout_text(plan.rows))
    @test JuliaForever2.timeline_entries(timeline)==original
    empty = T.session_display_plan(projection,80;options=T.SessionImageOptions(;limits=T.SessionImageLimits(;plan_pixels=0)),protocol=:kitty)
    @test isempty(empty.placements)
    @test occursin("display pixel budget exhausted",image_layout_text(empty.rows))
    @test_throws ErrorException T.session_display_plan(projection,80;options=T.SessionImageOptions(;limits=T.SessionImageLimits(;plan_pixels=-1)))
    @test_throws ErrorException T.session_image_prepare(image_layout_block(),80;pixel_budget=-1)
    # Even malicious invalid encoded input cannot bypass the budget into a decoder.
    invalid = T.session_image_prepare(image_layout_block(;data="not-base64"),80;protocol=:kitty,pixel_budget=0)
    @test invalid.state==:fallback
    @test isnothing(invalid.pixels)
    malformed = T.SessionImagePresentation(:raster,:decoded,:kitty,1,1,"",nothing,T.SessionImageLimits())
    @test_throws ErrorException T.render_session_image!(malformed,Tachikoma.Rect(1,1,1,1),image_layout_frame())
end
