public startup_viewport_lines, startup_document_draw!, StartupDockPart, startup_dock_sizes, startup_scene

"""Keep the document's visible tail above a fixed dock, without bottom-aligning short documents."""
function startup_viewport_lines(document::Vector{Vector{Tachikoma.Span}},height::Integer;scroll::Integer=0)
    available=max(0,Int(height));offset=clamp(Int(scroll),0,max(0,length(document)-available))
    bottom=max(0,length(document)-offset);top=max(1,bottom-available+1)
    visible=copy(document[top:bottom])
    append!(visible,[[Tachikoma.Span("",Tachikoma.Style())] for _ in 1:max(0,available-length(visible))])
    visible
end

"""Draw structured document glyphs with the shared search input's grapheme-aware cell writer."""
function startup_document_draw!(buffer,x::Integer,y::Integer,width::Integer,lines)
    for (row,line) in enumerate(lines)
        column=Int(x)
        for span in line
            for glyph in menu_search_graphemes(startup_safe_text(span.content))
                columns=menu_search_width(glyph)
                if columns>0 && column+columns<=x+width
                    characters=collect(glyph)
                    Tachikoma.set!(buffer,Int(column),Int(y+row-1),Tachikoma.Cell(first(characters),span.style,join(characters[2:end])))
                    for extra in 1:columns-1
                        Tachikoma.set!(buffer,Int(column+extra),Int(y+row-1),Tachikoma.Cell('\0',span.style))
                    end
                    column+=columns
                end
            end
        end
    end
    nothing
end

Base.@kwdef struct StartupDockPart
    name::Symbol
    lines::Vector{Vector{Tachikoma.Span}}
    minimum::Int = 0
    cursor_row::Union{Nothing,Int} = nothing
end

"""Allocate a constrained dock by current size weights, respecting each part's real minimum."""
function startup_dock_sizes(parts::Vector{StartupDockPart},height::Int)
    sizes=[max(part.minimum,length(part.lines)) for part in parts]
    remaining=max(0,sum(sizes)-height)
    progressing=true
    while remaining>0 && progressing
        candidates=findall(index->sizes[index]>parts[index].minimum,eachindex(parts))
        weight=sum(index->max(1,sizes[index]),candidates;init=0)
        distributed=0
        for index in candidates
            proposed=max(1,fld(remaining*max(1,sizes[index]),weight))
            delta=min(remaining,proposed,sizes[index]-parts[index].minimum)
            sizes[index]-=delta;remaining-=delta;distributed+=delta
        end
        progressing=distributed>0
    end
    sizes
end

"""Compose a full-screen document and independently rendered dock without footer overdraw."""
function startup_scene(document::Vector{Vector{Tachikoma.Span}},parts::Vector{StartupDockPart},height::Integer;scroll::Integer=0)
    total=max(0,Int(height));natural=sum(part->max(part.minimum,length(part.lines)),parts;init=0)
    document_height=max(1,total-max(1,natural));dock_height=max(1,total-document_height)
    sizes=startup_dock_sizes(parts,dock_height)
    lines=startup_viewport_lines(document,document_height;scroll)
    rectangles=NamedTuple{(:name,:top,:height,:first_row),Tuple{Symbol,Int,Int,Int}}[]
    top=document_height+1
    for (part,size) in zip(parts,sizes)
        first_row=!isnothing(part.cursor_row)&&part.cursor_row>size ? part.cursor_row-size+1 : 1
        push!(rectangles,(name=part.name,top,height=size,first_row))
        visible=part.lines[first_row:min(length(part.lines),first_row+size-1)]
        append!(lines,visible)
        append!(lines,[[Tachikoma.Span("",Tachikoma.Style())] for _ in 1:max(0,size-length(visible))])
        top+=size
    end
    (lines=lines[1:min(total,length(lines))],document_height,rectangles)
end
