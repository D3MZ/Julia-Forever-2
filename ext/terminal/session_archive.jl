"""Keep actual native model identity and supplied rich provider output in durable records."""
function archive_payload(session::Session, message::Message)
    if message.role != :assistant || message.metadata isa JuliaForever2.TimelineMessageMetadata
        JuliaForever2.timeline_archive_message(message)
    else
        raw = get(task_local_storage(), :JuliaForever2_provider_response, nothing)
        provider_message = raw isa JuliaForever2.StreamedCompletion ? raw.message : nothing
        payload = with_component(session.kernel, :provider; fallback=:unconfigured) do provider
            model = JuliaForever2.selected_model(provider)
            if model isa JuliaForever2.ModelSpec
                JuliaForever2.timeline_archive_message(message; provider_message,
                    provider=String(model.provider), model=model.id, api=isempty(model.api) ? nothing : model.api)
            else
                identity = JuliaForever2.provider_model_identity(provider)
                if !isempty(identity.model_id)
                    JuliaForever2.timeline_archive_message(message; provider_message,
                        provider=String(identity.provider_id), model=identity.model_id)
                else
                    JuliaForever2.timeline_archive_message(message; provider_message)
                end
            end
        end
        archive_reported_usage!(payload::Dict{String,Any}, raw)
    end
end


"""Persist initial history before enabling any reported session action."""
function ensure_archive!(archive::TerminalArchive, session::Session)
    timeline = archive.timeline
    if isnothing(timeline)
        error("Session archive must be initialized before binding history")
    end
    if isnothing(timeline.path)
        JuliaForever2.save_timeline!(archive.store, timeline)
    end
    timeline
end

"""Prepare archival identity without disk I/O or callbacks under the history lock."""
function initialize_archive!(archive::TerminalArchive, session::Session)
    lock(session.runtime.execution_lock) do
        timeline = JuliaForever2.SessionTimeline(working_directory(session); id=string(session.runtime.id))
        ids = String[]
        for message in history_snapshot(session).messages
            push!(ids, JuliaForever2.timeline_append_message!(timeline, archive_payload(session, message)))
        end
        marker = session.conversation.compaction
        if !isnothing(marker)
            if !(1 <= marker.first_kept <= length(ids) + 1)
                error("Invalid existing native compaction boundary")
            end
            boundary = marker.first_kept <= length(ids) ? ids[marker.first_kept] : nothing
            estimate = sum(JuliaForever2.estimated_tokens, session.messages; init=0)
            JuliaForever2.timeline_append_compaction!(timeline, marker.summary, boundary, estimate;
                fields=Dict("jf2" => Dict("format" => "JuliaForever2.compaction.v1",
                    "contextSummaryFormat" => "native-plain", "tokensBeforeSource" => "utf8_byte_estimate")))
        end
        seed_archive_configuration!(timeline, session)
        archive.timeline = timeline
        archive.entry_ids = ids
    end
    archive
end

"""Archive before in-memory history mutation; a failed durable write prevents false success."""
function (archive::TerminalArchive)(session::Session, operation::Symbol, arguments...)
    timeline = ensure_archive!(archive, session)
    archive_history!(archive, timeline, session, Val(operation), arguments...)
end

function archive_history!(archive, timeline, session, ::Val{:append}, message::Message)
    id = JuliaForever2.timeline_append_message!(timeline, archive_payload(session, message))
    push!(archive.entry_ids, id)
    nothing
end

function archive_history!(archive, timeline, session, ::Val{:clear})
    lock(timeline.lock) do
        candidate = JuliaForever2.timeline_from_rows([JuliaForever2.timeline_header(timeline); JuliaForever2.timeline_entries(timeline)]; leaf=nothing)
        seed_archive_configuration!(candidate, session)
        JuliaForever2.timeline_commit!(timeline, candidate.entries, candidate.leaf)
    end
    empty!(archive.entry_ids)
    nothing
end

function archive_history!(archive, timeline, session, ::Val{:replace}, index::Integer, message::Message)
    previous = session.messages[index]
    if previous.role != message.role || previous.kind != message.kind || !isequal(previous.metadata, message.metadata)
        error("History replacement cannot change archived role, kind or metadata")
    end
    target = JuliaForever2.timeline_entry(timeline, archive.entry_ids[index])
    if isnothing(target)
        error("History replacement target is missing from the session archive")
    end
    native = get(get(target::Dict{String,Any}, "message", Dict{String,Any}()), "jf2", nothing)
    visible = native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
    fields = visible ? Dict("jf2" => Dict("format" => "JuliaForever2.context-edit.v1", "display" => true)) : Dict{String,Any}()
    JuliaForever2.timeline_append_context_edit!(timeline, archive.entry_ids[index], Dict("content" => message.content); fields)
    nothing
end

"""Keep arbitrary safe Pi identifiers while using stable native UUIDs for runtime ownership."""
function runtime_timeline_id(id::AbstractString)
    parsed = tryparse(JuliaForever2.UUID, id)
    isnothing(parsed) ? JuliaForever2.uuid5(JuliaForever2.UUID("93e26192-d05e-4e43-ad59-319d829a61fd"), id) : parsed
end

"""Rebuild a fresh executor from the already-projected context, never a flattened archive."""
function timeline_runtime(app, timeline)
    projection = JuliaForever2.timeline_projection(timeline)
    mapping = JuliaForever2.timeline_runtime_mapping(projection)
    messages, ids = mapping.messages, mapping.entry_ids
    old = app.session
    lineage = timeline_lineage(timeline)
    JuliaForever2.Workspace(timeline.identity.cwd)
    kernel = JuliaForever2.fork_kernel(old.kernel)
    created_executor = Ref{Any}(nothing)
    created_session = Ref{Any}(nothing)
    construction = Task() do
        prepared = archived_model_configuration(app, projection; kernel)
        journal = install!(kernel, ComponentSpec(:history_journals, JuliaForever2.HistoryJournals()))
        journal.ok || error(journal.reason)
        if !isnothing(prepared)
            installed = install_retained_provider!(kernel, prepared.provider)
            installed.ok || error(installed.reason)
        end
        executor = JuliaForever2.fork_executor(old.runtime.executor)
        created_executor[] = executor
        session = Session(kernel; owns_kernel=true, executor, messages,
            definition=old.definition, working_directory=timeline.identity.cwd,
            id=runtime_timeline_id(timeline.identity.id), parent_id=lineage.parent_id, root_id=lineage.root_id, compaction=old.runtime.compaction_settings)
        created_session[] = session
        restore_timeline_usage!(session, timeline)
        session
    end
    schedule(construction)
    wait(construction; throw=false)
    if istaskfailed(construction)
        dispose_runtime_candidate!(kernel, created_executor[], created_session[])
    end
    session = fetch(construction)
    archive = TerminalArchive(; store=app.archive.store, timeline, entry_ids=ids)
    (session, archive)
end

"""Prepare a new persisted identity before replacing the current interactive runtime."""
function prepare_session_transition(app, ::Val{:new}, argument)
    timeline = JuliaForever2.SessionTimeline(working_directory(app.session))
    seed_archive_configuration!(timeline, app.session)
    session, archive = timeline_runtime(app, timeline)
    persist_session_transition!(session) do
        JuliaForever2.save_timeline!(app.archive.store, timeline)
    end
    SessionTransition(; session, archive, status="New session started")
end

function prepare_session_transition(app, ::Val{:clone}, argument)
    source = ensure_archive!(app.archive, app.session)
    timeline = JuliaForever2.timeline_clone(source)
    preserve_lineage!(timeline, app.session)
    session, archive = timeline_runtime(app, timeline)
    persist_session_transition!(session) do
        JuliaForever2.save_timeline!(app.archive.store, timeline)
    end
    SessionTransition(; session, archive, status="Session cloned")
end

function prepare_session_transition(app, ::Val{:fork}, argument)
    source = ensure_archive!(app.archive, app.session)
    forked = JuliaForever2.timeline_fork(source, argument)
    preserve_lineage!(forked.timeline, app.session)
    session, archive = timeline_runtime(app, forked.timeline)
    persist_session_transition!(session) do
        JuliaForever2.save_timeline!(app.archive.store, forked.timeline)
    end
    SessionTransition(; session, archive, editor=forked.editor_text, status="Session forked")
end

function prepare_session_transition(app, ::Val{:resume}, argument)
    timeline = JuliaForever2.load_timeline(app.archive.store, argument)
    session, archive = timeline_runtime(app, timeline)
    SessionTransition(; session, archive, status="Session resumed")
end

function prepare_session_transition(app, ::Val{:import}, argument)
    path = JuliaForever2.workspace_path(app.session, argument)
    if islink(path) || !isfile(path) || filesize(path) > 64 * 1024 * 1024
        error("Import requires a regular session file within the size limit")
    end
    timeline = JuliaForever2.parse_timeline_jsonl(read(path, String))
    session, archive = timeline_runtime(app, timeline)
    persist_session_transition!(session) do
        JuliaForever2.save_timeline!(app.archive.store, timeline)
    end
    SessionTransition(; session, archive, status="Session imported")
end

"""Run session filesystem/projection work under supervised, cancellable ownership."""
function session_action!(app::App, operation::Symbol, argument::AbstractString="")
    if app.busy || app.operations.closing[] || !require_user_shell_idle!(app)
        app.status = "Finish or cancel the active operation first."
    else
        handle = JuliaForever2.submit_managed!(app.session, app.session, ui_context(app)) do context
            lock(app.session.runtime.execution_lock) do
                ensure_archive!(app.archive, app.session)
                if cancelled(context)
                    JuliaForever2.ExecutionResult(false, "Session action cancelled.")
                else
                    transition = prepare_session_transition(app, Val(operation), argument)
                    status = session_action_status(transition)
                    status = cancelled(context) ? status * " (completed before cancellation took effect)" : status
                    JuliaForever2.ExecutionResult(true, status, transition)
                end
            end
        end
        track_operation!(app, handle, :session_action_done, "Updating session…")
    end
    nothing
end

"""Switch only after the background action reports a verified durable outcome."""
function session_action_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        app.operations.active = nothing
        app.busy = false
        result = session_action_result(handle)
        if result.ok && result.value isa SessionTransition
            transition = result.value
            prepared = prepare_terminal_session_preferences(app, transition.session)
            if prepared.ok
                old = app.session
                JuliaForever2.unbind_history_journal!(old)
                app.session = transition.session
                app.archive = transition.archive
                JuliaForever2.bind_history_journal!(app.session, app.archive)
                close(old)
                clear_preview!(app)
                app.transcript = prepared.transcript
                app.settings.workspace = working_directory(app.session)
                app.directory = directory_label(app.settings.workspace)
                close_session_selectors!(app)
                app.scroll = 0
                app.page = :chat
                Tachikoma.set_text!(app.input, transition.editor)
            else
                discard_session_transition!(transition)
                result = JuliaForever2.ExecutionResult(false, prepared.reason)
            end
        end
        if result.ok && result.value isa AbstractVector{<:NamedTuple}
            app.archive.sessions = result.value
            open_menu!(app, "resume")
        end
        app.status = result.text
    end
    nothing
end

"""Return truthful task errors without terminating the interactive event loop."""
function session_action_result(handle::TaskHandle)
    if istaskfailed(handle)
        errors = Base.current_exceptions(handle.task)
        reason = isempty(errors) ? "Session action failed." : sprint(showerror, last(errors).exception)
        JuliaForever2.ExecutionResult(false, reason)
    else
        fetch(handle)
    end
end

session_action_status(result::SessionTransition) = result.status
session_action_status(result::AbstractVector{<:NamedTuple}) = "Select a saved session"
session_action_status(result::AbstractString) = String(result)
discard_session_transition!(result) = nothing
discard_session_transition!(result::SessionTransition) = close(result.session)

function prepare_session_transition(app, ::Val{:name}, argument)
    if isempty(strip(argument))
        error("Use /name <title>")
    end
    JuliaForever2.timeline_name!(ensure_archive!(app.archive, app.session), argument)
    "Session named: " * strip(argument)
end

prepare_session_transition(app, ::Val{:list}, argument) = JuliaForever2.list_timelines(app.archive.store)

"""Leave source identity untouched when a branch switch cannot be reconstructed safely."""
function prepare_session_transition(app, ::Val{:tree}, argument)
    source = ensure_archive!(app.archive, app.session)
    candidate = JuliaForever2.timeline_from_rows([JuliaForever2.timeline_header(source); JuliaForever2.timeline_entries(source)]; leaf=argument)
    session, archive = timeline_runtime(app, candidate)
    persist_session_transition!(session) do
        JuliaForever2.timeline_branch!(source, argument)
    end
    archive.timeline = source
    SessionTransition(; session, archive, status="Session branch selected")
end

function archive_history!(archive, timeline, session, ::Val{:compact}, entry::JuliaForever2.CompactionEntry)
    first_kept = entry.first_kept <= length(archive.entry_ids) ? archive.entry_ids[entry.first_kept] : nothing
    reported = session.usage.context_tokens
    tokens = isnothing(reported) ? sum(JuliaForever2.estimated_tokens, JuliaForever2.context_messages(session); init=0) : reported
    source = isnothing(reported) ? "utf8_byte_estimate" : "provider_usage"
    JuliaForever2.timeline_append_compaction!(timeline, entry.summary, first_kept, tokens;
        fields=Dict("jf2" => Dict("tokensBeforeSource" => source)))
    nothing
end

"""Preserve all active branch fields in JSONL; never overwrite an existing export."""
function prepare_session_transition(app, ::Val{:export}, argument)
    timeline = ensure_archive!(app.archive, app.session)
    requested = isempty(strip(argument)) ? string("session-", timeline.identity.id, ".html") : String(strip(argument))
    path = JuliaForever2.workspace_path(app.session, requested)
    if endswith(lowercase(path), ".jsonl")
        JuliaForever2.export_timeline!(timeline, path)
    elseif endswith(lowercase(path), ".html")
        escape_html(value) = replace(String(value), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
        messages = JuliaForever2.timeline_messages(timeline)
        sections = [string("<section><h2>", escape_html(message["role"]), "</h2><pre>",
            escape_html(get(message, "content", get(message, "output", "")) isa AbstractString ? get(message, "content", get(message, "output", "")) : JSON.json(get(message, "content", ""))), "</pre></section>") for message in messages]
        html = string("<!doctype html><meta charset=\"utf-8\"><title>", escape_html(something(JuliaForever2.timeline_name(timeline), "Session")), "</title>", join(sections, "\n"))
        JuliaForever2.timeline_replace_file(path, html, nothing)
    else
        error("Export path must end in .html or .jsonl")
    end
    "Exported session: " * path
end

"""Dispose a successful but undisplayed replacement runtime during shutdown."""
function discard_pending_session!(app::App)
    handle = app.operations.active
    if !isnothing(handle) && istaskdone(handle) && !istaskfailed(handle)
        result = fetch(handle)
        result.ok && discard_session_transition!(result.value)
    end
    JuliaForever2.unbind_history_journal!(app.session)
    nothing
end

"""Dispose a prepared executor if its final durable commit fails."""
function persist_session_transition!(commit, session::Session)
    task = Task(commit)
    schedule(task)
    wait(task; throw=false)
    if istaskfailed(task)
        close(session)
    end
    fetch(task)
end

"""Keep native lineage namespaced without changing the source Pi parent-session field."""
function preserve_lineage!(timeline, parent::Session)
    timeline.identity.fields["jf2Lineage"] = Dict("parentId" => string(parent.runtime.id), "rootId" => string(parent.runtime.root_id))
    timeline
end

function timeline_lineage(timeline)
    stored = get(timeline.identity.fields, "jf2Lineage", nothing)
    if stored isa AbstractDict && get(stored, "parentId", nothing) isa AbstractString && get(stored, "rootId", nothing) isa AbstractString
        (parent_id=runtime_timeline_id(stored["parentId"]), root_id=runtime_timeline_id(stored["rootId"]))
    else
        (parent_id=nothing, root_id=runtime_timeline_id(timeline.identity.id))
    end
end

"""Use one source-backed context projection before and after a session resume."""
function JuliaForever2.history_journal_context(archive::TerminalArchive, session::Session)
    timeline = archive.timeline
    isnothing(timeline) ? nothing : JuliaForever2.timeline_runtime_messages(timeline)
end

"""Retain only reported usage fields; missing metering is never invented as zero."""
function archive_reported_usage!(payload::Dict{String,Any}, response)
    provenance=JuliaForever2.response_usage_provenance(response)
    namespace=get(payload,"jf2",nothing)
    if provenance isa AbstractDict && (isnothing(namespace) || namespace isa AbstractDict)
        owned=isnothing(namespace) ? Dict{String,Any}() : Dict{String,Any}(deepcopy(namespace))
        owned["usageProvenance"]=provenance
        payload["jf2"]=owned
    end
    usage = JuliaForever2.response_usage(response)
    if !haskey(payload, "usage") && usage isa JuliaForever2.UsageReport
        data = Dict{String,Any}()
        for (name, value) in (("input", usage.input_tokens), ("output", usage.output_tokens),
                ("cacheRead", usage.cache_read_tokens), ("cacheWrite", usage.cache_write_tokens), ("cost", usage.cost))
            isnothing(value) || (data[name] = value)
        end
        isempty(data) || (payload["usage"] = data)
    end
    payload
end

"""Restore cumulative and last-context usage from the selected branch's real assistant records."""
function restore_timeline_usage!(session::Session, timeline)
    for entry in JuliaForever2.timeline_branch(timeline)
        if entry["type"] == "message" && get(entry["message"], "role", nothing) == "assistant"
            usage = get(entry["message"], "usage", nothing)
            accounting=JuliaForever2.message_usage_accounting(entry["message"])
            if usage isa AbstractDict || accounting.provenance==:native
                JuliaForever2.record_usage!(session, accounting.report)
            end
        end
    end
    session
end

"""Restore only an exact catalog-backed archived model; never guess a provider or billing route."""
function archived_model_configuration(app::App, projection; kernel=app.session.kernel)
    identity = projection.model
    if identity isa AbstractDict && get(identity, "provider", nothing) isa AbstractString &&
            get(identity, "modelId", nothing) isa AbstractString && !isempty(identity["modelId"])
        requested = Symbol(identity["provider"])
        active = provider_selection_snapshot(kernel).id
        allowed = requested == active || requested in configured_model_providers(app) || requested == Symbol("openai-codex") && active in (:chatgpt, :codex)
        if !allowed
            error("The archived model provider is not configured in this application")
        end
        current = component(kernel, :provider)
        prepared = JuliaForever2.prepare_model_configuration(current, app.settings.registry;
            provider_id=requested, model_id=identity["modelId"], thinking_level=projection.thinking_level,
            directory=app.settings.directory, allow_provider_change=true)
        prepared.ok || error(prepared.reason)
        prepared
    else
        nothing
    end
end

function dispose_runtime_candidate!(kernel, executor, ::Nothing)
    cleanup_executor = Task(() -> JuliaForever2.close_executor!(executor))
    cleanup_kernel = Task(() -> close(kernel))
    schedule(cleanup_executor)
    schedule(cleanup_kernel)
    wait(cleanup_executor; throw=false)
    wait(cleanup_kernel; throw=false)
    nothing
end

dispose_runtime_candidate!(kernel, executor, session::Session) = close(session)

"""Record only actual selected native configuration, never invented provider defaults."""
function seed_archive_configuration!(timeline, session::Session)
    provider = component(session.kernel, :provider)
    identity = JuliaForever2.provider_model_identity(provider)
    thinking = JuliaForever2.current_thinking_level(provider)
    if !isempty(identity.model_id)
        JuliaForever2.timeline_append!(timeline, Dict("type" => "model_change",
            "provider" => String(identity.provider_id), "modelId" => identity.model_id))
    end
    if thinking isa AbstractString
        JuliaForever2.timeline_append!(timeline, Dict("type" => "thinking_level_change", "thinkingLevel" => String(thinking)))
    end
    timeline
end
