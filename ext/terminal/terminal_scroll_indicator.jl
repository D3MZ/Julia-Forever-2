# Native jump-to-end presentation derived from Pi at 2c8d1feb; MIT, see licenses/pi-LICENSE.
public TerminalScrollIndicator, terminal_scroll_indicator, terminal_scroll_indicator_draw!, terminal_scroll_indicator_mouse!

Base.@kwdef struct TerminalScrollIndicator
    rect::Tachikoma.Rect
    text::String
    style::Tachikoma.Style
    owner::String = ""
    epoch::UInt = UInt(0)
end

"""Format actual bound key names using the original capitalized modifier display convention."""
function terminal_indicator_shortcut(bindings::AbstractVector{<:AbstractString};macos::Bool=Sys.isapple())
    join([join([join([begin
        display=macos && lowercase(part)=="alt" ? "option" : part
        isempty(display) ? "" : uppercase(string(first(display)))*chop(display;head=1,tail=0)
    end for part in split(key,'+';keepempty=true)],'+') for key in split(binding,'/';keepempty=true)],'/')
        for binding in bindings],'/')
end

# Native Tachikoma.truncate_to_width uses Base.textwidth; Pi overlays retain
# the menu search editor's grapheme width rules and omit ellipses.

"""Place the source label on the last clipped document row, centered independently of scrollbar visibility."""
function terminal_scroll_indicator(control::TerminalScrollControl,buffer::Tachikoma.Buffer;
        theme::Union{NativeTheme,ThemeRuntime},bindings::AbstractVector{<:AbstractString}=String[],
        enabled::Bool=true,follow_end::Bool=true,image_rows::AbstractSet{Int}=Set{Int}(),
        macos::Bool=Sys.isapple(),now::Real=time_ns()/1e9)
    view=control.snapshot;clip=view.clip;row=clip.y+clip.height-1;result=nothing
    if !control.closed && view.fullscreen && enabled && follow_end && !control.scroll.following &&
            clip.width>0 && clip.height>0 && Tachikoma.in_bounds(buffer,clip.x,row) && !(row in image_rows)
        shortcut=terminal_indicator_shortcut(bindings;macos)
        label=menu_search_slice(" ↓ Jump to latest message"*(isempty(shortcut) ? "" : " · "*shortcut)*" ",0,clip.width)
        column=clip.x+fld(clip.width-menu_search_width(label),2)
        geometry=terminal_scroll_geometry(control.scroll,view.rect.width;now)
        track_column=view.rect.x+view.rect.width-1
        visible_track=!isnothing(geometry) && clip.x<=track_column<clip.x+clip.width
        right=visible_track ? track_column : clip.x+clip.width
        text=menu_search_slice(label,0,max(0,right-column))
        width=menu_search_width(text)
        if width>0
            foreground=theme_token_style(theme,"text");background=theme_token_style(theme,"selectedBg")
            style=Tachikoma.Style(;fg=foreground.fg,bg=background.bg,dim=foreground.dim)
            result=TerminalScrollIndicator(;rect=Tachikoma.Rect(column,row,width,1),text,style,owner=view.owner,epoch=view.epoch)
        end
    end
    result
end

"""Extract only whole native glyph cells on either side of an overlay, preserving original text styles."""
function terminal_indicator_segments(cells::Vector{Tachikoma.Cell},start::Int,stop::Int)
    before=Tachikoma.Cell[];after=Tachikoma.Cell[];index=1
    while index<=length(cells)
        next=index+1
        while next<=length(cells) && cells[next].char=='\0'
            next+=1
        end
        if index-1<start && next-1<=start
            append!(before,cells[index:next-1])
        elseif index-1>=stop
            append!(after,cells[index:next-1])
        end
        index=next
    end
    (before,after)
end

terminal_scroll_indicator_draw!(::Nothing,buffer::Tachikoma.Buffer)=nothing

"""Composite actual cells with source-equivalent wide-glyph boundary removal, never mutate archived rows."""
function terminal_scroll_indicator_draw!(indicator::TerminalScrollIndicator,buffer::Tachikoma.Buffer)
    rect=indicator.rect;area=buffer.area
    if Tachikoma.in_bounds(buffer,rect.x,rect.y) && Tachikoma.in_bounds(buffer,rect.x+rect.width-1,rect.y)
        row=[buffer.content[Tachikoma.buf_index(buffer,x,rect.y)] for x in area.x:area.x+area.width-1]
        start=rect.x-area.x;before,after=terminal_indicator_segments(row,start,start+rect.width)
        before_style=isempty(before) ? Tachikoma.Style() : last(before).style
        append!(before,[Tachikoma.Cell(' ',before_style) for _ in 1:max(0,start-length(before))])
        overlay=Tachikoma.Buffer(Tachikoma.Rect(1,1,rect.width,1))
        startup_document_draw!(overlay,1,1,rect.width,[[Tachikoma.Span(indicator.text,indicator.style)]])
        result=[before;overlay.content;after]
        after_style=isempty(after) ? Tachikoma.Style() : last(after).style
        append!(result,[Tachikoma.Cell(' ',after_style) for _ in 1:max(0,area.width-length(result))])
        for (column,cell) in enumerate(result[1:min(area.width,length(result))])
            Tachikoma.set!(buffer,area.x+column-1,rect.y,cell)
        end
    end
    nothing
end

terminal_scroll_indicator_mouse!(::Nothing,control::TerminalScrollControl,event::Tachikoma.MouseEvent;kwargs...)=false

"""Only an in-rect left press resumes follow; hover, release, drag and right presses have no indicator action."""
function terminal_scroll_indicator_mouse!(indicator::TerminalScrollIndicator,control::TerminalScrollControl,
        event::Tachikoma.MouseEvent;blocked::Bool=false,now::Real=time_ns()/1e9)
    rect=indicator.rect;view=control.snapshot
    handled=!blocked && !control.closed && view.fullscreen && indicator.owner==view.owner && indicator.epoch==view.epoch &&
        event.action==Tachikoma.mouse_press && event.button==Tachikoma.mouse_left && event.y==rect.y &&
        rect.x<=event.x<rect.x+rect.width
    handled && terminal_scroll_control_end!(control;now)
    handled
end
