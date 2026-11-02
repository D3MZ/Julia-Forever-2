public TerminalScrollHost, TerminalScrollbarExpiry, terminal_scroll_host, terminal_scroll_host_scene!
public terminal_scroll_host_setting!, terminal_scroll_host_expire!, terminal_scroll_host_publish!

"""Read effective persisted preferences once and post timer notifications through the real owner queue."""
function terminal_scroll_host(app::App;schedule=scroll_control_schedule,cancel=scroll_control_cancel)
    owner=Ref(nothing)
    notify=generation->enqueue_event!(app,Tachikoma.TaskEvent(:terminal_scrollbar_expired,TerminalScrollbarExpiry(;owner,generation)))
    control=TerminalScrollControl(;schedule,cancel,notify)
    host=TerminalScrollHost(;control,owner)
    terminal_scroll_host_setting!(host,"fullscreen-scrollbar",menu_preference(app,"fullscreen-scrollbar","auto"))
    terminal_scroll_host_setting!(host,"fullscreen-wheel-scroll-lines",menu_preference(app,"fullscreen-wheel-scroll-lines","auto"))
    host
end

"""Apply only implemented native runtime settings; persistence and rollback remain with the settings owner."""
function terminal_scroll_host_setting!(host::TerminalScrollHost,id::AbstractString,value::AbstractString;now::Real=time_ns()/1e9)
    if id=="fullscreen-scrollbar"
        terminal_scroll_control_mode!(host.control,Symbol(value);now)
    elseif id=="fullscreen-wheel-scroll-lines"
        terminal_wheel_setting!(host.wheel,value)
    else
        (ok=false,reason="Not a viewport-owned setting")
    end
end

"""Ignore stale notifications from replaced App viewport owners before checking timer generations."""
function terminal_scroll_host_expire!(host::TerminalScrollHost,event::TerminalScrollbarExpiry;now::Real=time_ns()/1e9)
    event.owner===host.owner && terminal_scroll_control_expire!(host.control,event.generation;now)
end

"""Publish the compatibility offset only after an explicit native scroll action or projection."""
function terminal_scroll_host_publish!(host::TerminalScrollHost,app::App)
    host.control.snapshot.fullscreen && (app.scroll=host.control.snapshot.distance_from_end)
    host.control.snapshot
end

"""Compose the real document and dock after reserved-width rendering; only document width is reduced."""
function terminal_scroll_host_scene!(host::TerminalScrollHost,app::App,document::Vector{Vector{Tachikoma.Span}},
        parts::Vector{StartupDockPart},width::Integer,height::Integer;owner::AbstractString=string(app.session.runtime.id),
        revision::UInt=app.transcript.revision,presentation::Symbol=terminal_presentation_mode(app),
        x::Integer=app.area.x,y::Integer=app.area.y,now::Real=time_ns()/1e9)
    shape=startup_scene(document,parts,height;scroll=0)
    rectangle=Tachikoma.Rect(Int(x),Int(y),max(0,Int(width)),shape.document_height)
    clip=Tachikoma.Rect(Int(x),Int(y),max(0,Int(width)),max(0,min(Int(height),shape.document_height)))
    snapshot=terminal_scroll_control_layout!(host.control,document,rectangle;owner,revision,clip,presentation,
        legacy_distance=app.scroll,now)
    terminal_scroll_host_publish!(host,app)
    scene=startup_scene(document,parts,height;scroll=snapshot.distance_from_end)
    (;scene...,viewport=snapshot)
end
