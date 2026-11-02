using Test, JSON, Base64, Tachikoma, CommonMark, JuliaForever2
const ImageAdapterTerminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const IMAGE_FIXTURES = joinpath(@__DIR__,"fixtures","session_images")
const IMAGE_CASES = JSON.parse(read(joinpath(IMAGE_FIXTURES,"png-cases.json"),String))
const IMAGE_INVALID = JSON.parse(read(joinpath(IMAGE_FIXTURES,"invalid-png-cases.json"),String))
image_adapter_test_block(data;mime="image/png") = Dict{String,Any}("type"=>"image","mimeType"=>mime,"data"=>data)

@testset "Bounded PNG decoding, independent zlib fixtures" begin
    for item in IMAGE_CASES
        block = image_adapter_test_block(item["data"])
        before = deepcopy(block)
        result = ImageAdapterTerminal.session_image_prepare(block,80;protocol=:kitty,cell_pixels=(w=9,h=18))
        @test result.state == :raster
        @test block == before
        @test size(result.pixels) == (2,2)
        for y in 1:2, x in 1:2
            expected = item["pixels"][y][x]
            actual = result.pixels[y,x]
            @test [Int(actual.r),Int(actual.g),Int(actual.b),Int(actual.a)] == expected
        end
    end
    for (name,data) in IMAGE_INVALID
        @test ImageAdapterTerminal.session_image_prepare(image_adapter_test_block(data),80;protocol=:kitty).state == :fallback
    end
    for data in ("", "file:///etc/passwd", "https://example.invalid/a.png", "\e[2J", "not_base64!", repeat("A",40))
        @test ImageAdapterTerminal.session_image_prepare(image_adapter_test_block(data),80;protocol=:kitty).state == :fallback
    end
    valid = image_adapter_test_block(first(IMAGE_CASES)["data"])
    limited = ImageAdapterTerminal.SessionImageOptions(;limits=ImageAdapterTerminal.SessionImageLimits(;encoded_bytes=10))
    @test ImageAdapterTerminal.session_image_prepare(valid,80;protocol=:kitty,options=limited).state == :fallback
    limited = ImageAdapterTerminal.SessionImageOptions(;limits=ImageAdapterTerminal.SessionImageLimits(;decoded_bytes=10))
    @test ImageAdapterTerminal.session_image_prepare(valid,80;protocol=:kitty,options=limited).state == :fallback
    limited = ImageAdapterTerminal.SessionImageOptions(;limits=ImageAdapterTerminal.SessionImageLimits(;pixels=3))
    @test ImageAdapterTerminal.session_image_prepare(valid,80;protocol=:kitty,options=limited).state == :fallback
end

@testset "Pinned Pi exact cell geometry and inert fallback" begin
    oracle = JSON.parse(read(joinpath(IMAGE_FIXTURES,"pi-image-oracle.json"),String))
    @test oracle["revision"] == "2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test oracle["source_sha256"] == "edb88db602610de4737505609b09bf1aedc3881dde5d6d7c2345b7c7f2bacc57"
    for row in oracle["rows"]
        actual = ImageAdapterTerminal.session_image_cell_size(row["w"],row["h"],row["mw"],row["mh"],9,18;optimize=row["optimize"])
        @test actual.columns == row["expected"]["columns"]
        @test actual.rows == row["expected"]["rows"]
    end
    block = image_adapter_test_block(first(IMAGE_CASES)["data"])
    @test ImageAdapterTerminal.session_image_fallback(block) == oracle["fallback"][1]
    @test ImageAdapterTerminal.session_image_fallback(image_adapter_test_block("";mime="image/jpeg")) == oracle["fallback"][2]
    @test ImageAdapterTerminal.session_image_fallback(image_adapter_test_block("";mime="image/png\e[2J")) == "[Image: [image/unknown]]"
end

@testset "Image visibility and protocol transitions preserve raw content" begin
    block = image_adapter_test_block(first(IMAGE_CASES)["data"])
    before = deepcopy(block)
    for context in (:user,:assistant)
        omitted = ImageAdapterTerminal.session_image_prepare(block,80;context,protocol=:kitty)
        @test omitted.state == :omitted
        @test omitted.rows == 0 && isnothing(omitted.pixels)
    end
    for protocol in (:kitty,:sixel)
        visible = ImageAdapterTerminal.session_image_prepare(block,80;protocol)
        @test visible.state == :raster
        hidden = ImageAdapterTerminal.session_image_prepare(block,80;protocol,options=ImageAdapterTerminal.SessionImageOptions(;show_images=false))
        @test hidden.state == :fallback && hidden.reason == :hidden
        @test isnothing(hidden.pixels)
        shown = ImageAdapterTerminal.session_image_prepare(block,80;protocol)
        @test shown.state == :raster
        @test shown.pixels == visible.pixels
    end
    unsupported = ImageAdapterTerminal.session_image_prepare(block,80;protocol=:none)
    @test unsupported.state == :fallback && unsupported.reason == :unsupported_terminal
    @test ImageAdapterTerminal.session_image_prepare(block,80;protocol=:iterm2).reason == :unsupported_protocol
    for mime in ("image/jpeg","image/webp","image/gif","image/svg+xml")
        @test ImageAdapterTerminal.session_image_prepare(image_adapter_test_block(block["data"];mime),80;protocol=:kitty).reason == :unsupported_mime
    end
    @test block == before
end

function image_adapter_test_frame(width=80,height=40)
    backend = Tachikoma.TestBackend(width,height)
    Tachikoma.Frame(backend.buf,backend.buf.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
end

@testset "Actual Kitty/Sixel frame placements, cropping, invalidation" begin
    original = (protocol=Tachikoma.GRAPHICS_PROTOCOL[],cell=Tachikoma.CELL_PX[],px=Tachikoma.TEXT_AREA_PX[],cells=Tachikoma.TEXT_AREA_CELLS[],sixel=Tachikoma.SIXEL_AREA_PX[],scale=Tachikoma.SIXEL_SCALE[],shm=Tachikoma._KITTY_SHM_AVAILABLE[])
    Tachikoma.CELL_PX[] = (w=9,h=18)
    Tachikoma.TEXT_AREA_PX[] = (w=0,h=0)
    Tachikoma.TEXT_AREA_CELLS[] = (w=0,h=0)
    Tachikoma.SIXEL_AREA_PX[] = (w=0,h=0)
    Tachikoma.SIXEL_SCALE[] = (w=1.0,h=1.0)
    Tachikoma._KITTY_SHM_AVAILABLE[] = false
    block = image_adapter_test_block(first(IMAGE_CASES)["data"])
    for (protocol,backend_protocol,format) in ((:kitty,Tachikoma.gfx_kitty,Tachikoma.gfx_fmt_kitty),(:sixel,Tachikoma.gfx_sixel,Tachikoma.gfx_fmt_sixel))
        Tachikoma.GRAPHICS_PROTOCOL[] = backend_protocol
        prepared = ImageAdapterTerminal.session_image_prepare(block,20;options=ImageAdapterTerminal.SessionImageOptions(;max_width_cells=12))
        frame = image_adapter_test_frame()
        placement = Tachikoma.Rect(3,4,prepared.columns,prepared.rows)
        @test ImageAdapterTerminal.render_session_image!(prepared,placement,frame) == :rendered
        @test length(frame.gfx_regions) == 1
        @test frame.gfx_regions[1].format == format
        @test !isempty(frame.gfx_regions[1].data)
        @test length(frame.pixel_snapshots) == 1
        y,x,pixels = only(frame.pixel_snapshots)
        @test (y,x) == (4,3)
        @test pixels[1,1] == Tachikoma.ColorRGBA(255,0,0,255)
        @test pixels[end,1] == Tachikoma.ColorRGBA(0,0,255,255)
        crop = image_adapter_test_frame()
        hidden = fld(prepared.rows,2)
        visible = prepared.rows-hidden
        @test ImageAdapterTerminal.render_session_image!(prepared,Tachikoma.Rect(1,1,prepared.columns,visible),crop;hidden_rows=hidden) == :rendered
        @test length(crop.pixel_snapshots) == 1
        @test only(crop.pixel_snapshots)[3][1,1].b == 0xff
        @test_throws ErrorException ImageAdapterTerminal.render_session_image!(prepared,Tachikoma.Rect(80,40,prepared.columns,prepared.rows),image_adapter_test_frame())
        Tachikoma.GRAPHICS_PROTOCOL[] = Tachikoma.gfx_none
        changed = image_adapter_test_frame()
        @test ImageAdapterTerminal.render_session_image!(prepared,placement,changed) == :capability_changed
        @test isempty(changed.gfx_regions)
        @test isempty(changed.pixel_snapshots)
        hidden_image = ImageAdapterTerminal.session_image_prepare(block,20;options=ImageAdapterTerminal.SessionImageOptions(;show_images=false))
        @test ImageAdapterTerminal.render_session_image!(hidden_image,placement,changed) == :fallback
        @test isempty(changed.gfx_regions)
        Tachikoma.GRAPHICS_PROTOCOL[] = backend_protocol
        restrictive = ImageAdapterTerminal.session_image_prepare(block,20;options=ImageAdapterTerminal.SessionImageOptions(;limits=ImageAdapterTerminal.SessionImageLimits(;render_pixels=1)))
        @test_throws ErrorException ImageAdapterTerminal.render_session_image!(restrictive,Tachikoma.Rect(1,1,restrictive.columns,restrictive.rows),image_adapter_test_frame())
    end
    Tachikoma.GRAPHICS_PROTOCOL[] = original.protocol
    Tachikoma.CELL_PX[] = original.cell
    Tachikoma.TEXT_AREA_PX[] = original.px
    Tachikoma.TEXT_AREA_CELLS[] = original.cells
    Tachikoma.SIXEL_AREA_PX[] = original.sixel
    Tachikoma.SIXEL_SCALE[] = original.scale
    Tachikoma._KITTY_SHM_AVAILABLE[] = original.shm
end
