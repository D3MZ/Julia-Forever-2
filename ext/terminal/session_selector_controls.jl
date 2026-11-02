"""Project actual archival identity and user/assistant text without invoking providers or tools."""
function terminal_resume_entry(timeline::JuliaForever2.SessionTimeline)
    entries = JuliaForever2.timeline_entries(timeline)
    messages = [entry for entry in entries if entry["type"] == "message"]
    texts = String[]
    first_message = ""
    latest = 0.0
    for entry in messages
        message = entry["message"]
        stamp = get(message, "timestamp", nothing)
        activity = stamp isa Real && isfinite(stamp) ? Float64(stamp) / 1000 : JuliaForever2.timeline_timestamp_seconds(entry["timestamp"])
        latest = max(latest, activity)
        content = get(message, "content", nothing)
        if get(message, "role", nothing) in ("user", "assistant") && content isa Union{AbstractString,AbstractVector}
            text = JuliaForever2.timeline_text(content)
            if !isempty(text)
                push!(texts, text)
                if isempty(first_message) && message["role"] == "user"
                    first_message = text
                end
            end
        end
    end
    created = JuliaForever2.timeline_timestamp_seconds(timeline.identity.timestamp)
    ResumeEntry(; id=timeline.identity.id, path=something(timeline.path, ""), cwd=timeline.identity.cwd,
        created, modified=latest > 0 ? latest : created, messages=length(messages),
        first_message=isempty(first_message) ? "(no messages)" : first_message, text=join(texts, " "),
        name=JuliaForever2.timeline_name(timeline), parent=timeline.identity.parent_session)
end

"""Accept only a listed native storage path, never arbitrary names or paths from an imported archive."""
function terminal_resume_id(app::App, path::AbstractString)
    filename = basename(path)
    if !endswith(filename, ".timeline.json")
        error("Not a native session archive")
    end
    id = chop(filename; tail=14)
    expected = JuliaForever2.timeline_store_path(app.archive.store, id)
    if abspath(path) != expected
        error("Session is outside this application's owned archive")
    end
    id
end

"""Load one scope asynchronously and publish immutable progress on the UI event owner."""
function start_resume_load!(app::App, menu::ResumeMenu, request::ResumeLoadRequest)
    task = Task() do
        directory = app.archive.store.directory
        files = isdir(directory) ? filter(name -> endswith(name, ".timeline.json"), sort(readdir(directory))) : String[]
        records = ResumeEntry[]
        revisions = Dict{String,String}()
        for (loaded, filename) in enumerate(files)
            if request.cancelled || app.operations.closing[]
                break
            end
            id = chop(filename; tail=14)
            attempt = preference_attempt(() -> JuliaForever2.load_timeline(app.archive.store, id))
            if attempt.ok
                timeline = attempt.value
                if request.scope == :all || normpath(timeline.identity.cwd) == normpath(app.settings.workspace)
                    push!(records, terminal_resume_entry(timeline))
                    revisions[something(timeline.path, "")] = something(timeline.disk_digest, "")
                end
            end
            enqueue_event!(app, TaskEvent(:resume_progress, (; menu, request, loaded, total=length(files), entries=copy(records), revisions=copy(revisions))))
            yield()
        end
        (; menu, request, entries=records, revisions)
    end
    schedule(task)
    notify_completion!(app, :resume_load_done, task, (; menu, request, task))
    nothing
end

function resume_progress_finished!(app::App, result)
    if app.menus.resume_menu === result.menu && !app.operations.closing[] && resume_load_active(result.menu, result.request) && !result.request.cancelled
        merge!(app.menus.resume_revisions, result.revisions)
        resume_progress!(result.menu, result.request, result.loaded, result.total; entries=result.entries)
    end
    nothing
end

function resume_load_finished!(app::App, result)
    if app.menus.resume_menu === result.menu && !app.operations.closing[] && resume_load_active(result.menu, result.request) && !result.request.cancelled
        if istaskfailed(result.task)
            errors = Base.current_exceptions(result.task)
            reason = isempty(errors) ? "Session loading failed" : sprint(showerror, last(errors).exception)
            resume_failed!(result.menu, result.request, reason)
        else
            loaded = fetch(result.task)
            merge!(app.menus.resume_revisions, loaded.revisions)
            resume_loaded!(result.menu, result.request, loaded.entries)
        end
    end
    nothing
end

"""Perform a confirmed rename/delete against the revision the selector actually displayed."""
function mutate_resume_entry!(app::App, request::ResumeMutationRequest)
    id = terminal_resume_id(app, request.path)
    expected = get(app.menus.resume_revisions, request.path, nothing)
    current = ensure_archive!(app.archive, app.session)
    if isnothing(expected)
        error("Reload the session list before changing this entry")
    end
    if request.kind == :delete
        JuliaForever2.delete_timeline!(app.archive.store, id, expected; active_id=current.identity.id)
    elseif request.kind == :rename
        timeline = current.identity.id == id ? current : JuliaForever2.load_timeline(app.archive.store, id)
        if timeline.disk_digest != expected
            error("Session changed before rename; reload the session list")
        end
        JuliaForever2.timeline_name!(timeline, something(request.value, ""))
        readback = JuliaForever2.load_timeline(app.archive.store, id)
        if JuliaForever2.timeline_name(readback) != JuliaForever2.timeline_name(timeline)
            error("Session rename could not be verified")
        end
    else
        error("Unsupported session mutation")
    end
    nothing
end

function start_resume_mutation!(app::App, menu::ResumeMenu, request::ResumeMutationRequest)
    if app.busy || app.operations.closing[]
        resume_mutation_complete!(menu, request; ok=false, error="Finish or cancel the active operation first.")
    else
        task = Task(() -> lock(() -> mutate_resume_entry!(app, request), app.session.runtime.execution_lock))
        schedule(task)
        notify_completion!(app, :resume_mutation_done, task, (; menu, request, task))
    end
    nothing
end

function resume_mutation_finished!(app::App, result)
    if app.menus.resume_menu === result.menu && !app.operations.closing[]
        failed = istaskfailed(result.task)
        errors = failed ? Base.current_exceptions(result.task) : nothing
        reason = failed ? isempty(errors) ? "Session update failed" : sprint(showerror, last(errors).exception) : ""
        resume_mutation_complete!(result.menu, result.request; ok=!failed, error=reason, method=:unlink)
    end
    nothing
end

"""Bind session menus to their own cancellable loaders, real durable mutations and guarded UI timers."""
function open_session_selector!(app::App, name::AbstractString)
    close_session_selectors!(app)
    if name == "resume"
        empty!(app.menus.resume_revisions)
        current = app.archive.timeline
        app.menus.resume_menu = resume_menu(; current_path=isnothing(current) ? nothing : current.path,
            on_load=(menu, request) -> start_resume_load!(app, menu, request),
            on_select=path -> session_action!(app, :resume, terminal_resume_id(app, path)),
            on_cancel=() -> (close_session_selectors!(app); app.page = :chat),
            on_rename=(menu, request) -> start_resume_mutation!(app, menu, request),
            on_delete=(menu, request) -> start_resume_mutation!(app, menu, request),
            schedule=(callback, delay) -> selector_schedule(app, callback, delay),
            style=key -> selector_style(app, key), bold=selector_bold(app))
    elseif name == "fork"
        timeline = app.archive.timeline
        entries = isnothing(timeline) ? Dict{String,Any}[] : JuliaForever2.timeline_branch(timeline)
        messages = [ForkMessage(; id=entry["id"], text=JuliaForever2.timeline_user_text(entry["message"])) for entry in entries
            if entry["type"] == "message" && get(entry["message"], "role", nothing) == "user"]
        app.menus.fork_menu = fork_menu(messages; on_select=id -> session_action!(app, :fork, id),
            on_cancel=() -> (close_session_selectors!(app); app.page = :chat),
            style=key -> selector_style(app, key), bold=selector_bold(app), schedule=(callback, delay) -> selector_schedule(app, callback, delay))
    end
    nothing
end

function close_session_selectors!(app::App)
    resume, fork = app.menus.resume_menu, app.menus.fork_menu
    isnothing(resume) || resume_dispose!(resume)
    isnothing(fork) || fork_dispose!(fork)
    app.menus.resume_menu = nothing
    app.menus.fork_menu = nothing
    nothing
end

function selector_style(app::App, token::Symbol)
    runtime = app.menus.theme_runtime
    isnothing(runtime) ? tree_default_style(token) : theme_token_style(runtime, String(token))
end
selector_bold(app::App) = !isnothing(app.menus.theme_runtime) && app.menus.theme_runtime.active.bold
selector_active(app::App) = app.menus.path in (["resume"], ["fork"])

function selector_schedule(app::App, callback, seconds)
    generation = app.menus.generation
    path = copy(app.menus.path)
    Timer(_ -> enqueue_event!(app, TaskEvent(:selector_callback, (; generation, path, callback))), seconds)
end

function selector_callback_finished!(app::App, event)
    if !app.operations.closing[] && app.page == :pi_menu && app.menus.generation == event.generation && app.menus.path == event.path
        event.callback()
    end
    nothing
end

function session_selector_input!(app::App, event::KeyEvent, raw)
    if app.menus.path == ["resume"]
        menu = app.menus.resume_menu
        isnothing(menu) || resume_input!(menu, menu_packet(event, raw))
    else
        menu = app.menus.fork_menu
        isnothing(menu) || fork_input!(menu, menu_packet(event, raw))
    end
    nothing
end

function session_selector_view!(app::App,frame::Frame)
    startup_host_view!(app,frame)
    nothing
end

selector_lines(menu::ResumeMenu, width) = resume_lines(menu, width)
selector_lines(menu::ForkMenu, width) = fork_lines(menu, width)

function session_selector_mouse!(app::App, event::MouseEvent)
    menu = app.menus.resume_menu
    if app.menus.path == ["resume"] && !isnothing(menu)
        lines = resume_lines(menu, app.area.width)
        geometry=startup_editor_geometry(app,lines)
        local_row=startup_editor_row(app,event,geometry)
        action = event.action == Tachikoma.mouse_press ? :press : :other
        button = event.button == Tachikoma.mouse_left ? :left : :other
        resume_mouse!(menu, event.x - app.area.x, local_row; action, button)
    end
    nothing
end
