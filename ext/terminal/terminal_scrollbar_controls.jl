# Native fullscreen scrollbar ownership. The source-equivalent pure state service stays independent.
public TerminalScrollControl, TerminalScrollViewport, terminal_scroll_control_width
public terminal_scroll_control_layout!, terminal_scroll_control_to!, terminal_scroll_control_by!, terminal_scroll_control_end!
public terminal_scroll_control_mouse!, terminal_scroll_control_draw!, terminal_scroll_control_expire!
public terminal_scroll_control_mode!, terminal_scroll_control_close!, terminal_scroll_control_snapshot, terminal_scroll_control_focus_out!

scroll_control_schedule(callback, seconds::Real) = Timer(_ -> callback(), seconds)
scroll_control_cancel(::Nothing) = nothing
scroll_control_cancel(timer::Timer) = close(timer)

"""An owner-projected viewport with copied rows; consumers must treat its document as read-only."""
Base.@kwdef struct TerminalScrollViewport
    owner::String = ""
    epoch::UInt = UInt(0)
    revision::UInt = UInt(0)
    document::Vector{Vector{Tachikoma.Span}} = Vector{Tachikoma.Span}[]
    rect::Tachikoma.Rect = Tachikoma.Rect()
    content_rect::Tachikoma.Rect = Tachikoma.Rect()
    visible_content_rect::Tachikoma.Rect = Tachikoma.Rect()
    clip::Tachikoma.Rect = Tachikoma.Rect()
    top::Int = 0
    first_row::Int = 1
    content_height::Int = 0
    distance_from_end::Int = 0
    following::Bool = true
    fullscreen::Bool = true
end

"""Own one absolute document anchor and an expiry notification, never mutate UI from a timer."""
Base.@kwdef mutable struct TerminalScrollControl{S,C,N}
    scroll::TerminalScrollState = TerminalScrollState()
    snapshot::TerminalScrollViewport = TerminalScrollViewport()
    schedule::S = scroll_control_schedule
    cancel::C = scroll_control_cancel
    notify::N = Returns(nothing)
    timer::Any = nothing
    timer_due::Float64 = -Inf
    timer_generation::UInt = UInt(0)
    published_distance::Int = 0
    initialized::Bool = false
    closed::Bool = false
end

terminal_scroll_control_width(control::TerminalScrollControl, width::Integer, presentation::Symbol=:fullscreen) =
    presentation==:fullscreen ? terminal_scroll_content_width(control.scroll,max(0,Int(width))) : max(0,Int(width))
terminal_scroll_control_distance(control::TerminalScrollControl) = max(0,terminal_scroll_max(control.scroll)-control.scroll.top)
terminal_scroll_control_snapshot(control::TerminalScrollControl) = control.snapshot

function terminal_scroll_control_cancel_timer!(control::TerminalScrollControl)
    control.timer_generation+=UInt(1)
    control.cancel(control.timer)
    control.timer=nothing
    control.timer_due=-Inf
    nothing
end

"""Arm only a changed auto expiry; the callback posts a generation for the UI owner to handle."""
function terminal_scroll_control_timer!(control::TerminalScrollControl;now::Real=time_ns()/1e9)
    state=control.scroll
    desired=!control.closed && control.snapshot.fullscreen && state.mode==:auto && !state.active &&
        state.content>state.viewport && isfinite(state.visible_until) && state.visible_until>now ? state.visible_until : -Inf
    if desired!=control.timer_due
        terminal_scroll_control_cancel_timer!(control)
        if isfinite(desired)
            control.timer_due=desired
            generation=control.timer_generation
            control.timer=control.schedule(() -> control.notify(generation),max(0.0,desired-Float64(now)))
        end
    end
    nothing
end

"""Accept expiry on the UI thread; stale, closed and early notifications cannot alter ownership."""
function terminal_scroll_control_expire!(control::TerminalScrollControl,generation::UInt;now::Real=time_ns()/1e9)
    expired=!control.closed && control.snapshot.fullscreen && generation==control.timer_generation &&
        isfinite(control.timer_due) && now>=control.timer_due
    if expired
        terminal_scroll_control_cancel_timer!(control)
    end
    expired
end

function terminal_scroll_control_mode!(control::TerminalScrollControl,mode::Symbol;now::Real=time_ns()/1e9)
    valid=mode in (:auto,:always,:hidden) && !control.closed
    if valid
        terminal_scrollbar_mode!(control.scroll,mode;now)
        terminal_scroll_control_timer!(control;now)
    end
    (ok=valid,reason=valid ? "" : "Scrollbar mode is invalid or closed")
end

"""Keep screen clipping separate from the full logical document and its reserved track column."""
function terminal_scroll_control_clip(rect::Tachikoma.Rect,clip::Tachikoma.Rect)
    x=max(rect.x,clip.x);y=max(rect.y,clip.y)
    Tachikoma.Rect(x,y,max(0,min(rect.x+rect.width,clip.x+clip.width)-x),
        max(0,min(rect.y+rect.height,clip.y+clip.height)-y))
end

"""Publish new rows without changing a manual absolute anchor when content is appended."""
function terminal_scroll_control_layout!(control::TerminalScrollControl,document::Vector{Vector{Tachikoma.Span}},
        rect::Tachikoma.Rect;owner::AbstractString="",revision::UInt=UInt(0),clip::Tachikoma.Rect=rect,
        presentation::Symbol=:fullscreen,legacy_distance::Union{Nothing,Integer}=nothing,now::Real=time_ns()/1e9)
    previous=control.snapshot
    if !control.closed
        fullscreen=presentation==:fullscreen
        replaced=!control.initialized || previous.owner!=owner
        epoch=previous.epoch+UInt(replaced || previous.fullscreen!=fullscreen)
        if replaced
            terminal_scroll_control_cancel_timer!(control)
            control.scroll=TerminalScrollState(;mode=control.scroll.mode)
            control.published_distance=0
        elseif !isnothing(legacy_distance) && legacy_distance!=control.published_distance && fullscreen
            # Interpret an explicitly changed compatibility offset against the PREVIOUS layout.
            terminal_scroll_to!(control.scroll,terminal_scroll_max(control.scroll)-max(0,Int(legacy_distance));now)
        end
        if previous.fullscreen && !fullscreen
            control.scroll.grab=nothing
            terminal_scroll_active!(control.scroll,false;now)
        end
        terminal_scroll_layout!(control.scroll,length(document),max(0,rect.height))
        if replaced && !isnothing(legacy_distance) && legacy_distance>0 && fullscreen
            terminal_scroll_to!(control.scroll,terminal_scroll_max(control.scroll)-Int(legacy_distance);now)
        end
        width=terminal_scroll_control_width(control,rect.width,presentation)
        content=Tachikoma.Rect(rect.x,rect.y,width,max(0,rect.height))
        distance=terminal_scroll_control_distance(control)
        control.snapshot=TerminalScrollViewport(;owner=String(owner),epoch,revision,document=[copy(row) for row in document],
            rect,content_rect=content,visible_content_rect=terminal_scroll_control_clip(content,clip),
            clip=terminal_scroll_control_clip(rect,clip),top=control.scroll.top,
            first_row=control.scroll.top+1,content_height=length(document),distance_from_end=distance,
            following=control.scroll.following,fullscreen)
        control.published_distance=distance
        control.initialized=true
        terminal_scroll_control_timer!(control;now)
    end
    control.snapshot
end

"""Refresh only anchor fields after user scrolling; reuse the already frozen document rows."""
function terminal_scroll_control_publish!(control::TerminalScrollControl)
    old=control.snapshot
    distance=terminal_scroll_control_distance(control)
    control.snapshot=TerminalScrollViewport(;owner=old.owner,epoch=old.epoch,revision=old.revision,document=old.document,
        rect=old.rect,content_rect=old.content_rect,visible_content_rect=old.visible_content_rect,clip=old.clip,
        top=control.scroll.top,first_row=control.scroll.top+1,
        content_height=old.content_height,distance_from_end=distance,following=control.scroll.following,fullscreen=old.fullscreen)
    control.published_distance=distance
    control.snapshot
end

"""Set an absolute document top for keys or selection autoscroll; regular mode owns its own scrollback."""
function terminal_scroll_control_to!(control::TerminalScrollControl,top::Integer;disable_follow::Bool=false,now::Real=time_ns()/1e9)
    if !control.closed && control.snapshot.fullscreen
        terminal_scroll_to!(control.scroll,top;disable_follow,now)
        terminal_scroll_control_publish!(control)
        terminal_scroll_control_timer!(control;now)
    end
    control.snapshot
end

"""Return unconsumed logical lines for scroll chaining while preserving source follow-end rules."""
function terminal_scroll_control_by!(control::TerminalScrollControl,lines::Integer;now::Real=time_ns()/1e9)
    remaining=Int(lines)
    if !control.closed && control.snapshot.fullscreen && lines!=0
        state=control.scroll
        start=state.following ? terminal_scroll_max(state) : state.top
        terminal_scroll_control_to!(control,start+Int(lines);now)
        remaining-=state.top-start
    end
    remaining
end

"""Route only visible scrollbar presses and captures; an owner clears selection on a new capture."""
function terminal_scroll_control_mouse!(control::TerminalScrollControl,event::Tachikoma.MouseEvent;
        blocked::Bool=false,now::Real=time_ns()/1e9)
    before=control.scroll.grab
    handled=false
    if !control.closed && control.snapshot.fullscreen
        viewport=control.snapshot
        clipped=viewport.clip
        inside=clipped.x<=event.x<clipped.x+clipped.width && clipped.y<=event.y<clipped.y+clipped.height
        wheel=event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
        if blocked
            terminal_scroll_active!(control.scroll,false;now)
        elseif !wheel && !isnothing(before) && !(clipped.x<=viewport.rect.x+viewport.rect.width-1<clipped.x+clipped.width)
            # An ongoing capture is consumed, but a clipped-away track cannot move the document.
            if event.action==Tachikoma.mouse_release
                control.scroll.grab=nothing
                terminal_scroll_active!(control.scroll,false;now)
            end
            handled=true
        elseif !wheel && (!isnothing(before) || inside)
            handled=terminal_scroll_mouse!(control.scroll,viewport.rect.width,event;left=viewport.rect.x,top=viewport.rect.y,now)
        elseif isnothing(before)
            terminal_scroll_active!(control.scroll,false;now)
        end
        terminal_scroll_control_publish!(control)
        terminal_scroll_control_timer!(control;now)
    end
    (handled,captured=!isnothing(control.scroll.grab),started=isnothing(before)&&!isnothing(control.scroll.grab),snapshot=control.snapshot)
end

"""Cancel expiry and capture on owner teardown; late callbacks never reactivate a closed controller."""
function terminal_scroll_control_close!(control::TerminalScrollControl)
    terminal_scroll_control_cancel_timer!(control)
    control.scroll.grab=nothing
    control.scroll.active=false
    control.closed=true
    nothing
end

"""Drop pointer ownership on terminal focus loss without changing the absolute scroll position."""
function terminal_scroll_control_focus_out!(control::TerminalScrollControl;now::Real=time_ns()/1e9)
    if !control.closed
        control.scroll.grab=nothing
        terminal_scroll_active!(control.scroll,false;now)
        terminal_scroll_control_timer!(control;now)
    end
    nothing
end

"""Resume following output explicitly, including a same-position transition from suppressed follow."""
function terminal_scroll_control_end!(control::TerminalScrollControl;now::Real=time_ns()/1e9)
    if !control.closed && control.snapshot.fullscreen
        maximum=terminal_scroll_max(control.scroll)
        changed=control.scroll.top!=maximum || !control.scroll.following
        terminal_scroll_to!(control.scroll,maximum;now)
        changed && terminal_scroll_activity!(control.scroll,now)
        terminal_scroll_control_publish!(control)
        terminal_scroll_control_timer!(control;now)
    end
    control.snapshot
end
