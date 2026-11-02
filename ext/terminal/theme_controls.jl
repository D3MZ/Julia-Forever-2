"""Load a private native palette without consulting provider credentials."""
function initialize_theme_controls!(app::App; fallback::AbstractString="system")
    catalog = theme_catalog(joinpath(app.settings.directory, "themes"))
    runtime = theme_restore(catalog, joinpath(app.settings.directory, "terminal-settings.json"); fallback)
    app.menus.theme_runtime = runtime
    app.menus.preferences["theme"] = runtime.committed
    activate_theme_runtime!(runtime)
    refresh_theme_controls!(app)
    isempty(runtime.last_error) || (app.status = runtime.last_error)
    nothing
end

function refresh_theme_controls!(app::App)
    app.input.style = pi_style(:text)
    app.transcript.display_key = nothing
    app.transcript.preview_dirty = true
    app.transcript.revision = typemax(UInt)
    nothing
end

"""Contain real filesystem failures in the theme save callback, without claiming persistence."""
function persist_terminal_theme(path, setting)
    prepared = prepare_terminal_preference(path, "theme", setting;
        validate=(name, value) -> !isempty(value))
    prepared.ok ? commit_terminal_preference!(prepared.plan) : (ok=false, reason=prepared.reason)

end

function theme_control_event!(app::App, kind, setting, result)
    input = app.settings.theme_input
    if !isnothing(input)
        theme_lifecycle_selection!(input.lifecycle; preview=kind == :preview, query=kind != :preview)
    end
    refresh_theme_controls!(app)
    if kind in (:change, :select)
        app.menus.preferences["theme"] = String(setting)
        app.status = string("Theme: ", setting)
        close_theme_control!(app)
    elseif kind in (:back, :cancel)
        close_theme_control!(app)
    elseif kind == :error
        app.status = result.reason
    end
    nothing
end

"""Attach color framing only after the framework completes terminal probes, without a second stdin reader."""
function initialize_terminal_theme!(app::App, terminal::Tachikoma.Terminal)
    close_terminal_theme!(app)
    runtime = app.menus.theme_runtime
    if !isnothing(runtime)
        lifecycle = ThemeLifecycle(; runtime, output=terminal.io)
        attached = theme_input_attach!(lifecycle)
        if attached.ok
            app.settings.theme_input = attached.input
            theme_lifecycle_start!(lifecycle)
        else
            theme_lifecycle_close!(lifecycle)
            app.status = attached.reason
        end
    end
    nothing
end

"""Apply color and file notifications on the UI owner before rendering the next frame."""
function Tachikoma.pre_render!(app::App)
    input = app.settings.theme_input
    if !isnothing(input) && theme_input_poll!(input)
        refresh_theme_controls!(app)
    end
    runtime = app.menus.theme_runtime
    if !isnothing(runtime) && ACTIVE_NATIVE_THEME[] !== runtime
        activate_theme_runtime!(runtime)
    end
    nothing
end

"""Restore the one terminal input binding and stop all theme timers/watchers before normal teardown."""
function close_terminal_theme!(app::App)
    input = app.settings.theme_input
    if !isnothing(input)
        theme_lifecycle_close!(input.lifecycle)
        theme_input_detach!(input)
        app.settings.theme_input = nothing
    end
    nothing
end

function open_theme_control!(app::App; standalone=false)
    runtime = app.menus.theme_runtime
    if !isnothing(runtime)
        app.menus.theme_menu = theme_menu(runtime; standalone,
            on_event=(kind, setting, result) -> theme_control_event!(app, kind, setting, result),
            persist=persist_terminal_theme)
    end
    nothing
end

function close_theme_control!(app::App)
    if isempty(app.menus.parents)
        app.page = :chat
    else
        path, cursor, query = pop!(app.menus.parents)
        app.menus.path = path
        app.menus.cursor = cursor
        Tachikoma.set_text!(app.menus.search, query)
    end
    nothing
end

theme_controls_active(app::App) = app.menus.path in (["theme"], ["settings", "theme"])
function theme_controls_input!(app::App, event::KeyEvent, raw)
    menu = app.menus.theme_menu
    isnothing(menu) || theme_menu_input!(menu, menu_packet(event, raw))
    nothing
end
function theme_controls_lines(app::App, width)
    menu = app.menus.theme_menu
    isnothing(menu) ? SessionDisplayRows() : theme_menu_lines(menu, width)
end
function theme_controls_mouse!(app::App, event::MouseEvent)
    menu = app.menus.theme_menu
    result=nothing
    if !isnothing(menu)
        area = app.area
        lines = theme_menu_lines(menu, area.width)
        geometry=startup_editor_geometry(app,lines)
        local_row=startup_editor_row(app,event,geometry)
        wheel_delta = terminal_viewport_wheel(app,event)
        action = wheel_delta != 0 ? :wheel : event.action == Tachikoma.mouse_press ? :press : event.action == Tachikoma.mouse_release && !isnothing(menu.pressed) ? :click : :move
        button = event.button == Tachikoma.mouse_left ? :left : :other
        result=theme_menu_mouse_dispatch!(menu, event.x - area.x, local_row; action, button, wheel_delta)
        event.action==Tachikoma.mouse_release && local_row<0 && (menu.pressed=nothing)
    end
    !isnothing(result) && get(result,:handled,false)
end

"""Cache source-backed rendered archive rows separately from streaming previews and model context."""
function archive_transcript_lines!(app::App, width::Int)
    timeline = app.archive.timeline
    state = app.transcript.display
    state.output_padding = terminal_integer(app, "output-padding", 1, 0, 1)
    runtime = app.menus.theme_runtime
    palette = isnothing(runtime) ? nothing : runtime.active
    options = SessionImageOptions(; show_images=menu_preference(app, "show-images", "true") == "true",
        max_width_cells=terminal_integer(app, "image-width-cells", 60, 1, 240))
    protocol, cell = session_image_protocol(), Tachikoma.cell_pixels()
    if isnothing(timeline)
        empty!(app.transcript.prompts.archived)
        app.transcript.display_plan = nothing
        app.transcript.display_rows = SessionDisplayRows()
        app.transcript.display_key = nothing
    else
        snapshot = lock(timeline.lock) do
            key = (timeline.identity.id, timeline.leaf, length(timeline.entries), width, palette, app.transcript.notices.revision, app.transcript.documents.revision,
                state.expand_all, state.hide_thinking, state.show_usage, state.output_padding,
                copy(state.expanded), copy(state.collapsed), menu_preference(app,"cache-miss-notices","false"), session_image_layout_key(options, protocol, cell))
            projection = isequal(key, app.transcript.display_key) ? nothing : JuliaForever2.timeline_display_projection(timeline)
            misses=isnothing(projection)||menu_preference(app,"cache-miss-notices","false")!="true" ? Dict{String,JuliaForever2.SessionCacheMiss}() : JuliaForever2.session_cache_misses(JuliaForever2.timeline_branch(timeline))
            (; key, projection, misses)
        end
        projection = snapshot.projection
        if !isnothing(projection)
            prompt_rows=Int[]
            plan = session_display_plan(projection, width; state, options, protocol, cell_pixels=cell,
                after_record=SessionAfterRecordLayout((anchor,w,offset)->cache_miss_after_record_rows(app,timeline.identity.id,anchor,w,snapshot.misses;projection,
                    on_component=(kind,message,start,count)->terminal_prompt_record!(prompt_rows,kind,message,offset+start,count))),
                on_component=(kind,message,start,count)->terminal_prompt_record!(prompt_rows,kind,message,start,count),
                tool_renderers=SessionBuiltinToolRenderers(; cwd=app.settings.workspace, home=homedir(), syntax_renderer=SessionParserSyntaxRenderer()))
            app.transcript.display_plan = plan
            app.transcript.display_rows = plan.rows
            app.transcript.prompts.archived = prompt_rows
            app.transcript.display_key = snapshot.key
        end
    end
    app.transcript.display_rows
end
