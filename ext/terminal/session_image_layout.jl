"""A real image's transcript reservation, distinct from successful terminal rendering."""
struct SessionImagePlacement
    row::Int
    column::Int
    source_entry_id::String
    tool_call_id::String
    image::SessionImagePresentation
end

"""Keep native text rows and typed pixel placements together through scrolling and resize."""
struct SessionDisplayPlan
    rows::SessionDisplayRows
    placements::Vector{SessionImagePlacement}
    width::Int
    options::SessionImageOptions
    protocol::Symbol
    cell_pixels::Tuple{Int,Int}
end

"""A display-only copy replaces image blocks with truthful fallback or separate raster reservations."""
function session_image_text_tool(tool::JuliaForever2.TimelineDisplayTool, presentations, inline::Bool)
    result = deepcopy(tool.result)
    if !isnothing(result)
        original = session_display_content(get(result,"content",Any[]))
        content = [deepcopy(block) for block in original if session_display_block_kind(block) != "image"]
        if !inline
            for image in presentations
                push!(content,Dict("type"=>"text","text"=>image.fallback))
            end
        end
        result["content"] = content
    end
    JuliaForever2.TimelineDisplayTool(;source_entry_id=tool.source_entry_id,
        call=deepcopy(tool.call),result,result_entry_id=tool.result_entry_id)
end

"""Append actual Pi-style image spacers after the tool renderer without embedding marker text."""
function session_tool_image_rows!(placements,tool,width,state,registry,offset,options,protocol,cell_pixels,budget)
    result = tool.result
    blocks = isnothing(result) ? Dict{String,Any}[] :
        [block for block in session_display_content(get(result,"content",Any[])) if session_display_block_kind(block)=="image"]
    if isempty(blocks)
        session_display_tool(tool,width,state,registry)
    else
        images = SessionImagePresentation[]
        for block in blocks
            image = session_image_prepare(block,width;options,protocol,cell_pixels,pixel_budget=budget[])
            pixels = image.pixels
            if !isnothing(pixels)
                budget[] -= length(pixels)
            end
            push!(images,image)
        end
        inline = options.show_images && protocol in (:kitty,:sixel)
        text_tool = session_image_text_tool(tool,images,inline)
        rows = session_display_tool(text_tool,width,state,registry)
        if inline
            for image in images
                push!(rows,session_display_blank(width))
                if image.state == :raster
                    row = offset + length(rows) + 1
                    id = get(tool.call,"id","")
                    push!(placements,SessionImagePlacement(row,1,tool.source_entry_id,String(id),image))
                    for _ in 1:image.rows
                        push!(rows,session_display_blank(width))
                    end
                else
                    text = Tachikoma.truncate_to_width(image.fallback,width)
                    append!(rows,session_display_text_rows(text,width,0;style=session_display_style(:tool)))
                end
            end
        end
        rows
    end
end

"""Prepare once per source/style/width/capability change and reuse decoded pixels on ordinary frames."""
function session_display_plan(projection::JuliaForever2.TimelineDisplayProjection,width::Int;
        state=SessionDisplayState(),tool_renderers=nothing,custom_entry_renderer=nothing,after_record=nothing,on_component=nothing,
        options=SessionImageOptions(),protocol=session_image_protocol(),cell_pixels=Tachikoma.cell_pixels())
    options.limits.plan_pixels >= 0 || error("Invalid transcript image pixel budget")
    placements = SessionImagePlacement[]
    budget = Ref(options.limits.plan_pixels)
    collector = (tool,w,display,registry,offset) -> session_tool_image_rows!(placements,tool,w,display,registry,offset,options,protocol,cell_pixels,budget)
    rows = session_display_lines(projection,width;state,tool_renderers,custom_entry_renderer,tool_layout=collector,after_record,on_component)
    SessionDisplayPlan(rows,placements,width,options,protocol,(Int(cell_pixels.w),Int(cell_pixels.h)))
end

session_image_layout_key(options::SessionImageOptions,protocol=session_image_protocol(),cell_pixels=Tachikoma.cell_pixels()) =
    (options.show_images,options.max_width_cells,options.max_height_cells,options.limits,protocol,cell_pixels.w,cell_pixels.h)

"""Draw only visible reserved images; changed layout or capability requires an explicit new plan."""
function draw_session_images!(plan::SessionDisplayPlan,frame::Tachikoma.Frame,viewport::Tachikoma.Rect;
        first_row::Int=1,options=plan.options)
    current = Tachikoma.cell_pixels()
    if first_row < 1 || viewport.width < 1 || viewport.height < 0 ||
            viewport.x < frame.area.x || viewport.y < frame.area.y ||
            viewport.x+viewport.width > frame.area.x+frame.area.width || viewport.y+viewport.height > frame.area.y+frame.area.height
        error("Invalid image transcript viewport")
    end
    outcomes = NamedTuple{(:source_entry_id,:tool_call_id,:status),Tuple{String,String,Symbol}}[]
    compatible = plan.width == viewport.width && plan.protocol == session_image_protocol() &&
        plan.cell_pixels == (current.w,current.h) && isequal(plan.options,options)
    if !compatible
        push!(outcomes,(source_entry_id="",tool_call_id="",status=:reprepare))
    else
        last_row = first_row + viewport.height - 1
        for placement in plan.placements
            start = max(first_row,placement.row)
            stop = min(last_row,placement.row+placement.image.rows-1)
            if start <= stop
                rect = Tachikoma.Rect(viewport.x+placement.column-1,viewport.y+start-first_row,
                    placement.image.columns,stop-start+1)
                status = render_session_image!(placement.image,rect,frame;hidden_rows=start-placement.row)
                push!(outcomes,(source_entry_id=placement.source_entry_id,tool_call_id=placement.tool_call_id,status))
            end
        end
    end
    outcomes
end
