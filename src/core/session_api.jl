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

"""Construct a native session API; factories return a Kernel or AgentDefinition."""
SessionAPI(; factory=Kernel, store=nothing, query=nothing) = SessionAPI(factory, store, query, ReentrantLock(), Dict{String,Session}(), Dict{String,TaskHandle}(), false)

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
        api.closed ? RpcError(-32000, "Session API is closed") : get(api.sessions, String(name), RpcError(-32004, "Unknown session: $name"))
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
        elseif haskey(api.sessions, String(name))
            RpcError(-32000, "Session is already open: $name")
        else
            restore!(api, name, directory, resume)
        end
    end
end

function restore!(api::SessionAPI, name, directory, resume)
    record = resume && !isnothing(api.store) ? saved_session_record(api.store, name) : nothing
    if resume && isnothing(record)
        RpcError(-32004, "Session was not saved: $name")
    else
        session = restore(Base.invokelatest(api.factory), record, directory)
        api.sessions[String(name)] = session
        api_session_summary(name, session)
    end
end

restore(target::Union{Kernel,AgentDefinition}, ::Nothing, directory) = api_create_session(target; working_directory=directory)
restore(target::Union{Kernel,AgentDefinition}, record, directory) = api_create_session(target; messages=record.messages, working_directory=record.directory, id=record.lineage.id, parent_id=record.lineage.parent_id, root_id=record.lineage.root_id)
"""Close one session after committing its settled history when persistence is installed."""
function api_close_session!(api::SessionAPI, params::AbstractDict)
    apply(api_session(api, params)) do session
        name = String(params["session"])
        result = lock(api.lock) do
            if api.closed || get(api.sessions, name, nothing) !== session
                RpcError(-32000, "Session is not available: $name")
            else
                saved = persist_before_close!(api.store, name, session,
                    get(api.handles, name, nothing))
                if !saved.ok
                    RpcError(-32000, "Session could not be saved: $(saved.reason)")
                else
                    pop!(api.sessions, name)
                    pop!(api.handles, name, nothing)
                    Dict("closed" => true)
                end
            end
        end
        result isa RpcError || close(session)
        result
    end
end

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
        name = String(params["session"])
        if !(prompt isa AbstractString && !isempty(prompt))
            RpcError(-32602, "Prompt is required")
        else
            lock(api.lock) do
                previous = get(api.handles, name, nothing)
                if api.closed || get(api.sessions, name, nothing) !== session
                    RpcError(-32000, "Session is not available: $name")
                elseif !isnothing(previous) && !istaskdone(previous)
                    RpcError(-32000, "Session already has an active turn: $name")
                else
                    api.handles[name] = submit_turn!(session, prompt)
                    Dict("accepted" => true)
                end
            end
        end
    end
end

"""Cancel only the in-flight operation; preserve the Julia session and future turns."""
function api_session_cancel!(api::SessionAPI, params::AbstractDict)
    name = api_parameter(params, "session")
    if !(name isa AbstractString && !isempty(name))
        RpcError(-32602, "Expected a session identifier")
    else
        lock(api.lock) do
            if api.closed
                RpcError(-32000, "Session API is closed")
            elseif !haskey(api.sessions, String(name))
                Dict("cancelled" => false)
            else
                cancel_api_turn!(get(api.handles, String(name), nothing))
            end
        end
    end
end

cancel_api_turn!(::Nothing) = Dict("cancelled" => false)

function cancel_api_turn!(handle::TaskHandle)
    active = !istaskdone(handle) && !cancelled(handle.context)
    active && cancel!(handle)
    return Dict("cancelled" => active)
end
function api_session_wait(api::SessionAPI, params::AbstractDict)
    apply(api_session(api, params)) do session
        status(lock(() -> get(api.handles, String(params["session"]), nothing), api.lock))
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
    elseif haskey(api.sessions, destination)
        RpcError(-32000, "Session is already open: $destination")
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
        api_session_summary(destination, child)
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
    "session/describe" => api_session_detail,
    "session/messages" => api_session_messages,
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
            snapshot
        end
    end
    foreach(close, sessions)
    nothing
end
"""Install the replaceable Julia session API service under a profile."""
function session_api_plugin(; name=:session_api, service_name=:session_api, store_service=nothing, query_service=nothing, factory=Kernel)
    contract = Symbol(service_name)
    dependencies = unique(Symbol[Symbol(name) for name in (store_service, query_service) if !isnothing(name)])
    setup = context -> begin
        store = isnothing(store_service) ? nothing : service(context, Symbol(store_service))
        query = isnothing(query_service) ? nothing : service(context, Symbol(query_service))
        provide!(context, contract, SessionAPI(; factory, store, query); requires=dependencies, cleanup=close)
    end
    PluginSpec(name, setup; requires=dependencies, provides=[contract])
end
