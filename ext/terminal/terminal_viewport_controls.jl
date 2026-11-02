"""Create one real fullscreen interaction owner around the current App queue and terminal."""
function terminal_viewport!(app::App)
    viewport=app.menus.viewport
    if isnothing(viewport)
        owner=Ref(nothing)
        notify=epoch->enqueue_event!(app,TaskEvent(:terminal_selection_expired,TerminalSelectionExpiry(;owner,epoch)))
        selection=TerminalSelectionControl(;copy=text->terminal_selection_clipboard(app,text),on_timer=notify)
        viewport=TerminalViewport(;scroll=terminal_scroll_host(app),selection,owner)
        app.menus.viewport=viewport
    end
    viewport
end

terminal_viewport_component(app::App)=(app.page,copy(app.menus.path),app.menus.generation)
function terminal_viewport_wheel(app::App,event::MouseEvent)
    viewport=app.menus.viewport
    isnothing(viewport) ? (event.button==Tachikoma.mouse_scroll_up ? -1 : event.button==Tachikoma.mouse_scroll_down ? 1 : 0) : viewport.wheel_delta
end

"""Read the actual painted framebuffer without interpreting text as terminal instructions."""
function terminal_viewport_buffer_rows(buffer::Tachikoma.Buffer,area::Rect)
    [[Tachikoma.Span(string(cell.char,cell.suffix),cell.style) for column in area.x:area.x+area.width-1
        for cell in (buffer.content[Tachikoma.buf_index(buffer,column,row)],) if cell.char!='\0']
        for row in area.y:area.y+area.height-1]
end

function terminal_viewport_selection_view(app::App,screen)
    viewport=terminal_viewport!(app);snapshot=viewport.scroll.control.snapshot
    TerminalSelectionView(;document=snapshot.document,screen,area=app.area,
        document_area=snapshot.clip,top=snapshot.top,document_press=!viewport.search.active)
end

"""Overlay scrollbar and selection on native cells while leaving archived text and image ownership unchanged."""
function terminal_viewport_draw!(app::App,frame::Frame,scene)
    viewport=terminal_viewport!(app);fullscreen=terminal_presentation_mode(app)==:fullscreen
    if fullscreen
        image_rows=terminal_viewport_image_anchors(app,scene)
        runtime=app.menus.theme_runtime
        terminal_scroll_control_draw!(viewport.scroll.control,frame.buffer;
            style=token->isnothing(runtime) ? pi_style(token) : theme_style(runtime,token),
            image_rows=image_rows.document)
        terminal_search_host_highlight!(app,frame;image_rows=image_rows.screen)
        viewport.indicator=isnothing(runtime) ? nothing : terminal_scroll_indicator(viewport.scroll.control,frame.buffer;
            theme=runtime,bindings=["ctrl+end"],image_rows=image_rows.screen)
        terminal_scroll_indicator_draw!(viewport.indicator,frame.buffer)
        terminal_search_host_overlay!(app,frame)
    else
        viewport.indicator=nothing
    end
    screen=terminal_viewport_buffer_rows(frame.buffer,frame.area)
    view=terminal_viewport_selection_view(app,screen)
    terminal_selection_publish!(viewport.selection,view;owner=string(app.session.runtime.id),fullscreen,
        copy_on_select=menu_preference(app,"fullscreen-copy-on-select","true")=="true")
    if fullscreen
        rows=terminal_selection_control_lines(viewport.selection)
        startup_document_draw!(frame.buffer,frame.area.x,frame.area.y,frame.area.width,rows)
    end
    nothing
end

"""Use the genuine absolute document anchor for timed selection scrolling, not a stale distance from end."""
function terminal_viewport_selection_scroll!(app::App,direction::Int)
    viewport=terminal_viewport!(app)
    terminal_scroll_control_by!(viewport.scroll.control,direction)
    snapshot=terminal_scroll_host_publish!(viewport.scroll,app)
    previous=viewport.selection.view
    next=TerminalSelectionView(;document=snapshot.document,screen=previous.screen,area=previous.area,
        document_area=snapshot.clip,top=snapshot.top,document_press=!viewport.search.active)
    viewport.selection.view=next
    next
end
function terminal_selection_expired!(app::App,event::TerminalSelectionExpiry)
    viewport=app.menus.viewport
    if !isnothing(viewport) && viewport.owner===event.owner && !app.operations.closing[]
        terminal_selection_poll!(viewport.selection,event.epoch,direction->terminal_viewport_selection_scroll!(app,direction))
    end
    nothing
end
function terminal_scrollbar_expired!(app::App,event::TerminalScrollbarExpiry)
    viewport=app.menus.viewport
    isnothing(viewport) || terminal_scroll_host_expire!(viewport.scroll,event)
    nothing
end

"""Invalidate captures and cancel owned timers before terminal or App teardown."""
function close_terminal_viewport!(app::App)
    viewport=app.menus.viewport
    if !isnothing(viewport)
        terminal_viewport_tracking!(app,:off)
        terminal_search_close!(viewport.search)
        terminal_selection_close!(viewport.selection)
        terminal_scroll_control_close!(viewport.scroll.control)
        viewport.component=nothing;viewport.press=nothing
        app.menus.viewport=nothing
    end
    nothing
end

function terminal_viewport_end!(app::App)
    viewport=app.menus.viewport
    if !isnothing(viewport)
        terminal_scroll_control_end!(viewport.scroll.control)
        terminal_scroll_host_publish!(viewport.scroll,app)
    end
    app.scroll=0
    nothing
end

"""A settings transaction updates the live native owner; rollback uses the same real operation."""
function apply_setting_effect!(app::App,::Val{Symbol("fullscreen-scrollbar")},value::AbstractString)
    terminal_scroll_host_setting!(terminal_viewport!(app).scroll,"fullscreen-scrollbar",value)
end
function apply_setting_effect!(app::App,::Val{Symbol("fullscreen-wheel-scroll-lines")},value::AbstractString)
    terminal_scroll_host_setting!(terminal_viewport!(app).scroll,"fullscreen-wheel-scroll-lines",value)
end
function apply_setting_effect!(app::App,::Val{Symbol("fullscreen-copy-on-select")},value::AbstractString)
    valid=value in ("true","false")
    valid && (terminal_viewport!(app).selection.state.copy_on_select=value=="true")
    (ok=valid,reason=valid ? "" : "Invalid fullscreen copy-on-select value")
end

"""Only an existing selection with manual copying enabled supersedes copying the last assistant reply."""
function terminal_viewport_copy!(app::App)
    viewport=app.menus.viewport
    manual=terminal_presentation_mode(app)==:fullscreen && menu_preference(app,"fullscreen-copy-on-select","true")=="false"
    handled=manual && !isnothing(viewport) && !isnothing(terminal_selection_text(viewport.selection.state,viewport.selection.view))
    handled && terminal_selection_copy_active!(viewport.selection)
    handled
end

"""Completed selections survive focus loss, but active gestures and stale component presses do not."""
function terminal_viewport_focus_out!(app::App)
    viewport=app.menus.viewport
    if !isnothing(viewport)
        viewport.search.hovered=0
        terminal_selection_focus_lost!(viewport.selection.state)
        terminal_selection_schedule!(viewport.selection)
        terminal_scroll_control_focus_out!(viewport.scroll.control)
        viewport.component=nothing;viewport.press=nothing;viewport.moved=false
        terminal_viewport_clear_press!(app)
    end
    nothing
end

"""Respect original component viewport capture rather than stealing open completion/menu navigation."""
function terminal_viewport_defers(app::App)
    tree=app.menus.tree_menu;resume=app.menus.resume_menu
    if terminal_search_host_focused(app)
        false
    elseif app.page==:chat
        chat_host_completion_open(app)
    elseif app.page==:pi_menu
        if app.menus.path==["thinking"]
            false
        elseif app.menus.path==["tree"] && !isnothing(tree)
            tree_captures_viewport(tree)
        elseif app.menus.path==["resume"] && !isnothing(resume)
            resume_captures_viewport(resume)
        else
            true
        end
    else
        true
    end
end

"""Fullscreen PageUp/PageDown shadow editor movement only when the focused component permits it."""
function terminal_viewport_key!(app::App,event::KeyEvent,raw::AbstractVector{UInt8})
    packet=menu_packet(event,raw)
    handled=false
    if packet in ("\e[O","\e[I")
        packet=="\e[O" && terminal_viewport_focus_out!(app)
        handled=true
    elseif terminal_search_host_key!(app,event,raw;viewport_owned=terminal_prompt_packet(packet).direction!=0)
        handled=true
    elseif terminal_prompt_key!(app,packet)
        handled=true
    elseif terminal_presentation_mode(app)==:fullscreen && !terminal_viewport_defers(app)
        viewport=terminal_viewport!(app);control=viewport.scroll.control
        action=terminal_viewport_action(packet)
        if action==:top
            terminal_scroll_control_to!(control,0);handled=true
        elseif action==:bottom
            terminal_scroll_control_end!(control);handled=true
        elseif action in (:page_up,:page_down)
            amount=max(1,control.snapshot.rect.height-4)
            terminal_scroll_control_by!(control,action==:page_up ? -amount : amount);handled=true
        end
        handled && terminal_scroll_host_publish!(viewport.scroll,app)
    end
    handled
end

"""Discard only the captured component's pressed-item state when no real click occurred."""
function terminal_viewport_clear_press!(app::App)
    app.menus.pressed=nothing
    for menu in (app.menus.theme_menu,app.menus.thinking_menu)
        isnothing(menu) || (menu.pressed=nothing)
    end
    completion=app.menus.chat_completion
    if !isnothing(completion)
        completion.pressed=nothing;completion.press_position=nothing
    end
    nothing
end

"""Dispatch real components first, without permitting a consumed gesture to become a text selection."""
function terminal_viewport_mouse!(app::App,event::MouseEvent)
    viewport=terminal_viewport!(app)
    fullscreen=terminal_presentation_mode(app)==:fullscreen
    viewport.wheel_delta=fullscreen ? terminal_wheel_delta!(viewport.scroll.wheel,event) : 0
    wheel=event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
    handled=false
    if !fullscreen
        handled=page_mouse!(app,Val(app.page),event)===true
    elseif !wheel && !isnothing(viewport.component)
        same=viewport.component==terminal_viewport_component(app)
        viewport.moved=viewport.moved || viewport.press!=(event.x,event.y)
        if same && !(event.action==Tachikoma.mouse_release && viewport.moved)
            terminal_viewport_component_mouse!(app,event;click=event.action==Tachikoma.mouse_release)
        end
        if event.action==Tachikoma.mouse_release || !same
            terminal_viewport_clear_press!(app)
            viewport.component=nothing;viewport.press=nothing;viewport.moved=false
        end
        handled=true
    else
        search=wheel ? (handled=false,changed=false,inside=terminal_search_host_inside(app,event.x,event.y)) : terminal_search_host_mouse!(app,event)
        indicator=!search.inside && !wheel && !search.handled && terminal_scroll_indicator_mouse!(viewport.indicator,viewport.scroll.control,event)
        blocked=search.inside || viewport.search.active && isnothing(viewport.scroll.control.scroll.grab)
        bar=wheel || indicator || search.handled ? (handled=false,) : terminal_scroll_control_mouse!(viewport.scroll.control,event;blocked)
        handled=search.handled || indicator || bar.handled
        if bar.handled && event.action==Tachikoma.mouse_press
            terminal_selection_component_press!(viewport.selection)
        end
        if !handled
            component=terminal_viewport_component(app)
            handled=!search.inside && terminal_viewport_component_mouse!(app,event)
            if handled && !wheel && event.action==Tachikoma.mouse_press
                terminal_selection_component_press!(viewport.selection)
                viewport.component=component;viewport.press=(event.x,event.y);viewport.moved=false
            elseif !handled && wheel
                handled=terminal_scroll_control_wheel!(viewport.scroll.control,event,viewport.wheel_delta).handled
                viewport.search.active && terminal_scroll_control_mouse!(viewport.scroll.control,event;blocked=true)
            elseif !handled && (viewport.selection.state.active || selection_inside(app.area,event.x,event.y))
                click=terminal_viewport_selection_click(viewport.selection,event)
                if click && !search.inside && terminal_viewport_component_mouse!(app,event;click=true)
                    terminal_selection_component_press!(viewport.selection)
                    handled=true
                else
                    handled=terminal_selection_handle!(viewport.selection,event)
                end
            end
        end
        terminal_scroll_host_publish!(viewport.scroll,app)
    end
    handled
end

"""Match the source multiplexer policy without enabling high-volume pointer tracking inside a declared mux."""
function terminal_viewport_tracking_mode(environment=ENV)
    term=lowercase(get(environment,"TERM",""))
    any(key->haskey(environment,key),("TMUX","ZELLIJ","STY")) || startswith(term,"tmux") || startswith(term,"screen") ? :buttons : :all
end
terminal_viewport_tracking_sequence(mode::Symbol)=mode==:all ? "\e[?1000h\e[?1002h\e[?1003h\e[?1004h\e[?1006h" :
    mode==:buttons ? "\e[?1003l\e[?1000h\e[?1002h\e[?1004h\e[?1006h" : "\e[?1006l\e[?1004l\e[?1003l\e[?1002l\e[?1000l"

"""Own focus and hover reporting across actual screen mode, external terminal leases and teardown."""
function terminal_viewport_tracking!(app::App,mode::Symbol=terminal_presentation_mode(app);force::Bool=false)
    terminal=app.settings.terminal
    if !isnothing(terminal)
        desired=mode==:fullscreen && terminal.mouse_enabled ? terminal_viewport_tracking_mode() : :off
        viewport=desired==:off ? app.menus.viewport : terminal_viewport!(app)
        sink=terminal.io isa PresentationIO ? terminal.io.sink : terminal.io
        if force || isnothing(viewport) || viewport.tracking!=desired || viewport.tracking_sink!==sink
            write(sink,terminal_viewport_tracking_sequence(desired));flush(sink)
            if !isnothing(viewport)
                viewport.tracking=desired;viewport.tracking_sink=sink
            end
        end
    end
    nothing
end

"""A real presentation switch cancels interaction capture without losing the document's absolute anchor."""
function terminal_viewport_mode!(app::App,mode::Symbol)
    viewport=app.menus.viewport
    if !isnothing(viewport)
        snapshot=viewport.scroll.control.snapshot
        mode==:fullscreen || terminal_search_close!(viewport.search)
        terminal_scroll_control_layout!(viewport.scroll.control,snapshot.document,snapshot.rect;
            owner=snapshot.owner,revision=snapshot.revision,clip=snapshot.clip,presentation=mode)
        terminal_selection_publish!(viewport.selection,viewport.selection.view;owner=string(app.session.runtime.id),
            fullscreen=mode==:fullscreen,copy_on_select=menu_preference(app,"fullscreen-copy-on-select","true")=="true")
        viewport.component=nothing;viewport.press=nothing;viewport.moved=false
    end
    nothing
end

"""A raw release is not a synthesized click, and must not terminate another component's selection."""
function terminal_viewport_component_mouse!(app::App,event::MouseEvent;click::Bool=false)
    result=app.page==:chat ? page_mouse!(app,Val(:chat),event;click) : page_mouse!(app,Val(app.page),event)
    handled=result===true
    handled && terminal_search_host_component_focus!(app,event;click)
    handled
end
function terminal_viewport_selection_click(control::TerminalSelectionControl,event::MouseEvent)
    state=control.state;anchor=state.anchor
    clicked=false
    if event.action==Tachikoma.mouse_release && state.active && !state.dragged && !isnothing(anchor)
        point=selection_point(control.view,event.x,event.y,anchor.document)
        clicked=anchor.row==point.row && anchor.column==point.column && anchor.document==point.document
    end
    clicked
end

"""Only visible protocol anchor rows suppress text overlays, not an image's whole pixel footprint."""
function terminal_viewport_image_anchors(app::App,scene)
    document=Set{Int}();screen=Set{Int}()
    plan=app.transcript.display_plan
    if !isnothing(plan) && plan.protocol==:kitty && scene.archive_height>0
        first_row=scene.first_archive_row;last_row=first_row+scene.archive_height-1
        for placement in plan.placements
            anchor=max(first_row,placement.row)
            if anchor<=min(last_row,placement.row+placement.image.rows-1)
                push!(document,scene.startup_rows+anchor)
                push!(screen,app.area.y+scene.archive_top-1+anchor-first_row)
            end
        end
    end
    (;document,screen)
end
