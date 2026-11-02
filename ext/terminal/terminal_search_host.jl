"""Read the actual native overlay focus without changing the underlying menu or editor owner."""
function terminal_search_host_focused(app::App)
    viewport=app.menus.viewport
    !isnothing(viewport) && terminal_presentation_mode(app)==:fullscreen && terminal_search_focused(viewport.search)
end

"""Keep bracketed paste with the focused query, including fragmented shortcut-looking contents."""
function terminal_search_host_pasting(app::App,packet::AbstractString)
    viewport=app.menus.viewport
    terminal_search_host_focused(app) && !isnothing(viewport) &&
        (viewport.search.input.pasting || occursin("\e[200~",packet))
end

"""Use the last painted overlay bounds for pointer dispatch, not a guessed document rectangle."""
function terminal_search_host_inside(app::App,x::Int,y::Int)
    viewport=app.menus.viewport
    !isnothing(viewport) && viewport.search.active && selection_inside(viewport.search.bounds,x,y)
end

"""Mirror focused native component results while leaving transcript selection and overlay chrome unfocused."""
function terminal_search_host_component_focus!(app::App,event::MouseEvent;click::Bool=false)
    viewport=app.menus.viewport
    if !isnothing(viewport) && viewport.search.active
        wheel=event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
        delegated=app.page==:chat || app.page==:pi_menu && length(app.menus.path)>1 && first(app.menus.path)=="settings"
        if click || event.action==Tachikoma.mouse_press && !wheel || wheel && delegated
            terminal_search_focus!(viewport.search,false)
        end
    end
    nothing
end

"""Apply search reveal before the real scene slices its document, so one frame has consistent geometry."""
function terminal_search_host_refresh!(app::App,host::TerminalScrollHost)
    viewport=app.menus.viewport
    if !isnothing(viewport)
        target=terminal_search_refresh!(viewport.search,host.control.snapshot)
        isnothing(target) || terminal_scroll_control_to!(host.control,target;disable_follow=true)
    end
    host.control.snapshot
end

"""Dispatch the actual focused query before global application shortcuts without swallowing viewport movement."""
function terminal_search_host_key!(app::App,event::KeyEvent,raw::AbstractVector{UInt8};
        viewport_owned::Bool=false,kitty::Bool=!isnothing(app.settings.terminal) && app.settings.terminal.kitty_keyboard)
    packet=menu_packet(event,raw)
    viewport=terminal_viewport!(app)
    handled=false
    if terminal_presentation_mode(app)==:fullscreen
        if viewport.search.active && viewport.search.owner!=string(app.session.runtime.id)
            terminal_search_close!(viewport.search)
        end
        movement=viewport_owned || terminal_viewport_action(packet) in (:top,:bottom,:page_up,:page_down)
        result=terminal_search_key!(viewport.search,viewport.scroll.control.snapshot,packet;
            viewport_owned=movement,kitty)
        handled=result.handled
    end
    handled
end

"""Expose overlay ownership separately from handled navigation so selection remains screen-based."""
function terminal_search_host_mouse!(app::App,event::MouseEvent)
    state=terminal_viewport!(app).search
    type=event.action==Tachikoma.mouse_press ? :press : event.action==Tachikoma.mouse_release ? :release :
        event.button==Tachikoma.mouse_left ? :drag : :move
    button=event.button==Tachikoma.mouse_left ? :left : :other
    terminal_search_mouse!(state,event.x,event.y;button,action=type)
end

"""Keep match paint separate from scrollbar/indicator/overlay/selection composition order."""
function terminal_search_host_highlight!(app::App,frame::Frame;image_rows::AbstractSet{Int}=Set{Int}())
    viewport=terminal_viewport!(app);runtime=app.menus.theme_runtime;control=viewport.scroll.control
    if !isnothing(runtime)
        geometry=terminal_scroll_geometry(control.scroll,control.snapshot.rect.width)
        column=isnothing(geometry) ? nothing : control.snapshot.rect.x+control.snapshot.rect.width-1
        terminal_search_highlight!(viewport.search,frame.buffer,control.snapshot;theme=runtime,scrollbar_column=column,image_rows)
    end
    nothing
end

"""Draw only an active fullscreen search; the parent's scene retains selection and image ownership."""
function terminal_search_host_overlay!(app::App,frame::Frame)
    viewport=terminal_viewport!(app);runtime=app.menus.theme_runtime
    if viewport.scroll.control.snapshot.fullscreen
        terminal_search_overlay_draw!(viewport.search,frame.buffer;area=frame.area,
            decorate=!isnothing(runtime) && runtime.active.bold,hardware=terminal_search_focused(viewport.search) && menu_preference(app,"show-hardware-cursor","false")=="true")
    end
    nothing
end

"""Return the actual focused query cursor without advertising the underlying editor's caret."""
function terminal_search_host_cursor(app::App)
    viewport=app.menus.viewport;cursor=nothing
    if !isnothing(viewport) && terminal_search_focused(viewport.search) && viewport.scroll.control.snapshot.fullscreen
        search=viewport.search;bounds=terminal_search_bounds!(search,app.area)
        terminal_search_lines(search,bounds.width)
        column=search.cursor_column
        if !isnothing(column)
            x=bounds.x+1+column;y=bounds.y+1
            if app.area.x<=x<app.area.x+app.area.width && app.area.y<=y<app.area.y+app.area.height
                cursor=(x,y)
            end
        end
    end
    cursor
end
