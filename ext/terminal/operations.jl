function enqueue_event!(app::App, event::TaskEvent)
    accepted = lock(app.operations.event_lock) do
        app.operations.closing[] && return false
        put!(app.queue.channel, event)
        return true
    end
    accepted || return false
    callback = app.queue.on_ready
    isnothing(callback) || callback()
    return true
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
        return nothing
    end
    (app.busy || app.operations.closing[]) && return nothing
    append_message!(app.session, Message(:user, "/julia " * code))
    handle = submit_evaluation!(app.session, code; context=ui_context(app))
    return track_operation!(app, handle, :evaluation, "Running Julia…")
end

function submit!(app::App, prompt::AbstractString)
    isempty(strip(prompt)) && return nothing
    app.operations.closing[] && return nothing
    app.scroll = 0
    if startswith(prompt, "/")
        return command!(app, SubString(prompt, nextind(prompt, firstindex(prompt))))
    end
    app.busy && return nothing
    Tachikoma.clear!(app.input)
    handle = submit_turn!(app.session, prompt; context=ui_context(app))
    return track_operation!(app, handle, :turn, "Thinking…")
end

function operation_finished!(app::App, handle::TaskHandle)
    app.operations.active === handle || return nothing
    clear_preview!(app)
    app.operations.active = nothing
    app.busy = false
    result = fetch(handle)
    app.status = result.ok ? "Ready" : result.text
    return nothing
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
