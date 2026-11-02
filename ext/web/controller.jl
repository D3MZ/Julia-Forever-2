Base.@kwdef mutable struct WebTurn
    id::String = web_secret()
    handle::Union{Nothing,JuliaForever2.TaskHandle} = nothing
    text::String = ""
    kind::Symbol = :answer
    revision::Int = 0
    request::String = ""
    prompt_digest::Vector{UInt8} = UInt8[]
    persistence::Union{Nothing,Task} = nothing
end

Base.@kwdef mutable struct WebController{A}
    api::A
    workspace::String = pwd()
    access::Union{Nothing,WebAccess} = nothing
    lock::ReentrantLock = ReentrantLock()
    save_lock::ReentrantLock = ReentrantLock()
    turns::Dict{String,WebTurn} = Dict{String,WebTurn}()
    requests::Dict{Tuple{String,String},WebTurn} = Dict{Tuple{String,String},WebTurn}()
end
WebController(api; workspace=pwd(), access=nothing) = WebController(; api, workspace=realpath(workspace), access)

const BROWSER_SESSION_METHODS = Set(("session/list", "session/list/all", "session/list/saved",
    "session/messages", "session/describe", "session/title/get", "session/title/rename", "session/save",
    "session/markdown", "session/search", "session/archive", "session/unarchive", "session/list/pinned",
    "session/pin", "session/unpin"))

const LOCAL_WORKSPACE_METHODS = Set(("workspace/list", "workspace/create", "workspace/rename",
    "workspace/delete", "workspace/move", "workspace/session/move", "workspace/feed", "session/list/workspaces"))

web_local_workspaces(controller::WebController) = !isnothing(controller.api.workspaces) &&
    !isnothing(controller.access) && isempty(controller.access.origin) && !controller.access.browser_only

function browser_route(controller::WebController, request::HTTP.Request, path)
    if request.method == "POST" && path == "/api/rpc"
        if length(request.body) > 1_048_576
            response(413, "{\"error\":\"Payload too large\"}")
        else
            browser_dispatch(controller, JuliaForever2.parse_json(String(request.body)))
        end
    elseif request.method == "GET" && path in ("/", "/app.js", "/app.css")
        route(controller.api, request, path)
    else
        response(404, "{\"error\":\"Not found\"}")
    end
end

browser_dispatch(controller, frame) = response(400, "{\"error\":\"Invalid JSON-RPC request\"}")
function browser_dispatch(controller::WebController, frame::AbstractDict)
    method = get(frame, "method", nothing)
    params = get(frame, "params", Dict{String,Any}())
    if get(frame, "jsonrpc", nothing) != "2.0" || !(method isa AbstractString) || !(params isa AbstractDict)
        browser_dispatch(controller, nothing)
    else
        result = browser_command!(controller, method, params)
        response(200, JSON.json(envelope(get(frame, "id", nothing), result)))
    end
end

function browser_command!(controller::WebController, method::AbstractString, params::AbstractDict)
    if method == "session/list/all"
        browser_session_inventory(controller, params)
    elseif method == "session/save"
        save_browser_session!(controller, params)
    elseif method in BROWSER_SESSION_METHODS
        JuliaForever2.session_api_request!(controller.api, method, params)
    elseif method in LOCAL_WORKSPACE_METHODS && web_local_workspaces(controller)
        JuliaForever2.session_api_request!(controller.api, method, params)
    elseif method in ("session/open", "session/resume")
        # Public browser callers cannot select a host directory or inject factory settings; local registry controls retain their native scope.
        directory = web_local_workspaces(controller) ? get(params, "workingDirectory", controller.workspace) : controller.workspace
        selected = Dict{String,Any}("workingDirectory" => directory)
        if haskey(params, "session")
            selected["session"] = params["session"]
        end
        browser_open!(controller, method, selected)
    elseif method == "session/close"
        close_browser_session!(controller, params, controller.api.store)
    elseif method == "web/turn"
        admit_web_turn!(controller, params)
    elseif method == "web/status"
        web_turn_status(controller, params)
    elseif method == "web/cancel"
        cancel_web_turn!(controller, params)
    elseif method == "web/info"
        Dict("persistent" => !isnothing(controller.api.store), "titles" => !isnothing(controller.api.titles),
            "transport" => "Julia-native", "streaming" => "operation-scoped polling",
            "chatOnly" => controller.api.factory isa WebChatFactory, "workspaces" => web_local_workspaces(controller))
    else
        JuliaForever2.RpcError(-32601, "Method is not available to the browser")
    end
end

browser_saved_title(titles, store, name) = nothing
browser_saved_title(titles::JuliaForever2.SessionTitleService, store::JuliaForever2.SessionStore, name::AbstractString) =
    JuliaForever2.saved_session_title(titles, store, name)

function browser_session_inventory(controller::WebController, params::AbstractDict)
    rows = JuliaForever2.session_api_request!(controller.api, "session/list/all", params)
    if rows isa AbstractVector
        for row in rows
            if !get(row, "live", false)
                title = browser_saved_title(controller.api.titles, controller.api.store, row["session"])
                isnothing(title) || (row["title"] = title)
            end
        end
    end
    rows
end

function save_browser_session!(controller::WebController, params)
    lock(controller.save_lock) do
        JuliaForever2.session_api_request!(controller.api, "session/save", params)
    end
end

close_browser_session!(controller, params, ::Nothing) = JuliaForever2.session_api_request!(controller.api, "session/close", params)
function close_browser_session!(controller, params, store)
    lock(controller.save_lock) do
        saved = JuliaForever2.session_api_request!(controller.api, "session/save", params)
        saved isa JuliaForever2.RpcError ? saved : JuliaForever2.session_api_request!(controller.api, "session/close", params)
    end
end

function capture_web_progress!(controller::WebController, name::String, turn::WebTurn, event)
    if event isa JuliaForever2.HarnessEvent && event.kind == :response_progress
        progress = event.data.progress
        lock(controller.lock) do
            if get(controller.turns, name, nothing) === turn && !isnothing(turn.handle) &&
                    event.data.operation_id == JuliaForever2.operation_id(turn.handle.context)
                turn.text = first(progress.text, 200_000)
                turn.kind = progress.kind
                turn.revision += 1
            end
        end
    end
    nothing
end

function start_web_turn!(controller::WebController, params::AbstractDict)
    name = get(params, "session", nothing)
    prompt = get(params, "prompt", nothing)
    request = get(params, "request", web_secret())
    if !(request isa AbstractString && 16 <= ncodeunits(request) <= 128)
        JuliaForever2.RpcError(-32602, "Invalid submission identity")
    elseif !(name isa AbstractString && prompt isa AbstractString && !isempty(strip(prompt)) && ncodeunits(prompt) <= 262_144)
        JuliaForever2.RpcError(-32602, "A session and message up to 256 KiB are required")
    else
        lock(controller.lock) do
            lock(controller.api.lock) do
                session = get(controller.api.sessions, String(name), nothing)
                previous = get(controller.api.handles, String(name), nothing)
                previous_turn = get(controller.turns, String(name), nothing)
                replay = get(controller.requests, (String(name), String(request)), nothing)
                if !isnothing(replay)
                    web_equal(replay.prompt_digest, web_digest(prompt)) ?
                        Dict("accepted" => true, "turn" => replay.id) : JuliaForever2.RpcError(-32602, "Submission identity does not match its message")
                elseif controller.api.closed || isnothing(session) || String(name) in controller.api.closing
                    JuliaForever2.RpcError(-32004, "Session is not available")
                elseif !isnothing(previous) && !istaskdone(previous) ||
                        !isnothing(previous_turn) && !web_turn_settled(previous_turn)
                    JuliaForever2.RpcError(-32000, "This conversation already has an active reply")
                elseif length(controller.requests) >= 1024
                    JuliaForever2.RpcError(-32000, "This temporary workspace has reached its submission limit")
                else
                    turn = WebTurn(; request=String(request), prompt_digest=web_digest(prompt))
                    controller.requests[(String(name), String(request))] = turn
                    controller.turns[String(name)] = turn
                    context = JuliaForever2.ExecutionContext(; timeout=web_turn_timeout(controller.access),
                        event_sink=event -> capture_web_progress!(controller, String(name), turn, event))
                    turn.handle = JuliaForever2.submit_turn!(session, prompt; context)
                    controller.api.handles[String(name)] = turn.handle
                    if !isnothing(controller.api.store)
                        turn.persistence = Threads.@spawn persist_web_turn!(controller, String(name), session, turn.handle)
                    end
                    Dict("accepted" => true, "turn" => turn.id)
                end
            end
        end
    end
end

"""Save a settled turn independently of browser polling without replacing a different session."""
function persist_web_turn!(controller::WebController, name::String, session, handle)
    wait(handle; throw=false)
    api = controller.api
    lock(controller.save_lock) do
        lock(api.lock) do
            if api.closed || name in api.closing || get(api.sessions, name, nothing) !== session
                (ok=false, reason="Conversation closed before automatic save")
            else
                JuliaForever2.save_session!(api.store, name, session)
            end
        end
    end
end

web_turn_settled(turn::WebTurn) = !isnothing(turn.handle) && istaskdone(turn.handle) &&
    (isnothing(turn.persistence) || istaskdone(turn.persistence))

function web_save_error(turn::WebTurn)
    task = turn.persistence
    if isnothing(task)
        nothing
    elseif istaskfailed(task)
        "Automatic save failed. Save the conversation to retry."
    else
        fetch(task).ok ? nothing : "Automatic save failed. Save the conversation to retry."
    end
end

function web_turn_status(controller::WebController, params::AbstractDict)
    name = get(params, "session", nothing)
    lock(controller.lock) do
        turn = get(controller.turns, name, nothing)
        web_turn_status(turn)
    end
end
web_turn_status(::Nothing) = Dict("status" => "idle")
web_turn_result(handle) = istaskfailed(handle) ?
    JuliaForever2.ExecutionResult(false, "Reply failed unexpectedly. Edit and retry.") : fetch(handle)

function web_turn_status(turn::WebTurn)
    result = Dict{String,Any}("turn" => turn.id, "request" => turn.request, "text" => turn.text,
        "kind" => String(turn.kind), "revision" => turn.revision)
    if web_turn_settled(turn)
        final = web_turn_result(turn.handle)
        result["status"] = "completed"
        result["ok"] = final.ok
        result["result"] = final.text
        result["cancelled"] = JuliaForever2.cancelled(turn.handle.context)
        save_error = web_save_error(turn)
        isnothing(save_error) || (result["saveError"] = save_error)
    else
        result["status"] = "running"
        if !isnothing(turn.handle) && istaskdone(turn.handle)
            result["phase"] = "saving"
        end
    end
    result
end

"""Bind Stop to the exact submitted operation; a delayed request cannot cancel its successor."""
function cancel_web_turn!(controller::WebController, params::AbstractDict)
    lock(controller.lock) do
        turn = get(controller.turns, get(params, "session", nothing), nothing)
        if isnothing(turn) || get(params, "turn", nothing) != turn.id
            JuliaForever2.RpcError(-32009, "That reply is no longer current")
        else
            JuliaForever2.cancel_api_turn!(turn.handle)
        end
    end
end

function cancel_web_turns!(controller::WebController)
    lock(controller.lock) do
        for turn in values(controller.turns)
            JuliaForever2.cancel_api_turn!(turn.handle)
        end
    end
    nothing
end

"""Finish saves for turns that already settled before the server closes."""
function wait_settled_web_saves!(controller::WebController)
    tasks = lock(controller.lock) do
        [turn.persistence for turn in values(controller.turns) if !isnothing(turn.handle) &&
            istaskdone(turn.handle) && !isnothing(turn.persistence)]
    end
    foreach(task -> wait(task; throw=false), tasks)
    nothing
end

"""Keep resumed browser sessions within the same server-owned workspace."""
function browser_open!(controller::WebController, method, params)
    store = controller.api.store
    name = get(params, "session", nothing)
    record = method == "session/resume" && !isnothing(store) && name isa AbstractString ?
        JuliaForever2.saved_session_record(store, name) : nothing
    if name isa AbstractString && ncodeunits(name) > 160
        JuliaForever2.RpcError(-32602, "Conversation identifier is too long")
    elseif lock(() -> length(controller.api.sessions) >= 64, controller.api.lock)
        JuliaForever2.RpcError(-32000, "Close a conversation before opening another (64 active maximum)")
    elseif !web_local_workspaces(controller) && !isnothing(record) && abspath(record.directory) != controller.workspace
        JuliaForever2.RpcError(-32602, "Saved conversation is outside this browser workspace")
    else
        JuliaForever2.session_api_request!(controller.api, method, params)
    end
end

web_turn_timeout(::Nothing) = 900.0
web_turn_timeout(access::WebAccess) = max(0.0, min(900.0, access.expires_at - time(),
    (Float64(access.deadline) - Float64(time_ns())) / 1e9))

"""Recheck authorization atomically with task admission so revoke cannot miss a queued turn."""
admit_web_turn!(controller::WebController, params) = admit_web_turn!(controller, params, controller.access)
admit_web_turn!(controller::WebController, params, ::Nothing) = start_web_turn!(controller, params)
function admit_web_turn!(controller::WebController, params, access::WebAccess)
    lock(access.lock) do
        web_access_alive(access) ? start_web_turn!(controller, params) :
            JuliaForever2.RpcError(-32001, "Private browser access has expired or was revoked")
    end
end
