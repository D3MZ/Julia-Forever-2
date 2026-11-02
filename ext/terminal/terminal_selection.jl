# Native selection behavior derived from Pi (MIT), copyright (c) 2025 Mario Zechner.
# Pinned upstream: 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""A terminal-cell position distinguishes document rows from screen-owned dock rows."""
Base.@kwdef struct TerminalSelectionPoint
    row::Int
    column::Int
    document::Bool=false
    boundary::Bool=false
end
Base.@kwdef struct TerminalSelectionRange
    start::TerminalSelectionPoint
    stop::TerminalSelectionPoint
end
Base.@kwdef struct TerminalSelectionView
    document::Vector{Vector{Tachikoma.Span}}=Vector{Tachikoma.Span}[]
    screen::Vector{Vector{Tachikoma.Span}}=Vector{Tachikoma.Span}[]
    area::Tachikoma.Rect=Tachikoma.Rect(1,1,0,0)
    document_area::Tachikoma.Rect=Tachikoma.Rect(1,1,0,0)
    top::Int=0
end
"""Keep selection ownership, multi-click timing and drag intent independent of model history."""
Base.@kwdef mutable struct TerminalSelectionState
    anchor::Union{Nothing,TerminalSelectionPoint}=nothing
    focus::Union{Nothing,TerminalSelectionPoint}=nothing
    initial::Union{Nothing,TerminalSelectionRange}=nothing
    granularity::Symbol=:character
    active::Bool=false
    dragged::Bool=false
    click_time::Float64=-Inf
    click_count::Int=0
    click_word::Union{Nothing,TerminalSelectionRange}=nothing
    pointer::Union{Nothing,Tuple{Int,Int}}=nothing
    direction::Int=0
    next_scroll::Float64=Inf
    copy_on_select::Bool=true
    revision::UInt=0
end
selection_inside(area::Tachikoma.Rect,x::Int,y::Int)=area.x<=x<area.x+area.width && area.y<=y<area.y+area.height
selection_plain(line::Vector{Tachikoma.Span})=startup_safe_text(join(span.content for span in line))
function selection_source(view::TerminalSelectionView,point::TerminalSelectionPoint)
    rows=point.document ? view.document : view.screen
    0<=point.row<length(rows) ? selection_plain(rows[point.row+1]) : ""
end
function selection_point(view::TerminalSelectionView,x::Int,y::Int,document::Bool)
    area=document ? view.document_area : view.area
    row=clamp(y-area.y,0,max(0,area.height-1))
    column=clamp(x-area.x,0,max(0,area.width-1))
    source_row=document ? clamp(view.top+row,0,max(0,length(view.document)-1)) : row
    TerminalSelectionPoint(;row=source_row,column,document)
end
selection_before(a::TerminalSelectionPoint,b::TerminalSelectionPoint)=a.row<b.row || a.row==b.row && a.column<b.column
selection_at(point::TerminalSelectionPoint,column::Int;boundary=false)=TerminalSelectionPoint(;row=point.row,column,document=point.document,boundary)
function selection_word(view::TerminalSelectionView,point::TerminalSelectionPoint)
    segments=NamedTuple{(:start,:stop,:selectable,:joiner),Tuple{Int,Int,Bool,Bool}}[]
    column=0
    for segment in JuliaForever2.WordSegmentation.segments(selection_source(view,point))
        stop=column+menu_search_width(segment.text)
        joiner=segment.text in ("/","-","+","\\","~","_",".")
        push!(segments,(start=column,stop,selectable=segment.word || joiner,joiner))
        column=stop
    end
    index=findfirst(segment->segment.start<=point.column<segment.stop,segments)
    if isnothing(index)
        nothing
    else
        first=last=index
        joins(left,right)=left.selectable && right.selectable && (left.joiner || right.joiner)
        while first>1 && joins(segments[first-1],segments[first])
            first-=1
        end
        while last<length(segments) && joins(segments[last],segments[last+1])
            last+=1
        end
        TerminalSelectionRange(;start=selection_at(point,segments[first].start),stop=selection_at(point,segments[last].stop;boundary=true))
    end
end
selection_line(view::TerminalSelectionView,point::TerminalSelectionPoint)=TerminalSelectionRange(;start=selection_at(point,0),stop=selection_at(point,menu_search_width(selection_source(view,point));boundary=true))
function selection_focus!(state::TerminalSelectionState,view::TerminalSelectionView,point::TerminalSelectionPoint)
    if state.granularity==:character || isnothing(state.initial)
        state.focus=point
    else
        range=state.granularity==:word ? selection_word(view,point) : selection_line(view,point)
        if !isnothing(range)
            initial=state.initial::TerminalSelectionRange
            before=selection_before(range.start,initial.start)
            state.anchor=before ? initial.stop : initial.start
            state.focus=before ? range.start : range.stop
        end
    end
    nothing
end
function selection_stop_scroll!(state::TerminalSelectionState)
    state.pointer=nothing;state.direction=0;state.next_scroll=Inf
    nothing
end
function terminal_selection_clear!(state::TerminalSelectionState;clicks=false)
    selection_stop_scroll!(state)
    state.anchor=nothing;state.focus=nothing;state.initial=nothing;state.granularity=:character
    state.active=false;state.dragged=false
    clicks && (state.click_word=nothing;state.click_count=0;state.click_time=-Inf)
    state.revision+=1
    nothing
end
function terminal_selection_focus_lost!(state::TerminalSelectionState)
    state.active && terminal_selection_clear!(state)
    selection_stop_scroll!(state);state.click_word=nothing;state.click_count=0;state.click_time=-Inf
    nothing
end
function selection_bounds(state::TerminalSelectionState)
    a,b=state.anchor,state.focus
    if isnothing(a)||isnothing(b)||a.document!=b.document||a.row==b.row && a.column==b.column
        nothing
    else
        selection_before(a,b) ? TerminalSelectionRange(;start=a,stop=b) : TerminalSelectionRange(;start=b,stop=a)
    end
end
function selection_graphemes(text::AbstractString)
    result=NamedTuple{(:text,:start,:stop),Tuple{String,Int,Int}}[];column=0
    for grapheme in Base.Unicode.graphemes(text)
        width=menu_search_width(grapheme)
        push!(result,(text=String(grapheme),start=column,stop=column+width));column+=width
    end
    result
end
function selection_columns(text::AbstractString,row::Int,range::TerminalSelectionRange;minimum=0,maximum=menu_search_width(text))
    width=menu_search_width(text);start=0;stop=min(width,maximum);graphemes=selection_graphemes(text)
    if row==range.start.row
        index=findfirst(item->item.start<=range.start.column<item.stop,graphemes)
        start=isnothing(index) ? min(range.start.column,width) : graphemes[index].start
    end
    if row==range.stop.row
        index=findfirst(item->item.start<=range.stop.column<item.stop,graphemes)
        stop=range.stop.boundary ? min(range.stop.column,width) : isnothing(index) ? min(range.stop.column+1,width) : graphemes[index].stop
    end
    (start=max(minimum,start),stop=min(maximum,stop))
end
"""Copy only selected visible text, never terminal escape programs or archived hidden payloads."""
function terminal_selection_text(state::TerminalSelectionState,view::TerminalSelectionView)
    range=selection_bounds(state)
    if isnothing(range)
        nothing
    else
        lines=String[]
        for row in range.start.row:range.stop.row
            text=selection_source(view,TerminalSelectionPoint(;row,column=0,document=range.start.document))
            columns=selection_columns(text,row,range)
            chosen=join(item.text for item in selection_graphemes(text) if item.stop>columns.start && item.start<columns.stop)
            push!(lines,rstrip(chosen))
        end
        text=join(lines,"\n")
        isempty(text) ? nothing : text
    end
end
function selection_click!(state::TerminalSelectionState,word,now::Float64)
    previous=state.click_word
    same=!isnothing(word) && !isnothing(previous) && now-state.click_time<=500 &&
        word.start.row==previous.start.row && word.start.document==previous.start.document &&
        word.start.column==previous.start.column && word.stop.column==previous.stop.column
    state.click_count=same ? mod(state.click_count,3)+1 : 1
    state.click_word=word;state.click_time=now
    state.click_count
end
"""Apply an unclaimed primary-button gesture; the owner decides whether returned text is actually copied."""
function terminal_selection_mouse!(state::TerminalSelectionState,view::TerminalSelectionView,action::Symbol,button::Symbol,x::Int,y::Int;now::Real=time_ns()/1e6)
    handled=false;copy_text=nothing
    if button==:left || action==:release && button==:none
        document=!isnothing(state.anchor) && state.anchor.document
        point=selection_point(view,x,y,document)
        if action==:release && state.active
            state.active=false;selection_stop_scroll!(state)
            selection_focus!(state,view,point)
            copy_text=state.copy_on_select ? terminal_selection_text(state,view) : nothing
            state.revision+=1;handled=true
        elseif action==:drag && state.active && !isnothing(state.anchor)
            state.dragged=true;state.click_word=nothing;state.click_count=0
            selection_focus!(state,view,point)
            if document && view.document_area.height>0
                area=view.document_area
                direction=y<=area.y ? -1 : y>=area.y+area.height-1 ? 1 : 0
                if direction==0
                    selection_stop_scroll!(state)
                else
                    state.pointer=(x,y);state.direction=direction
                    isfinite(state.next_scroll) || (state.next_scroll=Float64(now)+50)
                end
            else
                selection_stop_scroll!(state)
            end
            state.revision+=1;handled=true
        elseif action==:press && button==:left
            selection_stop_scroll!(state)
            document=selection_inside(view.document_area,x,y) && !isempty(view.document)
            point=selection_point(view,x,y,document)
            word=selection_word(view,point);count=selection_click!(state,word,Float64(now))
            range=count==2 ? word : count==3 ? selection_line(view,point) : nothing
            state.granularity=isnothing(range) ? :character : count==2 ? :word : :line
            state.initial=range;state.anchor=isnothing(range) ? point : range.start;state.focus=isnothing(range) ? point : range.stop
            state.active=true;state.dragged=false;state.revision+=1;handled=true
        end
    end
    (;handled,copy_text)
end
"""Advance one real 50ms drag-scroll tick through the owner's absolute viewport setter."""
function terminal_selection_tick!(state::TerminalSelectionState,view::TerminalSelectionView,scroll::Function;now::Real=time_ns()/1e6)
    changed=false
    pointer=state.pointer
    if state.active && state.direction!=0 && !isnothing(pointer) && now>=state.next_scroll
        next=Base.invokelatest(scroll,state.direction)
        if next isa TerminalSelectionView && next.top!=view.top
            x,y=pointer
            selection_focus!(state,next,selection_point(next,x,y,true))
            state.next_scroll=Float64(now)+50;state.revision+=1;changed=true
        else
            selection_stop_scroll!(state)
        end
    end
    changed
end
