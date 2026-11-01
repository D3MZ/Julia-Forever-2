"""An owned, replaceable interface to independent Julia sessions and their durable state."""
mutable struct SessionAPI{F,S,Q}
    factory::F
    store::S
    query::Q
    lock::ReentrantLock
    sessions::Dict{String,Session}
    handles::Dict{String,TaskHandle}
    closed::Bool
end

"""Construct a native session API with optional independently replaceable durable search."""
SessionAPI(; factory=Kernel, store=nothing, query=nothing) =
    SessionAPI(factory, store, query, ReentrantLock(),
        Dict{String,Session}(), Dict{String,TaskHandle}(), false)

api_create_session(target::Kernel; kwargs...) = Session(target; owns_kernel=true, kwargs...)
api_create_session(target::AgentDefinition; kwargs...) = Session(target; kwargs...)

function api_session_summary(name::AbstractString, session::Session)
    lineage = session_lineage(session)
    return Dict("session" => String(name), "id" => string(lineage.id),
        "parent" => isnothing(lineage.parent_id) ? nothing : string(lineage.parent_id),
        "root" => string(lineage.root_id), "workingDirectory" => working_directory(session),
        "messages" => length(history_snapshot(session).messages))
end

function api_message(message::Message)
    return Dict("role" => String(message.role), "kind" => String(message.kind), "content" => message.content)
end

function api_hit(hit)
    return Dict("session" => hit.session, "index" => hit.index, "role" => String(hit.role),
        "kind" => String(hit.kind), "content" => hit.content)
end

api_parameter(params::AbstractDict, key::String) = get(params, key, nothing)

function api_session(api::SessionAPI, params::AbstractDict)
    name = api_parameter(params, "session")
    name isa AbstractString || return RpcError(-32602, "Expected a session identifier")
    return lock(api.lock) do
        api.closed && return RpcError(-32000, "Session API is closed")
        return get(api.sessions, String(name), RpcError(-32004, "Unknown session: $name"))
    end
end

"""Open a new Julia session or resume a persisted session using the selected factory."""
function api_open_session!(api::SessionAPI, params::AbstractDict; resume=false)
    name = get(params, "session", string(uuid4()))
    name isa AbstractString && !isempty(name) || return RpcError(-32602, "Invalid session identifier")
    directory = get(params, "workingDirectory", pwd())
    directory isa AbstractString && isdir(directory) || return RpcError(-32602, "Invalid working directory")
    if !isnothing(api.store) && isnothing(session_file(api.store, name))
        return RpcError(-32602, "Invalid persisted session identifier")
    end
    return lock(api.lock) do
        api.closed && return RpcError(-32000, "Session API is closed")
        haskey(api.sessions, String(name)) && return RpcError(-32000, "Session is already open: $name")
        record = resume && !isnothing(api.store) ? saved_session_record(api.store, name) : nothing
        resume && isnothing(record) && return RpcError(-32004, "Session was not saved: $name")
        target = Base.invokelatest(api.factory)
        session = isnothing(record) ? api_create_session(target; working_directory=directory) :
            api_create_session(target; messages=record.messages, working_directory=record.directory,
                id=record.lineage.id, parent_id=record.lineage.parent_id, root_id=record.lineage.root_id)
        api.sessions[String(name)] = session
        return api_session_summary(name, session)
    end
end

function api_close_session!(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    session isa RpcError && return session
    name = String(params["session"])
    lock(api.lock) do
        pop!(api.sessions, name, nothing)
        pop!(api.handles, name, nothing)
    end
    close(session)
    return Dict("closed" => true)
end

function api_session_detail(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    return session isa RpcError ? session : api_session_summary(params["session"], session)
end

function api_session_messages(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    return session isa RpcError ? session :
        [api_message(message) for message in history_snapshot(session).messages]
end

"""Validate shared live/durable search predicates at the framework-neutral API boundary."""
function api_search_parameters(params::AbstractDict)
    text = api_parameter(params, "text")
    text isa AbstractString && !isempty(strip(text)) || return RpcError(-32602, "Search text is required")
    roles = get(params, "roles", nothing)
    (isnothing(roles) || (roles isa AbstractVector &&
        all(role -> role isa Union{Symbol,AbstractString}, roles))) ||
        return RpcError(-32602, "Search roles must be an array of strings")
    limit = get(params, "limit", typemax(Int))
    limit isa Integer && !(limit isa Bool) && limit >= 0 ||
        return RpcError(-32602, "Invalid search limit")
    return (text=String(text), roles, limit)
end

function api_session_search(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    session isa RpcError && return session
    selection = api_search_parameters(params)
    selection isa RpcError && return selection
    return [api_hit(hit) for hit in search_history(session, selection.text;
        roles=selection.roles, limit=selection.limit)]
end

"""Search persisted history without opening or executing sessions; query sources use Julia dispatch."""
function api_persisted_search(api::SessionAPI, params::AbstractDict)
    source = lock(api.lock) do
        api.closed && return RpcError(-32000, "Session API is closed")
        return isnothing(api.query) ? api.store : api.query
    end
    source isa RpcError && return source
    isnothing(source) && return RpcError(-32601, "No persistent session search service is configured")
    selection = api_search_parameters(params)
    selection isa RpcError && return selection
    return [api_hit(hit) for hit in search_history(source, selection.text;
        roles=selection.roles, limit=selection.limit)]
end

function api_session_workspace(api::SessionAPI, params::AbstractDict; change=false)
    session = api_session(api, params)
    session isa RpcError && return session
    if change
        path = api_parameter(params, "path")
        path isa AbstractString || return RpcError(-32602, "Expected a path")
        selected = set_working_directory!(session, path)
        selected.ok || return RpcError(-32602, selected.reason)
    end
    return Dict("workingDirectory" => working_directory(session))
end

function api_session_save(api::SessionAPI, params::AbstractDict)
    isnothing(api.store) && return RpcError(-32601, "No persistent session store is configured")
    session = api_session(api, params)
    session isa RpcError && return session
    saved = save_session!(api.store, params["session"], session)
    return saved.ok ? Dict("saved" => true) : RpcError(-32602, saved.reason)
end

function api_session_children(api::SessionAPI, params::AbstractDict)
    isnothing(api.store) && return RpcError(-32601, "No persistent session store is configured")
    session = api_session(api, params)
    session isa RpcError && return session
    return session_descendants(api.store, session)
end

function api_session_turn!(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    session isa RpcError && return session
    prompt = api_parameter(params, "prompt")
    prompt isa AbstractString && !isempty(prompt) || return RpcError(-32602, "Prompt is required")
    handle = submit_turn!(session, prompt)
    lock(api.lock) do
        api.handles[String(params["session"])] = handle
    end
    return Dict("accepted" => true)
end

function api_session_wait(api::SessionAPI, params::AbstractDict)
    session = api_session(api, params)
    session isa RpcError && return session
    handle = lock(() -> get(api.handles, String(params["session"]), nothing), api.lock)
    isnothing(handle) && return Dict("status" => "idle")
    result = fetch(handle)
    return Dict("status" => "completed", "ok" => result.ok, "text" => result.text)
end

"""Dispatch a Julia-native session API command, independently of protocol transports."""
function session_api_request!(api::SessionAPI, method::AbstractString, params::AbstractDict=Dict{String,Any}())
    method == "session/open" && return api_open_session!(api, params)
    method == "session/resume" && return api_open_session!(api, params; resume=true)
    method == "session/list" && return lock(() -> sort!(collect(keys(api.sessions))), api.lock)
    method == "session/describe" && return api_session_detail(api, params)
    method == "session/messages" && return api_session_messages(api, params)
    method == "session/search" && return api_session_search(api, params)
    method == "session/search/all" && return api_persisted_search(api, params)
    method == "session/workspace/get" && return api_session_workspace(api, params)
    method == "session/workspace/set" && return api_session_workspace(api, params; change=true)
    method == "session/save" && return api_session_save(api, params)
    method == "session/children" && return api_session_children(api, params)
    method == "session/turn" && return api_session_turn!(api, params)
    method == "session/wait" && return api_session_wait(api, params)
    method == "session/close" && return api_close_session!(api, params)
    return RpcError(-32601, "Unknown Julia session method: $method")
end

"""Bind the native API to caller-owned JSON-RPC byte streams without launching a DSH process."""
session_api_peer(api::SessionAPI, input, output) =
    JsonRpcPeer(input, output; on_request=(method, params) -> session_api_request!(api, method, params))

function Base.close(api::SessionAPI)
    sessions = lock(api.lock) do
        api.closed && return Session[]
        api.closed = true
        snapshot = collect(values(api.sessions))
        empty!(api.sessions)
        empty!(api.handles)
        return snapshot
    end
    for session in sessions
        close(session)
    end
    return nothing
end

"""Install the replaceable Julia session API service under a profile."""
function session_api_plugin(; name=:session_api, service_name=:session_api,
        store_service=nothing, query_service=nothing, factory=Kernel)
    contract = Symbol(service_name)
    dependencies = Symbol[]
    isnothing(store_service) || push!(dependencies, Symbol(store_service))
    isnothing(query_service) || push!(dependencies, Symbol(query_service))
    unique!(dependencies)
    setup = context -> begin
        store = isnothing(store_service) ? nothing : service(context, Symbol(store_service))
        query = isnothing(query_service) ? nothing : service(context, Symbol(query_service))
        provide!(context, contract, SessionAPI(; factory, store, query);
            requires=dependencies, cleanup=close)
    end
    return PluginSpec(name, setup; requires=dependencies, provides=[contract])
end
