function enqueue_event!(app::App, event::TaskEvent)
    accepted = lock(app.operations.event_lock) do
        if app.operations.closing[]
            false
        else
            put!(app.queue.channel, event)
            true
        end
    end
    if accepted
        callback = app.queue.on_ready
        if !isnothing(callback)
            callback()
        end
    end
    accepted
end
function notify_completion!(app::App, id::Symbol, task::Task, value; cleanup=Returns(nothing))
    for watcher in app.operations.watchers
        istaskdone(watcher) && fetch(watcher)
    end
    filter!(watcher -> !istaskdone(watcher), app.operations.watchers)
    watcher = Threads.@spawn begin
        wait(task; throw=false)
        cleanup()
        enqueue_event!(app, TaskEvent(id, value))
    end
    push!(app.operations.watchers, watcher)
    return watcher
end

function ui_context(app::App)
    return ExecutionContext(; event_sink=event -> enqueue_event!(app, TaskEvent(event.kind, event.data)))
end

function track_operation!(app::App, handle::TaskHandle, id::Symbol, status::AbstractString)
    clear_preview!(app)
    app.operations.active = handle
    app.busy = true
    app.status = String(status)
    notify_completion!(app, id, handle.task, handle)
    return handle
end

function julia_command!(app::App, code::AbstractString)
    if isempty(strip(code))
        Tachikoma.set_text!(app.input, "/julia ")
        nothing
    elseif app.busy || app.operations.closing[]
        nothing
    else
        append_message!(app.session, Message(:user, "/julia " * code))
        track_operation!(app, submit_evaluation!(app.session, code; context=ui_context(app)), :evaluation, "Running Julia…")
    end
end
function submit!(app::App, prompt::AbstractString)
    if !isempty(strip(prompt)) && !app.operations.closing[]
        app.scroll = 0
        dispatch!(app, prompt)
    end
end

function dispatch!(app::App, prompt::AbstractString)
    if startswith(prompt, "/")
        command!(app, SubString(prompt, nextind(prompt, firstindex(prompt))))
    elseif !app.busy
        Tachikoma.clear!(app.input)
        track_operation!(app, submit_turn!(app.session, prompt; context=ui_context(app)), :turn, "Thinking…")
    end
end
function operation_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        clear_preview!(app)
        app.operations.active = nothing
        app.busy = false
        result = fetch(handle)
        app.status = result.ok ? "Ready" : result.text
    end
    nothing
end
function cleanup!(app::App)
    lock(app.operations.event_lock) do
        app.operations.closing[] = true
        empty!(app.queue.channel)
    end
    active_turn, auth_flow = app.operations.active, app.settings.auth_flow
    isnothing(active_turn) || cancel!(active_turn)
    isnothing(auth_flow) || cancel_auth!(auth_flow)
    clear_preview!(app)
    return nothing
end

function finish_shutdown!(app::App)
    cleanup!(app)
    close(app.session)
    auth_task = app.settings.auth_task
    isnothing(auth_task) || wait(auth_task)
    foreach(wait, app.operations.watchers)
    empty!(app.operations.watchers)
    return nothing
end
