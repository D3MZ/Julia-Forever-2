using Test, JSON, JuliaForever2, Tachikoma, CommonMark
const ImageHostTerminal = Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function image_host_app(directory)
    calls=Ref(0)
    transport=(args...)->(calls[]+=1;error("Unexpected external call in image display test"))
    provider=JuliaForever2.OpenAIProvider(directory,transport,transport;model="fixture",reasoning="low")
    app=ImageHostTerminal.App(Session(JuliaForever2.default_kernel(provider));settings_dir=directory,registry=JuliaForever2.ProviderRegistry())
    (app,calls)
end
function image_host_capture(name,frame)
    root=get(ENV,"IMAGE_LAYOUT_CAPTURE","")
    if !isempty(root)
        w,h=frame.area.width,frame.area.height
        rows=[sprint() do io
            for col in 1:w
                cell=frame.buffer.content[(row-1)*w+col]
                print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,cell.char,cell.suffix)
            end
            print(io,"\e[0m")
        end for row in 1:h]
        images=[Dict("y"=>y,"x"=>x,"width"=>size(pixels,2),"height"=>size(pixels,1),
            "pixels"=>[[[Int(c.r),Int(c.g),Int(c.b),Int(c.a)] for c in pixels[row,:]] for row in axes(pixels,1)])
            for (y,x,pixels) in frame.pixel_snapshots]
        mkpath(root)
        write(joinpath(root,name*".json"),JSON.json(Dict("name"=>name,"width"=>w,"height"=>h,"ansiLines"=>rows,"images"=>images,"graphicsCount"=>length(frame.gfx_regions))))
    end
    nothing
end
@testset "Actual App image plan cache, show/hide/resize/capability and crop transitions" begin
    T=ImageHostTerminal
    original=(protocol=Tachikoma.GRAPHICS_PROTOCOL[],cell=Tachikoma.CELL_PX[],px=Tachikoma.TEXT_AREA_PX[],cells=Tachikoma.TEXT_AREA_CELLS[],sixel=Tachikoma.SIXEL_AREA_PX[],scale=Tachikoma.SIXEL_SCALE[],shm=Tachikoma._KITTY_SHM_AVAILABLE[])
    Tachikoma.GRAPHICS_PROTOCOL[]=Tachikoma.gfx_kitty
    Tachikoma.CELL_PX[]=(w=10,h=22)
    Tachikoma.TEXT_AREA_PX[]=(w=0,h=0)
    Tachikoma.TEXT_AREA_CELLS[]=(w=0,h=0)
    Tachikoma.SIXEL_AREA_PX[]=(w=0,h=0)
    Tachikoma.SIXEL_SCALE[]=(w=1.0,h=1.0)
    Tachikoma._KITTY_SHM_AVAILABLE[]=false
    mktempdir() do directory
        app,calls=image_host_app(directory)
        timeline,projection=image_layout_projection()
        app.archive.timeline=timeline
        app.menus.preferences["image-width-cells"]="12"
        original_archive=JuliaForever2.timeline_entries(timeline)
        original_context=JuliaForever2.timeline_context(timeline)
        frame=image_layout_frame(60,30)
        T.default_view!(app,frame)
        image_host_capture("01-kitty-shown",frame)
        plan=app.transcript.display_plan
        @test plan isa T.SessionDisplayPlan
        @test length(plan.placements)==1
        @test length(frame.gfx_regions)==1
        @test T.archive_transcript_lines!(app,60)===plan.rows
        @test app.transcript.display_plan===plan
        @test app.transcript.display_plan.placements[1].image.pixels===plan.placements[1].image.pixels
        app.transcript.display.expand_all=true
        expanded=image_layout_frame(60,30)
        T.default_view!(app,expanded)
        image_host_capture("02-expanded",expanded)
        @test app.transcript.display_plan!==plan
        @test occursin("Fixture result",image_layout_text(app.transcript.display_rows))
        @test length(expanded.gfx_regions)==1
        app.menus.preferences["show-images"]="false"
        hidden=image_layout_frame(60,30)
        T.default_view!(app,hidden)
        image_host_capture("03-hidden",hidden)
        @test isempty(hidden.gfx_regions)
        @test isempty(app.transcript.display_plan.placements)
        @test occursin("[Image: [image/png] 2x2]",image_layout_text(app.transcript.display_rows))
        app.menus.preferences["show-images"]="true"
        shown=image_layout_frame(60,30)
        T.default_view!(app,shown)
        image_host_capture("04-shown-again",shown)
        @test length(shown.gfx_regions)==1
        app.menus.preferences["image-width-cells"]="24"
        wide=image_layout_frame(60,30)
        T.default_view!(app,wide)
        image_host_capture("05-width-24",wide)
        wide_plan=app.transcript.display_plan
        @test only(wide_plan.placements).image.columns==24
        @test only(wide_plan.placements).image.rows>only(plan.placements).image.rows
        small=image_layout_frame(20,12)
        T.default_view!(app,small)
        image_host_capture("06-viewport-cropped",small)
        @test app.transcript.display_plan.width==20
        @test only(app.transcript.display_plan.placements).image.columns<=18
        @test length(small.gfx_regions)==1
        @test only(small.pixel_snapshots)[1]>=1
        @test only(small.pixel_snapshots)[1]+cld(size(only(small.pixel_snapshots)[3],1),22)<=8
        Tachikoma.GRAPHICS_PROTOCOL[]=Tachikoma.gfx_none
        unsupported=image_layout_frame(60,30)
        T.default_view!(app,unsupported)
        image_host_capture("07-no-graphics",unsupported)
        @test isempty(unsupported.gfx_regions)
        @test isempty(app.transcript.display_plan.placements)
        Tachikoma.GRAPHICS_PROTOCOL[]=Tachikoma.gfx_sixel
        sixel=image_layout_frame(60,30)
        T.default_view!(app,sixel)
        image_host_capture("08-sixel",sixel)
        @test length(sixel.gfx_regions)==1
        @test only(sixel.gfx_regions).format==Tachikoma.gfx_fmt_sixel
        @test JuliaForever2.timeline_entries(timeline)==original_archive
        @test JuliaForever2.timeline_context(timeline)==original_context
        @test calls[]==0
        for protocol in (Tachikoma.gfx_kitty,Tachikoma.gfx_sixel)
            Tachikoma.GRAPHICS_PROTOCOL[]=protocol
            sink=IOBuffer()
            terminal=Tachikoma.Terminal(;io=sink,size=(rows=30,cols=60),external_size=true)
            terminal.graphics_protocol=protocol
            app.menus.preferences["show-images"]="true"
            Tachikoma.draw!(frame->T.default_view!(app,frame),terminal)
            shown_bytes=String(take!(sink))
            @test terminal.had_gfx
            @test !isempty(terminal.prev_gfx_bounds)
            @test occursin(protocol==Tachikoma.gfx_kitty ? "\e_G" : "q",shown_bytes)
            app.menus.preferences["show-images"]="false"
            Tachikoma.draw!(frame->T.default_view!(app,frame),terminal)
            hidden_bytes=String(take!(sink))
            @test !terminal.had_gfx
            @test isempty(terminal.prev_gfx_bounds)
            @test occursin(Tachikoma.CLEAR_SCREEN,hidden_bytes)
            @test protocol!=Tachikoma.gfx_kitty || occursin("\e_Ga=d,d=a,q=2\e\\",hidden_bytes)
        end
        app.archive.timeline=nothing
        empty_frame=image_layout_frame(60,30)
        T.default_view!(app,empty_frame)
        image_host_capture("09-no-archive",empty_frame)
        @test isnothing(app.transcript.display_plan)
        @test isempty(app.transcript.display_rows)
        @test isempty(empty_frame.gfx_regions)
        kernel=app.session.kernel
        T.finish_shutdown!(app)
        close(kernel)
    end
    Tachikoma.GRAPHICS_PROTOCOL[]=original.protocol
    Tachikoma.CELL_PX[]=original.cell
    Tachikoma.TEXT_AREA_PX[]=original.px
    Tachikoma.TEXT_AREA_CELLS[]=original.cells
    Tachikoma.SIXEL_AREA_PX[]=original.sixel
    Tachikoma.SIXEL_SCALE[]=original.scale
    Tachikoma._KITTY_SHM_AVAILABLE[]=original.shm
end
