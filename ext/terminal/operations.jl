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

ui_context(app::App) = ExecutionContext(; event_sink=event -> enqueue_event!(app, TaskEvent(event.kind, event.data)))

function track_operation!(app::App, handle::TaskHandle, id::Symbol, status::AbstractString; pending_continuation::Bool=false, pending_ids=pending_input_ids(app))
    clear_preview!(app)
    app.operations.active = handle
    app.operations.active_kind = id
    app.operations.pending_start_ids = copy(pending_ids)
    app.operations.pending_continuation = pending_continuation
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
        handle = JuliaForever2.submit_managed!(app.session, app.session, ui_context(app)) do context
            lock(app.session.runtime.execution_lock) do
                if isopen(app.session) && !cancelled(context)
                    append_message!(app.session, Message(:user, string("/julia ", code)))
                    JuliaForever2.record!(app.session, code, context)
                else
                    JuliaForever2.stopped_result()
                end
            end
        end
        track_operation!(app, handle, :evaluation, "Running Julia…")
    end
end
function submit!(app::App, prompt::AbstractString)
    if !isempty(strip(prompt)) && !app.operations.closing[]
        terminal_viewport_end!(app)
        dispatch!(app, strip(prompt))
    end
end

function dispatch!(app::App, prompt::AbstractString)
    app.menus.model_command=nothing
    shell=raw_user_shell(prompt)
    if !isnothing(shell)
        start_user_shell!(app,shell)
    elseif startswith(prompt, "/")
        command!(app, SubString(prompt, nextind(prompt, firstindex(prompt))))
    else
        was_busy = app.busy
        result = submit_literal_input!(app, prompt)
        result.ok && !was_busy ? app.operations.active : nothing
    end
end
"""Retire the active terminal operation while preserving its queued-input boundary."""
function finish_operation!(app::App)
    clear_preview!(app)
    previous = (kind=app.operations.active_kind, ids=app.operations.pending_start_ids,
        continuation=app.operations.pending_continuation)
    app.operations.active = nothing
    app.operations.active_kind = :none
    app.operations.pending_start_ids = UInt64[]
    app.operations.pending_continuation = false
    app.busy = false
    previous
end

"""Run completion effects only after the active operation has been retired."""
function settle_operation!(app::App, handle::TaskHandle, previous;result=session_action_result(handle),interrupted_save_failed::Bool=false)
    app.settings.workspace = working_directory(app.session)
    app.directory = directory_label(app.settings.workspace)
    previous.kind == :compaction_done && result.ok && clear_command_documents!(app)
    app.status = result.ok ? "Ready" : result.text
    interrupted_save_failed && (app.status *= " Interrupted output could not be saved.")
    flush_user_shell!(app) && continue_terminal_pending!(app, result, previous.kind, previous.ids, previous.continuation)
    result
end

function operation_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        result = session_action_result(handle)
        result.ok || capture_interrupted_preview!(app,cancelled(handle.context) ? :aborted : :error)
        clear_preview!(app)
        interrupted_save_failed=finalize_interrupted_responses!(app,handle)
        settle_operation!(app,handle,finish_operation!(app);result,interrupted_save_failed)
    end
    nothing
end
function cleanup!(app::App)
    close_terminal_viewport!(app)
    close_chat_completion!(app)
    auth_menu_dispose!(app.menus.auth_menu_control)
    close_terminal_output!(app)
    close_terminal_theme!(app)
    close_session_selectors!(app)
    lock(app.operations.event_lock) do
        app.operations.closing[] = true
        empty!(app.queue.channel)
    end
    active_turn, auth_flow = app.operations.active, app.settings.auth_flow
    isnothing(active_turn) || cancel!(active_turn)
    isnothing(auth_flow) || cancel_auth!(auth_flow)
    clear_preview!(app)
    tree = app.menus.tree_menu
    isnothing(tree) || tree_dispose!(tree)
    return nothing
end

function finish_shutdown!(app::App)
    cleanup!(app)
    close_user_shell!(app)
    close(app.session)
    auth_task = app.settings.auth_task
    isnothing(auth_task) || wait(auth_task)
    foreach(wait, app.operations.watchers)
    active=app.operations.active
    if !isnothing(active) && finalize_interrupted_responses!(app,active)
        app.status="Interrupted output could not be saved."
    end
    discard_pending_session!(app)
    empty!(app.operations.watchers)
    return nothing
end
