# Native selection behavior derived from Pi (MIT), copyright (c) 2025 Mario Zechner.
# Pinned upstream: 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""Preserve real foreground/background tokens while applying terminal inverse video."""
struct TerminalSelectionInverseColor <: Tachikoma.AbstractColor
    base::Tachikoma.AbstractColor
end
function Tachikoma.write_fg(io::IO,color::TerminalSelectionInverseColor)
    Tachikoma.write_fg(io,color.base)
    write(io,"\e[7m")
end
selection_inverse(style::Tachikoma.Style)=Tachikoma.Style(;fg=TerminalSelectionInverseColor(style.fg),bg=style.bg,
    bold=style.bold,dim=style.dim,italic=style.italic,underline=style.underline,strikethrough=style.strikethrough,hyperlink=style.hyperlink)
function selection_highlight(line::Vector{Tachikoma.Span},start::Int,stop::Int)
    result=Tachikoma.Span[];column=0
    for span in line, grapheme in Base.Unicode.graphemes(startup_safe_text(span.content))
        width=menu_search_width(grapheme)
        selected=column<stop && column+width>start
        push!(result,Tachikoma.Span(String(grapheme),selected ? selection_inverse(span.style) : span.style))
        column+=width
    end
    result
end
"""Overlay selected cells without altering source rows, styles or copied model text."""
function terminal_selection_lines(state::TerminalSelectionState,view::TerminalSelectionView)
    result=copy(view.screen);range=selection_bounds(state)
    if !isnothing(range)
        document=range.start.document
        left=document ? max(0,view.document_area.x-view.area.x) : 0
        right=document ? min(view.area.width,view.document_area.x-view.area.x+view.document_area.width) : view.area.width
        row_offset=document ? view.document_area.y-view.area.y-view.top : 0
        column_offset=document ? view.document_area.x-view.area.x : 0
        screen_range=TerminalSelectionRange(;
            start=TerminalSelectionPoint(;row=range.start.row+row_offset,column=range.start.column+column_offset,boundary=range.start.boundary),
            stop=TerminalSelectionPoint(;row=range.stop.row+row_offset,column=range.stop.column+column_offset,boundary=range.stop.boundary))
        for row in eachindex(result)
            screen_row=row-1
            visible=!document || view.document_area.y<=view.area.y+screen_row<view.document_area.y+view.document_area.height
            if visible && screen_range.start.row<=screen_row<=screen_range.stop.row
                # Selection paints the composite screen, including a scrollbar overlay;
                # copied text continues to come only from the document in terminal_selection_text.
                source=selection_plain(result[row])
                columns=selection_columns(source,screen_row,screen_range;minimum=left,maximum=right)
                if columns.stop>columns.start
                    result[row]=selection_highlight(result[row],columns.start,columns.stop)
                end
            end
        end
    end
    result
end

"""One owned transient flash reports confirmed success separately from unconfirmed OSC submission."""
Base.@kwdef struct TerminalSelectionFlash
    text::String
    expires::Float64
end
Base.@kwdef mutable struct TerminalSelectionFlashes
    entries::Vector{TerminalSelectionFlash}=TerminalSelectionFlash[]
    revision::UInt=0
end
function terminal_selection_flash!(state::TerminalSelectionFlashes,text::AbstractString;duration::Real=1000,now::Real=time_ns()/1e6)
    push!(state.entries,TerminalSelectionFlash(;text=startup_safe_text(text),expires=Float64(now+max(0,duration))))
    state.revision+=1
    nothing
end
function terminal_selection_flash_expire!(state::TerminalSelectionFlashes;now::Real=time_ns()/1e6)
    previous=length(state.entries);filter!(entry->entry.expires>now,state.entries)
    changed=length(state.entries)!=previous
    changed && (state.revision+=1)
    changed
end
function selection_truncate(text::AbstractString,width::Int)
    pieces=String[];used=0
    for grapheme in Base.Unicode.graphemes(text)
        cells=menu_search_width(grapheme)
        if used+cells<=width
            push!(pieces,String(grapheme));used+=cells
        else
            break
        end
    end
    join(pieces)
end
function terminal_selection_flash_lines(state::TerminalSelectionFlashes,screen::Vector{Vector{Tachikoma.Span}},width::Int,height::Int)
    result=copy(screen)
    while length(result)<height
        push!(result,[Tachikoma.Span(repeat(" ",width),Tachikoma.Style())])
    end
    entries=state.entries[max(1,length(state.entries)-height+1):end]
    for (row,entry) in enumerate(entries)
        message=selection_truncate(" "*entry.text*" ",width)
        cells=menu_search_width(message);start=width-cells
        before=Tachikoma.Span[];used=0
        for span in result[row],grapheme in Base.Unicode.graphemes(startup_safe_text(span.content))
            size=menu_search_width(grapheme)
            if used+size<=start
                push!(before,Tachikoma.Span(String(grapheme),span.style))
            end
            used+=size
        end
        actual=sum(span->menu_search_width(span.content),before;init=0)
        actual<start && push!(before,Tachikoma.Span(repeat(" ",start-actual),Tachikoma.Style()))
        push!(before,Tachikoma.Span(message,selection_inverse(Tachikoma.Style())))
        result[row]=before
    end
    result
end
