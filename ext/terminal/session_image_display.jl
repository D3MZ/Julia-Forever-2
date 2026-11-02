using Base64: base64decode
using CodecZlib: ZlibDecompressorStream

"""Bound accepted encoded images, decoded pixels, and terminal raster allocations independently."""
Base.@kwdef struct SessionImageLimits
    encoded_bytes::Int = 12 * 1024 * 1024
    decoded_bytes::Int = 8 * 1024 * 1024
    dimension::Int = 4096
    pixels::Int = 4 * 1024 * 1024
    render_pixels::Int = 4 * 1024 * 1024
    plan_pixels::Int = 8 * 1024 * 1024
end

"""Image-only display policy; never changes the archived block or model context."""
Base.@kwdef struct SessionImageOptions
    show_images::Bool = true
    max_width_cells::Int = 60
    max_height_cells::Union{Nothing,Int} = nothing
    limits::SessionImageLimits = SessionImageLimits()
end

"""Keep real pixels separate from text fallback and omitted non-tool images."""
struct SessionImagePresentation
    state::Symbol
    reason::Symbol
    protocol::Symbol
    columns::Int
    rows::Int
    fallback::String
    pixels::Union{Nothing,Matrix{Tachikoma.ColorRGBA}}
    limits::SessionImageLimits
end

session_image_protocol() = Tachikoma.graphics_protocol() == Tachikoma.gfx_kitty ? :kitty :
    Tachikoma.graphics_protocol() == Tachikoma.gfx_sixel ? :sixel : :none

session_image_u32(bytes, offset) = foldl((value, byte) -> (value << 8) | UInt32(byte), @view(bytes[offset:offset+3]); init=UInt32(0))

const SESSION_IMAGE_CRC_TABLE = map(UInt32(0):UInt32(255)) do byte
    value = byte
    for _ in 1:8
        value = (value >> 1) ⊻ (isodd(value) ? UInt32(0xedb88320) : UInt32(0))
    end
    value
end
function session_image_crc(bytes)
    value = typemax(UInt32)
    for byte in bytes
        value = SESSION_IMAGE_CRC_TABLE[Int((value ⊻ byte) & 0xff) + 1] ⊻ (value >> 8)
    end
    ~value
end

"""Accept only bounded standard base64 data, never filenames, URLs, or terminal sequences."""
function session_image_bytes(block::AbstractDict, limits::SessionImageLimits)
    data = get(block, "data", nothing)
    if !(get(block, "type", nothing) == "image" && data isa AbstractString &&
            0 < ncodeunits(data) <= limits.encoded_bytes &&
            occursin(r"^[A-Za-z0-9+/]*={0,2}$", data) && mod(ncodeunits(data), 4) == 0)
        error("Invalid or oversized encoded image")
    end
    padding = endswith(data,"==") ? 2 : endswith(data,"=") ? 1 : 0
    div(ncodeunits(data),4)*3-padding <= limits.decoded_bytes || error("Encoded image exceeds decoded-byte limit")
    bytes = base64decode(data)
    length(bytes) <= limits.decoded_bytes || error("Encoded image exceeds the decoded-byte limit")
    bytes
end

"""Validate the PNG identity and IHDR before accepting any allocation dimensions."""
function session_image_png_header(bytes, limits::SessionImageLimits)
    if length(bytes) < 33 || bytes[1:8] != UInt8[137,80,78,71,13,10,26,10] ||
            session_image_u32(bytes, 9) != 13 || bytes[13:16] != codeunits("IHDR") ||
            session_image_crc(@view bytes[13:29]) != session_image_u32(bytes, 30)
        error("Invalid PNG header")
    end
    width, height = Int(session_image_u32(bytes, 17)), Int(session_image_u32(bytes, 21))
    if !(0 < width <= limits.dimension && 0 < height <= limits.dimension && width <= div(limits.pixels, height))
        error("PNG dimensions exceed the pixel limit")
    end
    (width=width, height=height, depth=Int(bytes[25]), color=Int(bytes[26]),
        compression=Int(bytes[27]), filter=Int(bytes[28]), interlace=Int(bytes[29]))
end

"""Decode only explicitly supported static eight-bit non-interlaced PNG color formats."""
function session_image_png(bytes, limits::SessionImageLimits)
    header = session_image_png_header(bytes, limits)
    if !(header.depth == 8 && header.color in (0,2,3,4,6) && header.compression == 0 && header.filter == 0 && header.interlace == 0)
        error("Unsupported PNG format: only static eight-bit non-interlaced images are supported")
    end
    channels = header.color == 0 || header.color == 3 ? 1 : header.color == 2 ? 3 : header.color == 4 ? 2 : 4
    compressed, palette, transparency = UInt8[], UInt8[], UInt8[]
    offset, ended, seen_data, data_ended = 34, false, false, false
    while offset <= length(bytes) - 11 && !ended
        size = Int(session_image_u32(bytes, offset))
        size <= length(bytes) - offset - 11 || error("Truncated PNG chunk")
        kindbytes = @view bytes[offset+4:offset+7]
        all(byte -> UInt8('A') <= byte <= UInt8('Z') || UInt8('a') <= byte <= UInt8('z'), kindbytes) || error("Invalid PNG chunk name")
        kind = String(copy(kindbytes))
        content = @view bytes[offset+8:offset+7+size]
        session_image_crc(@view bytes[offset+4:offset+7+size]) == session_image_u32(bytes, offset+8+size) || error("PNG checksum mismatch")
        if kind == "IDAT"
            data_ended && error("Non-contiguous PNG image data")
            length(compressed) + size <= limits.decoded_bytes || error("PNG compressed data exceeds limit")
            append!(compressed, content)
            seen_data = true
        elseif kind == "IEND"
            size == 0 && seen_data || error("Invalid PNG end")
            ended = true
        elseif kind == "PLTE"
            !seen_data && header.color in (2,3,6) && isempty(palette) && 0 < size <= 768 && mod(size,3) == 0 || error("Invalid PNG palette")
            append!(palette, content)
        elseif kind == "tRNS"
            !seen_data && isempty(transparency) || error("Invalid PNG transparency")
            append!(transparency, content)
        elseif kind in ("acTL","fcTL","fdAT")
            error("Animated PNG is not supported by this static decoder")
        elseif isuppercase(Char(first(kindbytes)))
            error("Unsupported critical PNG chunk")
        end
        seen_data && kind != "IDAT" && (data_ended = true)
        offset += size + 12
    end
    ended && offset == length(bytes) + 1 || error("Truncated PNG or trailing payload")
    if header.color == 3
        !isempty(palette) && length(transparency) <= div(length(palette),3) || error("Missing or invalid PNG palette")
    elseif !isempty(transparency)
        (header.color == 0 && length(transparency) == 2 || header.color == 2 && length(transparency) == 6) || error("Invalid PNG transparency format")
    end
    stride = header.width * channels
    expected = (stride + 1) * header.height
    stream = ZlibDecompressorStream(IOBuffer(compressed))
    decoding = Task(() -> read(stream, expected + 1))
    schedule(decoding)
    wait(decoding; throw=false)
    close(stream)
    raw = fetch(decoding)
    length(raw) == expected || error("PNG decompression size mismatch")
    pixels = Matrix{Tachikoma.ColorRGBA}(undef, header.height, header.width)
    previous = zeros(UInt8, stride)
    row = similar(previous)
    cursor = 1
    for y in 1:header.height
        filter = Int(raw[cursor])
        filter in 0:4 || error("Invalid PNG row filter")
        cursor += 1
        for x in 1:stride
            left = x > channels ? Int(row[x-channels]) : 0
            above = Int(previous[x])
            upperleft = x > channels ? Int(previous[x-channels]) : 0
            predictor = filter == 0 ? 0 : filter == 1 ? left : filter == 2 ? above :
                filter == 3 ? fld(left + above, 2) : session_image_paeth(left, above, upperleft)
            row[x] = UInt8(mod(Int(raw[cursor]) + predictor,256))
            cursor += 1
        end
        for x in 1:header.width
            pixels[y,x] = session_image_png_pixel(row, (x-1)*channels+1, header.color, palette, transparency)
        end
        previous, row = row, previous
    end
    pixels
end

function session_image_paeth(left, above, upperleft)
    prediction = left + above - upperleft
    distances = (abs(prediction-left), abs(prediction-above), abs(prediction-upperleft))
    distances[1] <= distances[2] && distances[1] <= distances[3] ? left : distances[2] <= distances[3] ? above : upperleft
end

function session_image_png_pixel(row, offset, color, palette, transparency)
    if color == 3
        index = Int(row[offset])
        index < div(length(palette),3) || error("PNG palette index outside palette")
        alpha = index < length(transparency) ? transparency[index+1] : 0xff
        Tachikoma.ColorRGBA(palette[3index+1], palette[3index+2], palette[3index+3], alpha)
    elseif color == 0 || color == 4
        gray = row[offset]
        alpha = color == 4 ? row[offset+1] : !isempty(transparency) && transparency[1] == 0 && transparency[2] == gray ? 0x00 : 0xff
        Tachikoma.ColorRGBA(gray, gray, gray, alpha)
    else
        r,g,b = row[offset],row[offset+1],row[offset+2]
        alpha = color == 6 ? row[offset+3] : !isempty(transparency) && transparency == UInt8[0,r,0,g,0,b] ? 0x00 : 0xff
        Tachikoma.ColorRGBA(r,g,b,alpha)
    end
end

session_image_format(mime) = mime == "image/png" ? :png : mime == "image/jpeg" ? :jpeg : mime == "image/gif" ? :gif : mime == "image/webp" ? :webp : :unsupported
session_image_supported(::Val{:png}) = true
session_image_supported(::Val{format}) where {format} = false
session_image_decode(::Val{:png}, bytes, limits) = session_image_png(bytes, limits)
session_image_decode(::Val{format}, bytes, limits) where {format} = error("No decoder is registered for this image format")

"""Keep unsupported image data inert; decode failures become a truthful bounded fallback."""
function session_image_attempt(f)
    task = Task(f)
    schedule(task)
    wait(task; throw=false)
    istaskfailed(task) ? nothing : fetch(task)
end

function session_image_dimensions(block::AbstractDict; limits=SessionImageLimits())
    get(block,"mimeType",nothing) == "image/png" ? session_image_attempt() do
        header = session_image_png_header(session_image_bytes(block,limits),limits)
        (width=header.width, height=header.height)
    end : nothing
end

"""Match the reference's inert image fallback without opening or hyperlinking archive paths."""
function session_image_fallback(block::AbstractDict; dimensions=session_image_dimensions(block))
    mime = get(block,"mimeType",nothing)
    safe_mime = mime isa AbstractString && occursin(r"^image/[A-Za-z0-9.+-]{1,40}$",mime) ? String(mime) : "image/unknown"
    suffix = isnothing(dimensions) ? "" : " $(dimensions.width)x$(dimensions.height)"
    "[Image: [$safe_mime]$suffix]"
end

function session_image_cell_size(width, height, max_width, max_height, cell_width, cell_height; optimize=false)
    ws, hs = max_width * cell_width / width, max_height * cell_height / height
    scale = min(ws,hs)
    cols = max(1,min(max_width,ceil(Int,width*scale/cell_width)))
    rows = max(1,min(max_height,ceil(Int,height*scale/cell_height)))
    if optimize
        if ws <= hs
            ideal = cols * cell_width * height / (width * cell_height)
            rows = session_image_nearest_cells(rows,ideal)
        else
            ideal = rows * cell_height * width / (height * cell_width)
            cols = session_image_nearest_cells(cols,ideal)
        end
    end
    (columns=cols, rows=rows)
end
session_image_nearest_cells(upper, ideal) = upper > 1 && max((upper-1)/ideal,ideal/(upper-1)) < max(upper/ideal,ideal/upper) ? upper-1 : upper

"""Prepare tool-result raster placements; user and assistant images are omitted like pinned Pi."""
function session_image_prepare(block::AbstractDict, width::Int; context=:tool, options=SessionImageOptions(), protocol=session_image_protocol(), cell_pixels=Tachikoma.cell_pixels(), pixel_budget::Union{Nothing,Int}=nothing)
    limits = options.limits
    if width < 1 || !(1 <= options.max_width_cells <= 512) || !(isnothing(options.max_height_cells) || 1 <= options.max_height_cells <= 512) ||
            !(0 < cell_pixels.w <= 512 && 0 < cell_pixels.h <= 512) ||
            (!isnothing(pixel_budget) && pixel_budget < 0)
        error("Invalid image layout settings")
    end
    if context in (:user,:assistant)
        SessionImagePresentation(:omitted,:reference_omission,protocol,0,0,"",nothing,limits)
    else
        dimensions = session_image_dimensions(block;limits)
        fallback = session_image_fallback(block;dimensions)
        if !options.show_images || protocol == :none
            SessionImagePresentation(:fallback,options.show_images ? :unsupported_terminal : :hidden,protocol,width,1,fallback,nothing,limits)
        elseif !(protocol in (:kitty,:sixel))
            SessionImagePresentation(:fallback,:unsupported_protocol,protocol,width,1,fallback,nothing,limits)
        elseif !session_image_supported(Val(session_image_format(get(block,"mimeType",nothing))))
            SessionImagePresentation(:fallback,:unsupported_mime,protocol,width,1,fallback,nothing,limits)
        elseif !isnothing(pixel_budget) && !isnothing(dimensions) && dimensions.width > div(pixel_budget,dimensions.height)
            SessionImagePresentation(:fallback,:plan_pixel_budget,protocol,width,1,
                fallback*" (display pixel budget exhausted)",nothing,limits)
        elseif !isnothing(pixel_budget) && isnothing(dimensions)
            SessionImagePresentation(:fallback,:invalid_or_unsupported_png,protocol,width,1,fallback,nothing,limits)
        else
            pixels = session_image_attempt() do
                session_image_decode(Val(session_image_format(get(block,"mimeType",nothing))),session_image_bytes(block,limits),limits)
            end
            if isnothing(pixels)
                SessionImagePresentation(:fallback,:invalid_or_unsupported_png,protocol,width,1,fallback,nothing,limits)
            else
                max_width = max(1,min(width-2,options.max_width_cells))
                max_height = something(options.max_height_cells,max(1,cld(max_width*cell_pixels.w,cell_pixels.h)))
                shape = session_image_cell_size(size(pixels,2),size(pixels,1),max_width,max_height,cell_pixels.w,cell_pixels.h;optimize=protocol==:kitty)
                SessionImagePresentation(:raster,:decoded,protocol,shape.columns,shape.rows,fallback,pixels,limits)
            end
        end
    end
end

"""Render real Kitty/Sixel pixel regions with vertical viewport cropping, never fake text success."""
function render_session_image!(prepared::SessionImagePresentation, rect::Tachikoma.Rect, frame::Tachikoma.Frame; hidden_rows=0)
    pixels = prepared.pixels
    if prepared.state != :raster
        prepared.state
    elseif isnothing(pixels)
        error("Raster image presentation is missing decoded pixels")
    elseif session_image_protocol() != prepared.protocol
        :capability_changed
    else
        if rect.width != prepared.columns || rect.height < 1 || hidden_rows < 0 || hidden_rows + rect.height > prepared.rows ||
                rect.x < frame.area.x || rect.y < frame.area.y ||
                rect.x+rect.width > frame.area.x+frame.area.width || rect.y+rect.height > frame.area.y+frame.area.height
            error("Image placement is outside its reserved viewport")
        end
        pw,ph = Tachikoma._pixelimage_pixel_dims(prepared.columns,prepared.rows)
        0 < pw && 0 < ph && pw <= div(prepared.limits.render_pixels,ph) || error("Terminal image raster exceeds render-pixel limit")
        image = Tachikoma.PixelImage(prepared.columns,prepared.rows;bg=Tachikoma.ColorRGBA(0,0,0,0))
        Tachikoma.load_pixels!(image,pixels)
        if hidden_rows != 0 || rect.height != prepared.rows
            first_row = fld(hidden_rows*ph,prepared.rows)+1
            last_row = cld((hidden_rows+rect.height)*ph,prepared.rows)
            cropped = image.pixels[first_row:last_row,:]
            image = Tachikoma.PixelImage(rect.width,rect.height;bg=Tachikoma.ColorRGBA(0,0,0,0))
            Tachikoma.load_pixels!(image,cropped)
        end
        before = length(frame.gfx_regions)
        Tachikoma.render(image,rect,frame)
        length(frame.gfx_regions) > before ? :rendered : :transparent
    end
end
