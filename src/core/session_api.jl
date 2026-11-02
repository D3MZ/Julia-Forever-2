"""An owned, replaceable interface to independent Julia sessions and their durable state."""
mutable struct SessionAPI{F,S,Q,T,W}
    factory::F
    store::S
    query::Q
    titles::T
    workspaces::W
    lock::ReentrantLock
    sessions::Dict{String,Session}
    handles::Dict{String,TaskHandle}
    closing::Set{String}
    closed::Bool
end

api_default_workspaces(::Any) = nothing
api_default_workspaces(store::SessionStore) = WorkspaceRegistry(store)

"""Construct a native session API; factories return a Kernel or AgentDefinition."""
SessionAPI(; factory=Kernel, store=nothing, query=nothing, titles=nothing, workspaces=api_default_workspaces(store)) = SessionAPI(factory, store, query, titles, workspaces, ReentrantLock(), Dict{String,Session}(), Dict{String,TaskHandle}(), Set{String}(), false)

"""Preserve the existing positional SessionAPI constructor for callers not using workspaces."""
SessionAPI(factory, store, query, titles, lock::ReentrantLock, sessions::Dict{String,Session}, handles::Dict{String,TaskHandle}, closing::Set{String}, closed::Bool) = SessionAPI(factory, store, query, titles, api_default_workspaces(store), lock, sessions, handles, closing, closed)

api_create_session(target::Kernel; kwargs...) = Session(target; owns_kernel=true, kwargs...)
api_create_session(target::AgentDefinition; kwargs...) = Session(target; kwargs...)

function api_session_summary(name::AbstractString, session::Session)
    lineage = session_lineage(session)
    return Dict("session" => String(name), "id" => string(lineage.id),
        "parent" => isnothing(lineage.parent_id) ? nothing : string(lineage.parent_id),
        "root" => string(lineage.root_id), "workingDirectory" => working_directory(session),
        "messages" => lock(() -> length(session.conversation.messages), session.conversation.lock))
end

api_message(message::Message) = Dict("role" => String(message.role), "kind" => String(message.kind), "content" => message.content)

api_hit(hit) = Dict("session" => hit.session, "index" => hit.index, "role" => String(hit.role), "kind" => String(hit.kind), "content" => hit.content)

api_parameter(params::AbstractDict, key::String) = get(params, key, nothing)

api_session(api::SessionAPI, params::AbstractDict) = api_session(api, api_parameter(params, "session"))
api_session(api::SessionAPI, name) = RpcError(-32602, "Expected a session identifier")

function api_session(api::SessionAPI, name::AbstractString)
    lock(api.lock) do
        api.closed ? RpcError(-32000, "Session API is closed") :
            String(name) in api.closing ? RpcError(-32000, "Session is closing: $name") :
            get(api.sessions, String(name), RpcError(-32004, "Unknown session: $name"))
    end
end

apply(f, session::Session) = f(session)
apply(f, error::RpcError) = error
"""Open a new Julia session or resume a persisted session using the selected factory."""
function api_open_session!(api::SessionAPI, params::AbstractDict; resume=false)
    name = get(params, "session", string(uuid4()))
    directory = get(params, "workingDirectory", pwd())
    if !(name isa AbstractString && !isempty(name))
        RpcError(-32602, "Invalid session identifier")
    elseif !(directory isa AbstractString && isdir(directory))
        RpcError(-32602, "Invalid working directory")
    elseif !isnothing(api.store) && isnothing(session_file(api.store, name))
        RpcError(-32602, "Invalid persisted session identifier")
    else
        create!(api, name, directory, resume)
    end
end

function create!(api::SessionAPI, name::AbstractString, directory::AbstractString, resume::Bool)
    lock(api.lock) do
        if api.closed
            RpcError(-32000, "Session API is closed")
        elseif haskey(api.sessions, String(name)) || String(name) in api.closing
            RpcError(-32000, "Session is already open: $name")
        else
            restore!(api, name, directory, resume)
        end
    end
end

function restore!(api::SessionAPI, name, directory, resume)
    if !isnothing(api.store) && session_archived(api.store, name)
        RpcError(-32000, "Session is archived: $name")
    else
        record = resume && !isnothing(api.store) ? saved_session_record(api.store, name) : nothing
        if resume && isnothing(record)
            RpcError(-32004, "Session was not saved: $name")
        else
            session = restore(Base.invokelatest(api.factory), record, directory)
            api.sessions[String(name)] = session
            api_session_summary(name, session)
        end
    end
end

restore(target::Union{Kernel,AgentDefinition}, ::Nothing, directory) = api_create_session(target; working_directory=directory)
restore(target::Union{Kernel,AgentDefinition}, record, directory) = api_create_session(target; messages=record.messages, compaction_entry=record.compaction,
    working_directory=record.directory, id=record.lineage.id,
    parent_id=record.lineage.parent_id, root_id=record.lineage.root_id)

"""Reserve the name before waiting or saving, without holding the API lock."""
function api_close_session!(api::SessionAPI, params::AbstractDict)
    apply(api_session(api, params)) do session
        name = String(params["session"])
        reserved = lock(api.lock) do
            if api.closed || get(api.sessions, name, nothing) !== session || name in api.closing
                false
            else
                push!(api.closing, name)
                true
            end
        end
        if !reserved
            RpcError(-32000, "Session is not available: $name")
        elseif !isnothing(api.store) && executing_owned_work(session)
            lock(() -> delete!(api.closing, name), api.lock)
            RpcError(-32000, "A session cannot synchronously close its own work")
        else
            close_reserved_session!(api, name, session)
        end
    end
end

function close_reserved_session!(api::SessionAPI, name::String, session::Session)
    handle = lock(() -> get(api.handles, name, nothing), api.lock)
    worker = spawn_scoped(() -> persist_before_close!(api.store, name, session, handle))
    wait(worker; throw=false)
    saved = istaskfailed(worker) ? (ok=false, reason="Persistence failed") : fetch(worker)
    saved = normalize_close_save(saved)
    failed = !saved.ok
    if !(failed isa Bool)
        lock(() -> delete!(api.closing, name), api.lock)
        RpcError(-32000, "Session could not be saved: invalid persistence status")
    elseif failed
        lock(() -> delete!(api.closing, name), api.lock)
        RpcError(-32000, "Session could not be saved: $(saved.reason)")
    else
        removed = lock(api.lock) do
            if api.closed || get(api.sessions, name, nothing) !== session
                false
            else
                pop!(api.sessions, name)
                pop!(api.handles, name, nothing)
                true
            end
        end
        if removed
            close(session)
            lock(() -> delete!(api.closing, name), api.lock)
            Dict("closed" => true)
        else
            lock(() -> delete!(api.closing, name), api.lock)
            RpcError(-32000, "Session is not available: $name")
        end
    end
end

"""Reject missing status without inspecting custom persistence results on another task."""
normalize_close_save(::Nothing) = (ok=false, reason="Persistence failed")
normalize_close_save(saved::NamedTuple) = haskey(saved, :ok) && applicable(!, saved.ok) ? saved : (ok=false, reason="Persistence failed")
normalize_close_save(saved) = saved

persist_before_close!(::Nothing, name, session::Session, handle) = (ok=true, reason="")

function persist_before_close!(store, name, session::Session, handle)
    settle_for_close!(handle)
    save_session!(store, name, session)
end

settle_for_close!(::Nothing) = nothing

function settle_for_close!(handle::TaskHandle)
    istaskdone(handle) || cancel!(handle)
    wait(handle; throw=false)
    nothing
end
api_session_detail(api::SessionAPI, params::AbstractDict) = apply(session -> api_session_summary(params["session"], session), api_session(api, params))
api_session_messages(api::SessionAPI, params::AbstractDict) = apply(session -> api_message.(history_snapshot(session).messages), api_session(api, params))

"""Resolve a replaceable durable store without holding the API lock during I/O."""
function api_saved_store(api::SessionAPI)
    lock(api.lock) do
        api.closed ? RpcError(-32000, "Session API is closed") :
            isnothing(api.store) ? RpcError(-32601, "No persistent session store is configured") : api.store
    end
end

saved_summaries(error::RpcError) = error
saved_summaries(store) = session_summaries(store)
saved_summaries(error::RpcError, ::Nothing) = error
saved_summaries(error::RpcError, ::Bool) = error
saved_summaries(store, ::Nothing) = session_summaries(store)
saved_summaries(store, archived::Bool) = archived ?
    RpcError(-32601, "Session archive service is not configured") : session_summaries(store)
saved_summaries(store::SessionStore, archived::Bool) = session_summaries(store; archived)

function api_saved_session_list(api::SessionAPI, params::AbstractDict)
    archived = get(params, "archived", nothing)
    isnothing(archived) || archived isa Bool ?
        saved_summaries(api_saved_store(api), archived) :
        RpcError(-32602, "Archived filter must be Boolean")
end

"""List live and saved Julia sessions as one identity-aware, cold-safe projection.

Live state wins when the same durable UUID is open and saved. A new live
session reusing a saved name has a different UUID and remains a separate row.
An optional store is queried through its replaceable session_summaries method.
"""
api_session_inventory(api::SessionAPI, params::AbstractDict) = api_inventory_filter(api, get(params, "archived", false))
api_inventory_filter(::SessionAPI, archived) = RpcError(-32602, "Archived filter must be Boolean")

function api_inventory_filter(api::SessionAPI, archived::Bool)
    snapshot = lock(api.lock) do
        api.closed ? RpcError(-32000, "Session API is closed") :
            (collect(pairs(api.sessions)), api.store)
    end
    api_inventory_snapshot(snapshot, archived)
end

api_inventory_snapshot(error::RpcError, ::Bool) = error

function api_inventory_snapshot(snapshot::Tuple, archived::Bool)
    live, store = snapshot
    saved = isnothing(store) ? Dict{String,Any}[] : saved_summaries(store, archived)
    api_inventory_rows(live, saved, archived)
end

api_inventory_rows(live, error::RpcError, ::Bool) = error

function api_inventory_rows(live, saved, archived::Bool)
    records = Dict{String,Dict{String,Any}}()
    for row in saved
        summary = Dict{String,Any}(String(key) => value for (key, value) in pairs(row))
        identity = string(summary["id"])
        summary["live"] = false
        summary["persisted"] = true
        summary["archived"] = archived
        records[identity] = summary
    end
    if !archived
        for (name, session) in live
            summary = Dict{String,Any}(api_session_summary(name, session))
            identity = string(summary["id"])
            summary["persisted"] = haskey(records, identity)
            summary["live"] = true
            summary["archived"] = false
            records[identity] = summary
        end
    end
    sort!(collect(values(records)); by=row -> (String(row["session"]), string(row["id"])))
end

"""Group cold-safe session summaries by lexical working directory, not process ownership.

This is a derived view, not a persistent Workspace registry or authorization boundary.
The caller retains ownership of all session state and may replace the API service.
"""
function session_workspace_groups(summaries::AbstractVector)
    groups = Dict{String,Vector{Dict{String,Any}}}()
    for row in summaries
        directory = normpath(String(row["workingDirectory"]))
        summary = Dict{String,Any}(String(key) => value for (key, value) in pairs(row))
        push!(get!(groups, directory, Dict{String,Any}[]), summary)
    end
    result = Dict{String,Any}[]
    for (directory, sessions) in groups
        sort!(sessions; by=row -> (String(row["session"]), String(row["id"])))
        push!(result, Dict{String,Any}(
            "workingDirectory" => directory, "sessions" => sessions,
            "sessionCount" => length(sessions)))
    end
    sort!(result; by=row -> String(row["workingDirectory"]))
end

"""Project live and persisted Julia sessions into independent directory groups."""
function api_session_workspace_groups(api::SessionAPI, params::AbstractDict)
    sessions = api_session_inventory(api, params)
    if sessions isa RpcError
        sessions
    elseif isnothing(api.workspaces)
        session_workspace_groups(sessions)
    else
        registered_workspace_groups(api.workspaces, sessions)
    end
end

"""Resolve the optional, replaceable registry without trusting browser-supplied identity."""
function api_workspace_registry(api::SessionAPI)
    lock(api.lock) do
        api.closed ? RpcError(-32000, "Session API is closed") :
            isnothing(api.workspaces) ? RpcError(-32601, "Workspace registry is not configured") :
            api.workspaces
    end
end

workspace_api_result(result::RpcError) = result
workspace_api_result(result) = result.ok ? result.value :
    RpcError(result.reason == "Unknown workspace" ? -32004 : -32602, result.reason)

"""Apply registry mutations only after successful registry resolution."""
api_workspace_apply(f, api::SessionAPI) = api_workspace_apply(f, api_workspace_registry(api))
api_workspace_apply(f, error::RpcError) = error
api_workspace_apply(f, registry) = workspace_api_result(f(registry))

function api_workspace_list(api::SessionAPI, params::AbstractDict)
    registry = api_workspace_registry(api)
    registry isa RpcError ? registry : workspace_snapshot(registry)
end

function api_workspace_create!(api::SessionAPI, params::AbstractDict)
    path = get(params, "path", nothing)
    title = get(params, "title", nothing)
    if path isa AbstractString && (isnothing(title) || title isa AbstractString)
        api_workspace_apply(api) do registry
            register_workspace!(registry, path; title)
        end
    else
        RpcError(-32602, "Expected an absolute directory and optional title")
    end
end

function api_workspace_rename!(api::SessionAPI, params::AbstractDict)
    id = get(params, "workspaceId", nothing)
    title = get(params, "title", nothing)
    if id isa AbstractString && title isa AbstractString
        api_workspace_apply(api) do registry
            rename_workspace!(registry, id, title)
        end
    else
        RpcError(-32602, "Expected a workspace identifier and title")
    end
end

function api_workspace_delete!(api::SessionAPI, params::AbstractDict)
    id = get(params, "workspaceId", nothing)
    if id isa AbstractString
        api_workspace_apply(api) do registry
            delete_workspace!(registry, id)
        end
    else
        RpcError(-32602, "Expected a workspace identifier")
    end
end

function api_workspace_move!(api::SessionAPI, params::AbstractDict)
    id = get(params, "workspaceId", nothing)
    before = get(params, "beforeWorkspaceId", nothing)
    if id isa AbstractString && (isnothing(before) || before isa AbstractString)
        api_workspace_apply(api) do registry
            move_workspace!(registry, id, before)
        end
    else
        RpcError(-32602, "Invalid workspace ordering request")
    end
end

api_workspace_move_members(registry, error::RpcError, id, session_id, before) = error

function api_workspace_move_members(registry, inventory::AbstractVector, id, session_id, before)
    groups = registered_workspace_groups(registry, inventory)
    index = findfirst(group -> get(group, "workspaceId", nothing) == id, groups)
    if isnothing(index)
        RpcError(-32004, "Unknown workspace")
    else
        members = String[string(row["id"]) for row in groups[index]["sessions"]]
        move_workspace_session!(registry, id, session_id, before, members)
    end
end

function api_workspace_session_move!(api::SessionAPI, params::AbstractDict)
    id = get(params, "workspaceId", nothing)
    session_id = get(params, "sessionId", nothing)
    before = get(params, "beforeSessionId", nothing)
    if id isa AbstractString && session_id isa AbstractString &&
            (isnothing(before) || before isa AbstractString)
        api_workspace_apply(api) do registry
            api_workspace_move_members(registry, api_session_inventory(api, Dict{String,Any}()), id, session_id, before)
        end
    else
        RpcError(-32602, "Invalid workspace session ordering request")
    end
end

function api_workspace_feed(api::SessionAPI, params::AbstractDict)
    since = get(params, "since", nothing)
    if isnothing(since) || (since isa Integer && !(since isa Bool) && since >= 0)
        registry = api_workspace_registry(api)
        registry isa RpcError ? registry : workspace_changes(registry; since)
    else
        RpcError(-32602, "Workspace cursor must be a nonnegative integer")
    end
end

saved_summary(error::RpcError, name) = error
saved_summary(error::RpcError, ::AbstractString) = error
saved_summary(store, name) = RpcError(-32602, "Expected a session identifier")
saved_summary(store, name::AbstractString) = isempty(name) ?
    RpcError(-32602, "Expected a session identifier") : saved_summary_lookup(store, name)
saved_summary_lookup(store, name) = something(session_summary(store, name),
    RpcError(-32004, "Session was not saved: $name"))
api_saved_session_detail(api::SessionAPI, params::AbstractDict) =
    saved_summary(api_saved_store(api), api_parameter(params, "session"))

"""Set the durable archive status only after the live Julia session has closed."""
function api_set_saved_archive!(api::SessionAPI, params::AbstractDict, archived::Bool)
    name = api_parameter(params, "session")
    if !(name isa AbstractString && !isempty(name))
        RpcError(-32602, "Expected a session identifier")
    elseif archived && get(params, "stopActivity", false) !== false
        RpcError(-32602, "Stopping an active session during archive is not supported")
    else
        identity = String(name)
        lock(api.lock) do
            if api.closed
                RpcError(-32000, "Session API is closed")
            elseif isnothing(api.store)
                RpcError(-32601, "No persistent session store is configured")
            elseif archived && (haskey(api.sessions, identity) || identity in api.closing)
                RpcError(-32000, "Close the live session before archiving: $name")
            else
                result = archived ? archive_session!(api.store, identity) :
                    unarchive_session!(api.store, identity)
                if result.ok
                    Dict("archived" => archived)
                elseif startswith(result.reason, "Session was not saved:")
                    RpcError(-32004, result.reason)
                elseif result.reason == "Session archive service is not configured"
                    RpcError(-32601, result.reason)
                else
                    RpcError(-32602, result.reason)
                end
            end
        end
    end
end

"""List ordered native pin identities without loading or resuming any session."""
pinned_saved_sessions(error::RpcError) = error
function pinned_saved_sessions(store)
    names = pinned_sessions(store)
    isnothing(names) ? RpcError(-32601, "Session pin service is not configured") : names
end

"""Adapt optional pin mutations to the Julia-native, replaceable session RPC."""
pin_saved_session!(error::RpcError, name::AbstractString, pinned::Bool) = error
function pin_saved_session!(store, name::AbstractString, pinned::Bool)
    result = pinned ? pin_session!(store, name) : unpin_session!(store, name)
    if result.ok
        Dict("pinned" => pinned)
    elseif result.reason == "Session pin service is not configured"
        RpcError(-32601, result.reason)
    elseif startswith(result.reason, "Session was not saved:")
        RpcError(-32004, result.reason)
    elseif startswith(result.reason, "Session is archived:")
        RpcError(-32000, result.reason)
    else
        RpcError(-32602, result.reason)
    end
end

function api_set_saved_pin!(api::SessionAPI, params::AbstractDict, pinned::Bool)
    name = api_parameter(params, "session")
    name isa AbstractString && !isempty(name) ?
        pin_saved_session!(api_saved_store(api), String(name), pinned) :
        RpcError(-32602, "Expected a session identifier")
end

api_pinned_session_list(api::SessionAPI, params::AbstractDict) =
    pinned_saved_sessions(api_saved_store(api))

"""Export public session text through a Julia-owned, replaceable Markdown renderer."""
function api_session_markdown(api::SessionAPI, params::AbstractDict)
    title = get(params, "title", nothing)
    source_path = get(params, "sourcePath", nothing)
    if !(isnothing(title) || title isa AbstractString) ||
            !(isnothing(source_path) || source_path isa AbstractString)
        RpcError(-32602, "Invalid Markdown export options")
    else
        apply(api_session(api, params)) do session
            Dict("markdown" => session_markdown(session; title, source_path))
        end
    end
end

"""Validate external predicates before constructing a native history query."""
function api_search_parameters(params::AbstractDict)
    text = api_parameter(params, "text")
    roles = get(params, "roles", nothing)
    limit = get(params, "limit", typemax(Int))
    sessions = get(params, "sessions", nothing)
    first = get(params, "fromIndex", nothing)
    last = get(params, "toIndex", nothing)
    if !(text isa AbstractString && !isempty(strip(text)))
        RpcError(-32602, "Search text is required")
    elseif !(isnothing(roles) || roles isa AbstractVector && all(role -> role isa Union{Symbol,AbstractString}, roles))
        RpcError(-32602, "Search roles must be an array of strings")
    elseif !(limit isa Integer && !(limit isa Bool) && limit >= 0)
        RpcError(-32602, "Invalid search limit")
    elseif !(isnothing(sessions) || sessions isa AbstractVector && all(name -> name isa AbstractString, sessions))
        RpcError(-32602, "Search sessions must be an array of strings")
    elseif !(validindex(first) && validindex(last))
        RpcError(-32602, "Search index bounds must be positive integers")
    elseif !isnothing(first) && !isnothing(last) && first > last
        RpcError(-32602, "Search lower index exceeds upper index")
    else
        (text=String(text), roles, limit, sessions, from_index=first, to_index=last)
    end
end

function api_session_search(api::SessionAPI, params::AbstractDict)
    apply(api_session(api, params)) do session
        searchresponse(session, api_search_parameters(params))
    end
end

searchresponse(source, error::RpcError) = error
searchresponse(session::Session, query::NamedTuple) = isnothing(query.sessions) ? api_hit.(search_history(session, query.text; roles=query.roles, limit=query.limit, from_index=query.from_index, to_index=query.to_index)) : RpcError(-32602, "Session selection requires persisted search")
searchresponse(source, query::NamedTuple) = api_hit.(search_history(source, query.text; roles=query.roles, limit=query.limit, sessions=query.sessions, from_index=query.from_index, to_index=query.to_index))

"""Search persisted history without opening sessions or bypassing custom query services."""
function api_persisted_search(api::SessionAPI, params::AbstractDict)
    source = lock(api.lock) do
        api.closed ? RpcError(-32000, "Session API is closed") : isnothing(api.query) ? api.store : api.query
    end
    persisted(source, params)
end

persisted(error::RpcError, params) = error
persisted(::Nothing, params) = RpcError(-32601, "No persistent session search service is configured")
persisted(source, params) = searchresponse(source, api_search_parameters(params))

function api_session_workspace(api::SessionAPI, params::AbstractDict; change=false)
    apply(api_session(api, params)) do session
        change ? workspace(session, api_parameter(params, "path")) : workspace(session)
    end
end

workspace(session::Session) = Dict("workingDirectory" => working_directory(session))
workspace(session::Session, path) = RpcError(-32602, "Expected a path")

function workspace(session::Session, path::AbstractString)
    selected = set_working_directory!(session, path)
    selected.ok ? workspace(session) : RpcError(-32602, selected.reason)
end
function api_session_save(api::SessionAPI, params::AbstractDict)
    stored(api, params) do session
        saved = save_session!(api.store, params["session"], session)
        saved.ok ? Dict("saved" => true) : RpcError(-32602, saved.reason)
    end
end

stored(f, api::SessionAPI, params) = isnothing(api.store) ? RpcError(-32601, "No persistent session store is configured") : apply(f, api_session(api, params))
api_session_children(api::SessionAPI, params::AbstractDict) = stored(session -> session_descendants(api.store, session), api, params)
"""Admit at most one active Julia turn per session without replacing its cancellation handle."""
function api_session_turn!(api::SessionAPI, params::AbstractDict)
    apply(api_session(api, params)) do session
        prompt = api_parameter(params, "prompt")
        include_id = get(params, "includeOperationId", false)
        name = String(params["session"])
        if !(prompt isa AbstractString && !isempty(prompt))
            RpcError(-32602, "Prompt is required")
        elseif !(include_id isa Bool)
            RpcError(-32602, "includeOperationId must be Boolean")
        else
            lock(api.lock) do
                previous = get(api.handles, name, nothing)
                if api.closed || get(api.sessions, name, nothing) !== session || name in api.closing
                    RpcError(-32000, "Session is not available: $name")
                elseif !isnothing(api.store) && session_archived(api.store, name)
                    RpcError(-32000, "Session is archived: $name")
                elseif !isnothing(previous) && !istaskdone(previous)
                    RpcError(-32000, "Session already has an active turn: $name")
                else
                    handle = submit_turn!(session, prompt)
                    api.handles[name] = handle
                    include_id ? Dict{String,Any}("accepted" => true,
                        "operationId" => api_operation_id(handle)) : Dict("accepted" => true)
                end
            end
        end
    end
end

"""Cancel only the in-flight operation; preserve the Julia session and future turns."""
function api_session_cancel!(api::SessionAPI, params::AbstractDict)
    name = api_parameter(params, "session")
    target = get(params, "operationId", nothing)
    if !(name isa AbstractString && !isempty(name))
        RpcError(-32602, "Expected a session identifier")
    elseif !valid_operation_target(target)
        RpcError(-32602, "Expected a nonempty operation identifier")
    else
        lock(api.lock) do
            if api.closed
                RpcError(-32000, "Session API is closed")
            elseif !haskey(api.sessions, String(name))
                Dict("cancelled" => false)
            else
                handle = get(api.handles, String(name), nothing)
                matches_operation(handle, target) ? cancel_api_turn!(handle) : Dict("cancelled" => false)
            end
        end
    end
end

const API_OPERATION_NAMESPACE = Ref{String}("")

function __init__()
    API_OPERATION_NAMESPACE[] = string(uuid4())
    nothing
end

api_operation_id(handle::TaskHandle) = string(API_OPERATION_NAMESPACE[], ':', operation_id(handle.context))
valid_operation_target(target) = isnothing(target) || (target isa AbstractString && !isempty(target))
matches_operation(handle, ::Nothing) = true
matches_operation(::Nothing, ::AbstractString) = false
matches_operation(handle::TaskHandle, target::AbstractString) = api_operation_id(handle) == target
cancel_api_turn!(::Nothing) = Dict("cancelled" => false)

function cancel_api_turn!(handle::TaskHandle)
    active = !istaskdone(handle) && !cancelled(handle.context)
    active && cancel!(handle)
    return Dict("cancelled" => active)
end
function api_session_wait(api::SessionAPI, params::AbstractDict)
    target = get(params, "operationId", nothing)
    if !valid_operation_target(target)
        RpcError(-32602, "Expected a nonempty operation identifier")
    else
        apply(api_session(api, params)) do session
            handle = lock(() -> get(api.handles, String(params["session"]), nothing), api.lock)
            matches_operation(handle, target) ? status(handle) : Dict("status" => "stale")
        end
    end
end

status(::Nothing) = Dict("status" => "idle")

function status(handle::TaskHandle)
    result = fetch(handle)
    Dict("status" => "completed", "ok" => result.ok, "text" => result.text)
end
"""Fork a stable message prefix into an independently owned Julia session."""
function api_session_fork!(api::SessionAPI, params::AbstractDict)
    source = api_parameter(params, "session")
    destination = get(params, "newSession", string(uuid4()))
    boundary = api_parameter(params, "atIndex")
    if !(source isa AbstractString && !isempty(source))
        RpcError(-32602, "Expected a session identifier")
    elseif !(destination isa AbstractString && !isempty(destination))
        RpcError(-32602, "Invalid fork session identifier")
    elseif !validindex(boundary)
        RpcError(-32602, "Fork index must be a positive integer")
    elseif !isnothing(api.store) && isnothing(session_file(api.store, destination))
        RpcError(-32602, "Invalid persisted session identifier")
    else
        lock(api.lock) do
            api_fork_locked!(api, String(source), String(destination), boundary)
        end
    end
end

function api_fork_locked!(api::SessionAPI, source::String, destination::String, boundary)
    if api.closed
        RpcError(-32000, "Session API is closed")
    elseif !haskey(api.sessions, source)
        RpcError(-32004, "Unknown session: $source")
    elseif source in api.closing
        RpcError(-32000, "Session is closing: $source")
    elseif haskey(api.sessions, destination) || destination in api.closing
        RpcError(-32000, "Session is already open: $destination")
    elseif !isnothing(api.store) && session_archived(api.store, destination)
        RpcError(-32000, "Session is archived: $destination")
    else
        original = api.sessions[source]
        handle = get(api.handles, source, nothing)
        if !isopen(original)
            RpcError(-32000, "Session is not available: $source")
        elseif !isnothing(handle) && !istaskdone(handle)
            RpcError(-32000, "Cannot fork while a turn is active: $source")
        else
            api_fork_snapshot!(api, original, destination, boundary)
        end
    end
end

function api_fork_snapshot!(api::SessionAPI, source::Session, destination::String, boundary)
    messages = history_snapshot(source).messages
    last = something(boundary, length(messages))
    if last < 1 || last > length(messages)
        RpcError(-32602, "Fork index is outside the session history")
    else
        inherited = messages[1:Int(last)]
        child = Base.invokelatest(fork_session, source, inherited)
        api.sessions[destination] = child
        isnothing(api.titles) || inherit_session_title!(api.titles, source, child)
        api_session_summary(destination, child)
    end
end

"""Read the optional title service without projecting title state into model messages."""
function api_session_title(api::SessionAPI, params::AbstractDict)
    if isnothing(api.titles)
        RpcError(-32601, "No session title service is configured")
    else
        apply(api_session(api, params)) do session
            Dict("title" => session_title(api.titles, session))
        end
    end
end

"""Accept an explicit human rename, preserving the original session identity."""
function api_session_rename_title!(api::SessionAPI, params::AbstractDict)
    input = api_parameter(params, "title")
    if isnothing(api.titles)
        RpcError(-32601, "No session title service is configured")
    elseif !(input isa AbstractString)
        RpcError(-32602, "Expected a session title")
    else
        apply(api_session(api, params)) do session
            accepted = rename_session_title!(api.titles, session, input)
            isnothing(accepted) ? RpcError(-32602, "Invalid session title") :
                Dict("title" => accepted)
        end
    end
end

"""Explicitly reset a pinned title to the current first-eligible-message fallback."""
function api_session_refresh_title!(api::SessionAPI, params::AbstractDict)
    if isnothing(api.titles)
        RpcError(-32601, "No session title service is configured")
    else
        apply(api_session(api, params)) do session
            Dict("title" => refresh_session_title!(api.titles, session))
        end
    end
end

"""Dispatch a Julia-native session API command, independently of protocol transports."""
struct SessionCommand{F,P}
    method::String
    operation::F
    parameters::P
end

const SESSION_OPERATIONS = Dict(
    "session/open" => api_open_session!,
    "session/resume" => (api, params) -> api_open_session!(api, params; resume=true),
    "session/list" => (api, params) -> lock(() -> sort!(collect(keys(api.sessions))), api.lock),
    "session/list/saved" => api_saved_session_list,
    "session/list/all" => api_session_inventory,
    "session/list/workspaces" => api_session_workspace_groups,
    "workspace/list" => api_workspace_list,
    "workspace/create" => api_workspace_create!,
    "workspace/rename" => api_workspace_rename!,
    "workspace/delete" => api_workspace_delete!,
    "workspace/move" => api_workspace_move!,
    "workspace/session/move" => api_workspace_session_move!,
    "workspace/feed" => api_workspace_feed,
    "session/archive" => (api, params) -> api_set_saved_archive!(api, params, true),
    "session/unarchive" => (api, params) -> api_set_saved_archive!(api, params, false),
    "session/pin" => (api, params) -> api_set_saved_pin!(api, params, true),
    "session/unpin" => (api, params) -> api_set_saved_pin!(api, params, false),
    "session/list/pinned" => api_pinned_session_list,
    "session/describe/saved" => api_saved_session_detail,
    "session/describe" => api_session_detail,
    "session/messages" => api_session_messages,
    "session/markdown" => api_session_markdown,
    "session/title/get" => api_session_title,
    "session/title/rename" => api_session_rename_title!,
    "session/title/refresh" => api_session_refresh_title!,
    "session/search" => api_session_search,
    "session/search/all" => api_persisted_search,
    "session/workspace/get" => api_session_workspace,
    "session/workspace/set" => (api, params) -> api_session_workspace(api, params; change=true),
    "session/save" => api_session_save,
    "session/children" => api_session_children,
    "session/fork" => api_session_fork!,
    "session/turn" => api_session_turn!,
    "session/cancel" => api_session_cancel!,
    "session/wait" => api_session_wait,
    "session/close" => api_close_session!,
)

SessionCommand(method::AbstractString, params::AbstractDict) = SessionCommand(String(method), get(SESSION_OPERATIONS, method, nothing), params)
execute!(api::SessionAPI, command::SessionCommand{Nothing}) = RpcError(-32601, "Unknown Julia session method: $(command.method)")
execute!(api::SessionAPI, command::SessionCommand) = command.operation(api, command.parameters)
session_api_request!(api::SessionAPI, method::AbstractString, params::AbstractDict=Dict{String,Any}()) = execute!(api, SessionCommand(method, params))
"""Bind the native API to caller-owned JSON-RPC byte streams without launching a DSH process."""
session_api_peer(api::SessionAPI, input, output) = JsonRpcPeer(input, output; on_request=(method, params) -> session_api_request!(api, method, params))

function Base.close(api::SessionAPI)
    sessions = lock(api.lock) do
        if api.closed
            Session[]
        else
            api.closed = true
            snapshot = collect(values(api.sessions))
            empty!(api.sessions)
            empty!(api.handles)
            empty!(api.closing)
            snapshot
        end
    end
    foreach(close, sessions)
    nothing
end
"""Install the replaceable Julia session API service under a profile."""
function session_api_plugin(; name=:session_api, service_name=:session_api,
        store_service=nothing, query_service=nothing, title_service=nothing,
        workspace_service=nothing, factory=Kernel)
    contract = Symbol(service_name)
    dependencies = unique(Symbol[Symbol(dependency) for dependency in
        (store_service, query_service, title_service, workspace_service) if !isnothing(dependency)])
    setup = context -> begin
        store = isnothing(store_service) ? nothing : service(context, Symbol(store_service))
        query = isnothing(query_service) ? nothing : service(context, Symbol(query_service))
        titles = isnothing(title_service) ? nothing : service(context, Symbol(title_service))
        workspaces = isnothing(workspace_service) ? api_default_workspaces(store) :
            service(context, Symbol(workspace_service))
        provide!(context, contract, SessionAPI(; factory, store, query, titles, workspaces);
            requires=dependencies, cleanup=close)
    end
    PluginSpec(name, setup; requires=dependencies, provides=[contract])
end
