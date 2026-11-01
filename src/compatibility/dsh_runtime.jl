using UUIDs: uuid4

const DSH_REFERENCE_COMMIT = "ce7073d51254c26cd63b22a60835b8f948deb447"
const DSH_REFERENCE_VERSION = "0.2.2-alpha.2"
const DSH_SHIPPED_PROFILES = ("web", "headless", "sdk", "sdk-minimal", "acp")

struct DSHProfile
    name::String
    command::Cmd
    patches::Vector{String}
    arguments::Vector{String}
    directory::String
    environment::Dict{String,String}
end

"""Describe an optional DSH composition, including third-party profiles, ordered overlays and app arguments."""
function DSHProfile(name::AbstractString="sdk"; command=`dsh`, patches=String[], arguments=String[],
        directory=pwd(), environment=Dict{String,String}(), home=nothing)
    values = Dict{String,String}(String(key) => String(value) for (key, value) in pairs(environment))
    isnothing(home) || (values["DSH_HOME"] = abspath(home))
    return DSHProfile(String(name), command, abspath.(String.(patches)), String.(arguments),
        abspath(directory), values)
end

"""Construct argv without a shell, preserving profile patch order and all application arguments."""
function dsh_command(profile::DSHProfile)
    overlays = String[]
    for patch in profile.patches
        append!(overlays, ["--patch", patch])
    end
    command = `$(profile.command) --profile $(profile.name) $overlays $(profile.arguments)`
    return addenv(Cmd(command; dir=profile.directory), profile.environment...)
end

mutable struct RuntimeSubscriptions
    lock::ReentrantLock
    listeners::Dict{UInt64,Any}
    next_id::UInt64
end

RuntimeSubscriptions() = RuntimeSubscriptions(ReentrantLock(), Dict{UInt64,Any}(), UInt64(0))

function dispatch_runtime_event!(subscriptions::RuntimeSubscriptions, method, params)
    listeners = lock(subscriptions.lock) do
        [last(pair) for pair in sort!(collect(subscriptions.listeners); by=first)]
    end
    for listener in listeners
        Base.invokelatest(listener, method, params)
    end
    return nothing
end

function subscribe_runtime!(listener, subscriptions::RuntimeSubscriptions)
    identity = lock(subscriptions.lock) do
        subscriptions.next_id += UInt64(1)
        subscriptions.listeners[subscriptions.next_id] = listener
        subscriptions.next_id
    end
    return ResourceRegistration(identity, identity -> lock(subscriptions.lock) do
        delete!(subscriptions.listeners, identity)
        nothing
    end)
end

struct DSHClient{R} <: AbstractRuntimeBackend
    backend::R
    subscriptions::RuntimeSubscriptions
    server_info::Any
end

runtime_request!(client::DSHClient, method, params=Dict{String,Any}(); kwargs...) =
    runtime_request!(client.backend, method, params; kwargs...)
runtime_notify!(client::DSHClient, method, params=nothing) = runtime_notify!(client.backend, method, params)
subscribe_runtime!(listener, client::DSHClient) = subscribe_runtime!(listener, client.subscriptions)
Base.isopen(client::DSHClient) = isopen(client.backend)

function dsh_host_handler(on_request, on_approval, on_question)
    return (method, params) -> begin
        if method == "approval/request" && !isnothing(on_approval)
            Base.invokelatest(on_approval, params)
        elseif method == "user-question/ask" && !isnothing(on_question)
            Base.invokelatest(on_question, params)
        elseif !isnothing(on_request)
            Base.invokelatest(on_request, method, params)
        else
            RpcError(-32601, "method not found: $method")
        end
    end
end

"""Start and initialize an SDK profile through a replaceable backend; approval callbacks are opt-in."""
function connect_dsh(profile::DSHProfile=DSHProfile(); initialize=Dict{String,Any}(),
        backend_factory=start_runtime, on_request=nothing, on_approval=nothing, on_question=nothing,
        on_notification=nothing, context=nothing, timeout=10.0, stderr=Base.stderr)
    subscriptions = RuntimeSubscriptions()
    isnothing(on_notification) || subscribe_runtime!(on_notification, subscriptions)
    observer = (method, params) -> dispatch_runtime_event!(subscriptions, method, params)
    handler = dsh_host_handler(on_request, on_approval, on_question)
    params = Dict{String,Any}(String(key) => value for (key, value) in pairs(initialize))
    get!(params, "cwd", profile.directory)
    if !isnothing(on_approval)
        params["approvalRequests"] = true
    end
    if !isnothing(on_question)
        capabilities = Dict{String,Any}(get(params, "capabilities", Dict{String,Any}()))
        capabilities["userQuestions"] = true
        params["capabilities"] = capabilities
    end
    started = Base.invokelatest(backend_factory, dsh_command(profile);
        on_request=handler, on_notification=observer, stderr)
    started.ok || return started
    backend = started.value
    handshake = Threads.@spawn runtime_request!(backend, "initialize", params; context, timeout)
    wait(handshake; throw=false)
    response = istaskfailed(handshake) ? RpcResult(RpcError(nothing,
        JSONRPCTransport.task_failure_message(handshake))) : fetch(handshake)
    if !response.ok
        close(backend)
        return response
    end
    info = response.value isa AbstractDict ? get(response.value, "serverInfo", nothing) : nothing
    if !(info isa AbstractDict) || get(info, "name", nothing) != "deepseek-harness-sdk-runtime"
        close(backend)
        return RpcResult(RpcError(nothing, "DSH initialize returned an invalid server identity"))
    end
    return RpcResult(DSHClient(backend, subscriptions, info))
end

"""Ask the SDK to shut down within a bound, then always stop and reap its owned backend."""
function Base.close(client::DSHClient)
    if isopen(client.backend)
        shutdown = Threads.@spawn runtime_request!(client.backend, "shutdown", Dict{String,Any}(); timeout=2.0)
        wait(shutdown; throw=false)
        if !istaskfailed(shutdown) && fetch(shutdown).ok
            finish_runtime!(client.backend; timeout=2.0)
        end
    end
    close(client.backend)
    lock(client.subscriptions.lock) do
        empty!(client.subscriptions.listeners)
    end
    return nothing
end

struct DSHSession{C}
    client::C
    id::String
end

DSHSession(client::DSHClient; id=string(uuid4())) = DSHSession(client, String(id))
dsh_content_blocks(text::AbstractString) = [Dict("type" => "text", "text" => String(text))]
dsh_content_blocks(blocks::AbstractVector) = blocks

"""Enqueue SDK input and return its durable receipt, without presenting it as a model answer."""
dsh_prompt!(session::DSHSession, input; kwargs...) = runtime_request!(session.client, "session/prompt",
    Dict("sessionId" => session.id, "contentBlocks" => dsh_content_blocks(input)); kwargs...)

"""Route SDK input through native prompt and slash-command handling."""
dsh_query!(session::DSHSession, input; kwargs...) = runtime_request!(session.client, "session/query",
    Dict("sessionId" => session.id, "contentBlocks" => dsh_content_blocks(input)); kwargs...)

"""Restore an exact persisted SDK session without adding input."""
dsh_resume!(session::DSHSession; kwargs...) = runtime_request!(session.client, "session/resume",
    Dict("sessionId" => session.id); kwargs...)

"""Wait for an SDK session and its managed descendants to settle."""
dsh_wait!(session::DSHSession; kwargs...) = runtime_request!(session.client, "session/wait",
    Dict("sessionId" => session.id); kwargs...)

"""Read the effective SDK session directory, including upstream missing-directory recovery."""
dsh_working_directory(session::DSHSession; kwargs...) = runtime_request!(session.client, "session/working-directory/get",
    Dict("sessionId" => session.id); kwargs...)

"""Change the SDK session directory through the selected runtime's validation and permissions."""
dsh_working_directory!(session::DSHSession, path::AbstractString; kwargs...) = runtime_request!(session.client,
    "session/working-directory/set", Dict("sessionId" => session.id, "path" => String(path)); kwargs...)

"""Extract the text blocks of the final assistant message from validated DSH session events."""
function dsh_final_response(events)
    for event in Iterators.reverse(events)
        if get(event, "type", nothing) == "assistant/message"
            return join(block["text"] for block in event["data"]["message"]["content"]
                if get(block, "type", nothing) == "text")
        end
    end
    return ""
end

"""Offer the generic JSON-RPC process transport as a replaceable native plugin service."""
runtime_transport_plugin(name=:jsonrpc_transport; service_name=:runtime_transport, factory=start_runtime) =
    PluginSpec(name, context -> provide!(context, service_name, factory); provides=[service_name])

"""Offer process lifetime management independently from any frontend or harness protocol."""
process_launcher_plugin(name=:process_launcher; service_name=:process_launcher, launcher=launch_feature) =
    PluginSpec(name, context -> provide!(context, service_name, launcher); provides=[service_name])

"""Mount an SDK client whose transport implementation is selected by the active native profile."""
function dsh_sdk_plugin(name=:dsh_sdk; profile=DSHProfile(), initialize=Dict{String,Any}(),
        transport_service=:runtime_transport, service_name=:dsh, kwargs...)
    setup = context -> begin
        selected_profile = get(context.config, :profile, profile)
        selected_initialize = get(context.config, :initialize, initialize)
        started = connect_dsh(selected_profile; initialize=selected_initialize,
            backend_factory=service(context, transport_service), kwargs...)
        started.ok || return (ok=false, reason=started.error.message)
        return provide!(context, service_name, started.value; cleanup=close)
    end
    return PluginSpec(name, setup; requires=[transport_service], provides=[service_name])
end

"""Mount an optional web, headless, ACP or third-party DSH frontend with owned process cleanup."""
function dsh_frontend_plugin(name=:dsh_web; profile=DSHProfile("web"; arguments=["--no-open"]),
        launcher_service=:process_launcher, service_name=:frontend, kwargs...)
    setup = context -> begin
        selected_profile = get(context.config, :profile, profile)
        started = Base.invokelatest(service(context, launcher_service), dsh_command(selected_profile); kwargs...)
        started.ok || return (ok=false, reason=started.error.message)
        return provide!(context, service_name, started.value; cleanup=close)
    end
    return PluginSpec(name, setup; requires=[launcher_service], provides=[service_name])
end
