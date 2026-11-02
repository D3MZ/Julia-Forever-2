"""Open actual durable graph entries using original identifiers and native callbacks."""
function open_tree_control!(app::App)
    previous = app.menus.tree_menu
    isnothing(previous) || tree_dispose!(previous)
    timeline = app.archive.timeline
    runtime = app.menus.theme_runtime
    if !isnothing(timeline)
        style = token -> isnothing(runtime) ? tree_default_style(token) : theme_token_style(runtime, String(token))
        generation = app.menus.generation
        scheduler = (callback, seconds) -> Timer(_ -> enqueue_event!(app, TaskEvent(:tree_callback, (generation, callback))), seconds)
        app.menus.tree_menu = tree_menu(JuliaForever2.timeline_tree(timeline), JuliaForever2.timeline_leaf(timeline);
            on_select=id -> session_action!(app, :tree, id), on_cancel=() -> close_tree_control!(app),
            on_label=(id, label) -> tree_save_label!(app, id, label), on_copy=text -> copy_terminal_text!(app, text),
            height=max(5, app.area.height), filter=menu_preference(app, "tree-filter-mode", "default"),
            style, schedule=scheduler, bold=!isnothing(runtime) && runtime.active.bold)
    end
    nothing
end

function close_tree_control!(app::App)
    menu = app.menus.tree_menu
    isnothing(menu) || tree_dispose!(menu)
    app.page = :chat
    nothing
end

"""Keep an optimistic selector label tied to its separately confirmed durable outcome."""
function tree_save_label!(app::App, id, label)
    timeline = app.archive.timeline
    menu = app.menus.tree_menu
    old = isnothing(timeline) ? nothing : JuliaForever2.timeline_label(timeline, id)
    task = Task() do
        if isnothing(timeline) || app.busy || app.operations.closing[]
            error("Cannot change a label while the session is changing")
        end
        lock(app.session.runtime.execution_lock) do
            ensure_archive!(app.archive, app.session)
            JuliaForever2.timeline_label!(timeline, id, label)
            JuliaForever2.timeline_label(timeline, id) == label || error("Session label readback did not match")
        end
        nothing
    end
    schedule(task)
    wait(task; throw=false)
    if istaskfailed(task)
        isnothing(menu) || tree_update_label!(menu, id, old)
        errors = Base.current_exceptions(task)
        app.status = isempty(errors) ? "Session label failed" : sprint(showerror, last(errors).exception)
        (ok=false, reason=app.status)
    else
        fetch(task)
        app.status = isnothing(label) ? "Label removed" : "Label saved"
        (ok=true, reason="")
    end
end

function tree_controls_input!(app::App, event::KeyEvent, raw)
    menu = app.menus.tree_menu
    isnothing(menu) || tree_input!(menu, menu_packet(event, raw))
    nothing
end
function tree_controls_view!(app::App,frame::Frame)
    startup_host_view!(app,frame)
    nothing
end

"""Copy through the actual terminal backend; distinguish an OSC submission from local confirmation."""
function copy_terminal_text!(app::App, text::AbstractString)
    terminal = app.settings.terminal
    task = Task(() -> isnothing(terminal) ? :none : Tachikoma.clipboard_copy!(terminal, text))
    schedule(task)
    wait(task; throw=false)
    if istaskfailed(task)
        app.status = "Clipboard transfer failed."
        false
    else
        result = fetch(task)::Symbol
        app.status = result == :native ? "Copied to clipboard" : result == :osc52 ?
            "Clipboard transfer sent to terminal; confirmation unavailable" : "No supported clipboard destination"
        result != :none
    end
end

function tree_callback_finished!(app::App, value)
    generation, callback = value
    if app.page == :pi_menu && app.menus.path == ["tree"] && app.menus.generation == generation
        callback()
    end
    nothing
end
