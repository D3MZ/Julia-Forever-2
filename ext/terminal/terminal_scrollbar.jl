public TerminalScrollState, terminal_scroll_layout!, terminal_scroll_to!, terminal_scroll_active!, terminal_scrollbar_mode!

"""Keep fullscreen follow-end and transient scrollbar state without asynchronous timers."""
Base.@kwdef mutable struct TerminalScrollState
    mode::Symbol = :auto
    top::Int = 0
    content::Int = 0
    viewport::Int = 0
    following::Bool = true
    suppress_follow::Bool = false
    active::Bool = false
    visible_until::Float64 = -Inf
    last_offset::Int = 0
    grab::Union{Nothing,Int} = nothing
end

terminal_scroll_max(state::TerminalScrollState)=max(0,state.content-state.viewport)
terminal_scroll_content_width(state::TerminalScrollState,width::Int)=state.mode==:always && width>1 ? width-1 : width
terminal_scroll_visible(state::TerminalScrollState;now::Real=time_ns()/1e9)=state.mode==:always ? state.viewport>0 :
    state.mode==:auto && state.content>state.viewport && now<state.visible_until

function terminal_scroll_activity!(state::TerminalScrollState,now::Real)
    if state.mode==:auto && state.content>state.viewport
        state.visible_until=state.active ? Inf : Float64(now)+1
    end
    nothing
end

function terminal_scrollbar_mode!(state::TerminalScrollState,mode::Symbol;now::Real=time_ns()/1e9)
    if mode!=state.mode
        state.mode=mode
        if mode!=:auto
            state.visible_until=-Inf
        elseif state.active
            terminal_scroll_activity!(state,now)
        end
    end
    nothing
end

function terminal_scroll_layout!(state::TerminalScrollState,content::Integer,viewport::Integer)
    state.content=max(0,Int(content));state.viewport=max(0,Int(viewport))
    maximum=terminal_scroll_max(state)
    state.top=state.following ? maximum : clamp(state.top,0,maximum)
    state.top<maximum && (state.suppress_follow=false)
    state.top==maximum && !state.suppress_follow && (state.following=true)
    state.content<=state.viewport && (state.visible_until=-Inf)
    nothing
end

function terminal_scroll_to!(state::TerminalScrollState,top::Integer;disable_follow::Bool=false,now::Real=time_ns()/1e9)
    maximum=terminal_scroll_max(state)
    next=clamp(Int(top),0,maximum)
    suppress=disable_follow && next==maximum
    following=!suppress && next==maximum
    moved=next!=state.top
    state.top=next;state.suppress_follow=suppress;state.following=following
    moved && terminal_scroll_activity!(state,now)
    nothing
end

function terminal_scroll_active!(state::TerminalScrollState,active::Bool;now::Real=time_ns()/1e9)
    if active!=state.active
        state.active=active
        terminal_scroll_activity!(state,now)
    end
    nothing
end

"""Return exact native scrollbar geometry, including the original two-cell minimum thumb."""
function terminal_scroll_geometry(state::TerminalScrollState,width::Integer;now::Real=time_ns()/1e9,include_hidden::Bool=false)
    visible=terminal_scroll_visible(state;now) || (include_hidden && state.mode==:auto && state.content>state.viewport)
    if width<=0 || state.viewport<=0 || !visible
        nothing
    else
        height=state.viewport
        thumb=state.content==0 ? height : clamp(floor(Int,height*height/state.content+0.5),min(2,height),height)
        maximum=terminal_scroll_max(state)
        offset=maximum==0 ? 0 : floor(Int,state.top*(height-thumb)/maximum+0.5)
        (column=Int(width),top=1,height,thumb_top=offset+1,thumb_height=thumb,maximum)
    end
end

"""Convert a thumb drag into the same bounded document position, including a track click's centered grab."""
function terminal_scroll_pointer!(state::TerminalScrollState,geometry,row::Int,grab::Int;now::Real=time_ns()/1e9)
    capacity=geometry.height-geometry.thumb_height
    offset=clamp(row-geometry.top-grab,0,capacity)
    target=capacity==0 ? 0 : floor(Int,offset*geometry.maximum/capacity+0.5)
    terminal_scroll_to!(state,target;now)
    nothing
end

"""Own only scrollbar hits and active drags; release cannot activate an unrelated menu row."""
function terminal_scroll_mouse!(state::TerminalScrollState,width::Int,event::Tachikoma.MouseEvent;
        left::Int=1,top::Int=1,now::Real=time_ns()/1e9)
    x=event.x-left+1;y=event.y-top+1
    geometry=terminal_scroll_geometry(state,width;now)
    captured=!isnothing(state.grab)
    if captured
        if event.action==Tachikoma.mouse_release
            state.grab=nothing
        elseif !isnothing(geometry)
            terminal_scroll_pointer!(state,geometry,y,state.grab::Int;now)
        end
    elseif event.action==Tachikoma.mouse_press && event.button==Tachikoma.mouse_left &&
            !isnothing(geometry) && x==geometry.column && geometry.top<=y<geometry.top+geometry.height
        inside=geometry.thumb_top<=y<geometry.thumb_top+geometry.thumb_height
        grab=inside ? y-geometry.thumb_top : fld(geometry.thumb_height,2)
        inside || terminal_scroll_pointer!(state,geometry,y,grab;now)
        state.grab=grab
        terminal_scroll_active!(state,true;now)
        captured=true
    end
    if isnothing(state.grab)
        hover=terminal_scroll_geometry(state,width;now,include_hidden=true)
        terminal_scroll_active!(state,!isnothing(hover) && x==hover.column && hover.top<=y<hover.top+hover.height;now)
    end
    captured
end
