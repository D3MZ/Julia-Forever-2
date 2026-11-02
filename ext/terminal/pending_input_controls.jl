"""Read stable IDs, not preference revisions, when proving queued work made progress."""
function pending_input_ids(app::App)
    snapshot = JuliaForever2.pending_input_snapshot(app.session)
    UInt64[item.id for item in [snapshot.steering; snapshot.follow_up]]
end

pending_follow_up_key(packet::AbstractString) = packet in ("\e\r", "\e[13;3u", "\e[27;3;13~") || Sys.iswindows() && packet == "\x11"
pending_dequeue_key(packet::AbstractString) = packet == "\e[1;3A" || Sys.iswindows() && packet == "\eq"

"""Accept input into its real session queue before changing the editor or reporting acceptance."""
function queue_terminal_input!(app::App, text::AbstractString; kind::Symbol=:steering)
    if app.operations.closing[]
        (ok=false, reason="Terminal is closing")
    elseif app.operations.active_kind ∉ (:turn, :evaluation, :compaction_done, :changelog_done)
        app.status = "Finish the current session operation before queuing messages."
        (ok=false, reason=app.status)
    else
        result = JuliaForever2.queue_input!(app.session, text; kind)
        if result.ok
            Tachikoma.clear!(app.input)
            app.menu = false
            app.operations.active_kind == :compaction_done && (app.status = "Queued message for after compaction")
        else
            app.status = result.reason
        end
        result
    end
end

"""Submit expanded user content without ever interpreting a leading slash as a command."""
function submit_literal_input!(app::App, text::AbstractString; kind::Symbol=:steering)
    if isempty(strip(text))
        (ok=false, reason="Input is empty")
    elseif kind ∉ (:steering, :follow_up)
        (ok=false, reason="Unsupported pending-input queue")
    elseif app.operations.closing[] || !isopen(app.session)
        app.status = "Session is closed"
        (ok=false, reason=app.status)
    elseif app.busy
        result = queue_terminal_input!(app, text; kind)
        (ok=result.ok, reason=result.reason)
    else
        handle = submit_turn!(app.session, text; context=ui_context(app))
        Tachikoma.clear!(app.input)
        app.menu = false
        track_operation!(app, handle, :turn, "Thinking…")
        (ok=true, reason="")
    end
end

"""Resolve only real extension commands for immediate execution during follow-up submission."""
function pending_extension_command(app::App, text::AbstractString)
    parts = split(chop(text; head=1, tail=0); limit=2)
    !isempty(parts) && any(command -> command.name == first(parts) && command.origin ∉ (:builtin, :prompt, :skill), discover_commands(app))
end

"""Alt+Enter queues during an active turn, but submits normally when the agent is idle."""
function follow_up_terminal_input!(app::App)
    text = strip(Tachikoma.text(app.input))
    if !isempty(text)
        if !app.busy || startswith(text, "/") && pending_extension_command(app, text)
            submit!(app, text)
        else
            result = expand_registered_resources(app, text)
            if result.ok
                submit_literal_input!(app, result.text; kind=:follow_up)
            else
                app.status = result.reason
            end
        end
    end
    nothing
end

"""Restore queued steering then follow-up text ahead of the current editor, optionally aborting."""
function restore_pending_input!(app::App; abort::Bool=false)
    removed = JuliaForever2.clear_pending_inputs!(app.session)
    count = length(removed.removed)
    if removed.ok && count > 0
        queued = join((item.message.content for item in removed.removed), "\n\n")
        current = Tachikoma.text(app.input)
        combined = join(filter(text -> !isempty(strip(text)), [queued, current]), "\n\n")
        Tachikoma.set_text!(app.input, combined)
        app.menu = false
    end
    if abort
        handle = app.operations.active
        isnothing(handle) || cancel!(handle)
        app.busy && (app.status = "Cancelling…")
    else
        app.status = count == 0 ? "No queued messages to restore" : "Restored $count queued message$(count == 1 ? "" : "s") to editor"
    end
    count
end

"""Render original first-line truncation while preserving its newline-trimmed foreground reset."""
function pending_truncated_row(text::AbstractString, width::Integer, inherited::Symbol=:terminal_default)
    single = first(split(text, '\n'; limit=2))
    available = max(1, width - 2)
    truncated = menu_search_width(single) > available
    carry = !truncated && occursin('\n', text)
    row = menu_line(" ", inherited)
    if truncated
        suffix = first("...", min(3, available))
        push!(row, menu_span(menu_search_slice(single, 0, available - length(suffix)), :text_dim))
        push!(row, menu_span(suffix))
    else
        push!(row, menu_span(single, :text_dim))
    end
    trailing = carry ? :text_dim : :terminal_default
    used = sum(span -> menu_search_width(span.content), row; init=0)
    push!(row, menu_span(repeat(" ", max(1, width - used)), trailing))
    (row=row, carry=trailing)
end

"""Expose the pending dock as pure rendered rows for the real fullscreen layout owner."""
function pending_input_lines(app::App, width::Integer)
    snapshot = JuliaForever2.pending_input_snapshot(app.session)
    rows = Vector{Tachikoma.Span}[]
    if !isempty(snapshot.steering) || !isempty(snapshot.follow_up)
        push!(rows, menu_line(repeat(" ", max(0, width))))
        texts = ["Steering: " * item.message.content for item in snapshot.steering]
        append!(texts, ["Follow-up: " * item.message.content for item in snapshot.follow_up])
        key = Sys.iswindows() ? "alt+q" : "alt+up"
        push!(texts, "↳ $key to edit all queued messages")
        inherited = :terminal_default
        for text in texts
            rendered = pending_truncated_row(text, width, inherited)
            push!(rows, rendered.row)
            inherited = rendered.carry
        end
    end
    rows
end

"""Continue only successful queue-bearing operations and stop custom loops that make no progress."""
function continue_terminal_pending!(app::App, result, previous_kind, previous_ids, was_continuation)
    ids = pending_input_ids(app)
    if result.ok && !app.operations.closing[] && !isempty(ids) && previous_kind in (:turn, :evaluation, :compaction_done, :changelog_done)
        consumed = any(id -> id ∉ ids, previous_ids)
        if was_continuation && !consumed
            app.status = "The active loop did not consume queued messages; they remain available to edit."
        else
            handle = JuliaForever2.submit_queued_turn!(app.session; context=ui_context(app))
            track_operation!(app, handle, :turn, "Thinking…"; pending_continuation=true, pending_ids=ids)
        end
    end
    nothing
end

apply_setting_effect!(app::App, ::Val{Symbol("steering-mode")}, value::AbstractString) =
    JuliaForever2.set_input_queue_mode!(app.session, :steering, value)
apply_setting_effect!(app::App, ::Val{Symbol("follow-up-mode")}, value::AbstractString) =
    JuliaForever2.set_input_queue_mode!(app.session, :follow_up, value)

"""Invalidate rendered history only after the core reports an actually committed queued input."""
function pending_input_delivered!(app::App, event)
    active = app.operations.active
    if !isnothing(active) && event.operation_id == JuliaForever2.operation_id(active.context)
        app.transcript.display_key = nothing
    end
    nothing
end
