module DSHDifferentialTests

using Test
using JSON
using Base64
using JuliaForever2

const DIFFERENTIAL_DIRECTORY = joinpath(@__DIR__, "differential")
include(joinpath(DIFFERENTIAL_DIRECTORY, "dsh_reference_profiles.jl"))
const CASES = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "cases.json"), String))
CASES["profile_groups"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "profile_groups.json"), String))
CASES["session_query"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "session_query.json"), String))
CASES["tool_arguments"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_arguments.json"), String))
CASES["tool_outputs"] = deepcopy(CASES["tool_arguments"])
CASES["tool_output_projection"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_output_projection.json"), String))
CASES["tool_activation"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_activation.json"), String))
CASES["tool_batch"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_batch.json"), String))
CASES["tool_cancellation"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_cancellation.json"), String))
CASES["tool_approval"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_approval.json"), String))
CASES["tool_completion"] = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "tool_completion.json"), String))
const COVERAGE = JSON.parse(read(joinpath(DIFFERENTIAL_DIRECTORY, "coverage.json"), String))

normalize(value) = JSON.parse(JSON.json(value))

function reference_results(kind, cases)
    executable = get(ENV, "DSH_NODE", "node")
    command = Cmd([executable, "--disable-warning=ExperimentalWarning", joinpath(DIFFERENTIAL_DIRECTORY, "oracle.mjs")])
    request = IOBuffer(JSON.json(Dict("kind" => kind, "cases" => cases)) * "\n")
    return JSON.parse(read(pipeline(command; stdin=request), String))
end

function patch_result(original)
    input = deepcopy(original)
    warnings = Any[]
    entries = JuliaForever2.apply_entry_patches(input["entries"], input["patches"];
        warn=(arguments...) -> push!(warnings, Any[arguments...]))
    return normalize(Dict("entries" => entries, "warnings" => warnings,
        "originalEntries" => input["entries"], "originalPatches" => input["patches"]))
end

function layer_result(original)
    input = deepcopy(original)
    warnings = String[]
    entries = JuliaForever2.compose_entry_layers(input["layers"]; warn=message -> push!(warnings, message))
    return normalize(Dict("entries" => entries, "warnings" => warnings, "originalLayers" => input["layers"]))
end

request_handler(::Val{:echo}) = (method, params) -> Dict("method" => method, "params" => params)
request_handler(::Val{:failure}) = (method, params) -> error("fixture failure")
request_handler(::Val{:none}) = nothing

function transport_result(input)
    output = IOBuffer()
    notifications = Any[]
    trace = Any[]
    handler = if input["handler"] == "echo"
        (method, params) -> begin
            push!(trace, Dict("type" => "request", "method" => method, "params" => params))
            Dict("method" => method, "params" => params)
        end
    else
        request_handler(Val(Symbol(input["handler"])))
    end
    observer = (method, params) -> begin
        push!(notifications, Dict("method" => method, "params" => params))
        push!(trace, Dict("type" => "notification", "method" => method, "params" => params))
    end
    peer = JuliaForever2.JsonRpcPeer(IOBuffer(), output; on_request=handler,
        on_notification=observer)
    for chunk in input["chunks"]
        JuliaForever2.feed!(peer, base64decode(chunk))
        JuliaForever2.drain!(peer)
    end
    JuliaForever2.drain!(peer)
    frames = [JSON.parse(line) for line in split(String(take!(output)), '\n') if !isempty(line)]
    close(peer)
    result = Dict("frames" => frames, "notifications" => notifications)
    get(input, "trace", false) && (result["trace"] = trace)
    return normalize(result)
end

function rpc_result(result)
    error = isnothing(result.error) ? nothing : Dict("code" => result.error.code,
        "message" => result.error.message, "data" => result.error.data)
    return Dict("ok" => result.ok, "value" => result.value, "error" => error)
end

function outgoing_result(input)
    output = IOBuffer()
    peer = JuliaForever2.JsonRpcPeer(IOBuffer(), output)
    pending = Threads.@spawn JuliaForever2.request!(peer, input["method"], input["params"]; timeout=10)
    ready = timedwait(() -> lock(() -> position(output) > 0, peer.write_lock), 5)
    if ready !== :ok
        close(peer)
        wait(pending)
        return Dict("request" => nothing, "result" => "outbound frame was not emitted")
    end
    frame = lock(peer.write_lock) do
        JSON.parse(String(take!(output)))
    end
    response = merge(Dict("jsonrpc" => "2.0", "id" => frame["id"]), input["response"])
    JuliaForever2.feed!(peer, JSON.json(response) * "\n")
    result = fetch(pending)
    frame["id"] = "<request-id>"
    close(peer)
    return normalize(Dict("request" => frame, "result" => rpc_result(result)))
end

mutable struct RecoveringWriter <: IO
    buffer::IOBuffer
    failures::Int
end

function Base.write(output::RecoveringWriter, value::String)
    if output.failures > 0
        output.failures -= 1
        error("fixture write failure")
    end
    return write(output.buffer, value)
end

Base.write(output::RecoveringWriter, value::Char) = write(output.buffer, value)
Base.flush(output::RecoveringWriter) = flush(output.buffer)

function recovery_result(input)
    output = RecoveringWriter(IOBuffer(), input["failures"])
    peer = JuliaForever2.JsonRpcPeer(IOBuffer(), output)
    failed = [rpc_result(JuliaForever2.request!(peer, "fixture/fail", Dict(); timeout=10)) for index in 1:input["failures"]]
    pending = Threads.@spawn JuliaForever2.request!(peer, "fixture/recover", Dict("value" => 42); timeout=10)
    ready = timedwait(() -> lock(() -> position(output.buffer) > 0, peer.write_lock), 5)
    if ready !== :ok
        close(peer)
        wait(pending)
        return Dict("failed" => failed, "request" => nothing, "result" => "outbound frame was not emitted")
    end
    frame = lock(peer.write_lock) do
        JSON.parse(String(take!(output.buffer)))
    end
    JuliaForever2.feed!(peer, JSON.json(Dict("jsonrpc" => "2.0", "id" => frame["id"], "result" => input["result"])) * "\n")
    result = fetch(pending)
    frame["id"] = "<request-id>"
    close(peer)
    return normalize(Dict("failed" => failed, "request" => frame, "result" => rpc_result(result)))
end

function callback_close_result(input)
    runtime = Ref{Any}(nothing)
    followup = Ref{Any}(nothing)
    notifications = Any[]
    returned = Threads.Atomic{Bool}(false)
    observer = (method, params) -> begin
        push!(notifications, Dict("method" => method, "params" => params))
        if haskey(input, "followup")
            request = input["followup"]
            followup[] = JuliaForever2.runtime_request!(runtime[], request["method"], request["params"]; timeout=5)
        end
        close(runtime[])
        returned[] = true
        return nothing
    end
    command = Cmd([get(ENV, "DSH_NODE", "node"), "--disable-warning=ExperimentalWarning",
        joinpath(DIFFERENTIAL_DIRECTORY, "transport-close-peer.mjs")])
    started = JuliaForever2.start_runtime(command; on_notification=observer)
    started.ok || error("Native transport process could not start: $(started.error.message)")
    runtime[] = started.value
    result = JuliaForever2.runtime_request!(runtime[], input["method"], input["params"]; timeout=10)
    completed = timedwait(() -> returned[], 10) === :ok
    if completed
        close(runtime[])
    else
        # Bound a regressed callback/reader cycle without waiting on its blocked supervisor.
        close(runtime[].peer)
        JuliaForever2.stop_process!(runtime[].process)
        close(runtime[].process.in)
        close(runtime[].process.out)
    end
    observed = Dict("notifications" => notifications, "callbackReturned" => completed,
        "processExited" => !process_running(runtime[].process), "result" => rpc_result(result))
    haskey(input, "followup") && (observed["followup"] = rpc_result(followup[]))
    return normalize(observed)
end

function asynchronous_fixture(callback, arguments...)
    return @async begin
        yield()
        Base.invokelatest(callback, arguments...)
    end
end

function lifecycle_result(input)
    get(input, "ownership", false) && return ownership_result(input)
    trace = Any[]
    registry = JuliaForever2.PluginRegistry()
    for specification in input["plugins"]
        dependencies = get(specification, "requires", String[])
        provided = get(specification, "provides", Dict{String,Any}())
        initialize = context -> begin
            values = Dict(name => JuliaForever2.service(context, Symbol(name)) for name in dependencies)
            push!(trace, Dict("action" => "activate", "plugin" => specification["name"], "dependencies" => values))
            for (name, value) in provided
                JuliaForever2.provide!(context, Symbol(name), value)
            end
            for label in get(specification, "effects", String[])
                dispose = () -> begin
                    push!(trace, Dict("action" => "dispose", "plugin" => specification["name"], "effect" => label))
                end
                cleanup = get(specification, "async_cleanup", false) ? () -> asynchronous_fixture(dispose) : dispose
                JuliaForever2.effect!(cleanup, context)
            end
            return nothing
        end
        setup = get(specification, "async_setup", false) ? context -> asynchronous_fixture(initialize, context) : initialize
        plugin = JuliaForever2.PluginSpec(Symbol(specification["name"]), setup;
            provides=Symbol.(collect(keys(provided))), requires=Symbol.(dependencies))
        JuliaForever2.register_plugin!(registry, plugin)
    end
    base = Kernel()
    host = JuliaForever2.PluginHost(base, registry)
    names = [Symbol(specification["name"]) for specification in input["plugins"]]
    JuliaForever2.activate!(host, JuliaForever2.Profile(:differential, names))
    services = Dict(name => component(host, Symbol(name)) for name in input["services"])
    close(host)
    close(base)
    return normalize(Dict("trace" => trace, "services" => services))
end

function ownership_fixture(mode)
    if mode == "scope"
        scope = JuliaForever2.ExtensionScope()
        return (owner=scope, finish=() -> close(scope))
    end
    reference = Ref{Any}(nothing)
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, JuliaForever2.PluginSpec(:owner, context -> begin
        reference[] = context
        nothing
    end))
    kernel = Kernel()
    host = JuliaForever2.PluginHost(kernel, registry)
    JuliaForever2.activate!(host, JuliaForever2.Profile(:ownership, [:owner]))
    finish = () -> begin
        close(host)
        close(kernel)
    end
    return (owner=reference[], finish)
end

function ownership_result(input)
    results = Any[]
    for mode in input["owners"]
        fixture = ownership_fixture(mode)
        registrations = Dict{String,Any}()
        trace = Any[]
        counts = Int[]
        for operation in input["operations"]
            if operation["type"] == "register"
                registrations[operation["id"]] = JuliaForever2.own_resource!(fixture.owner, operation["id"];
                    cleanup=value -> push!(trace, value))
            elseif operation["type"] == "release"
                release!(registrations[operation["id"]])
            elseif operation["type"] == "close"
                fixture.finish()
            elseif operation["type"] == "snapshot"
                push!(counts, lock(() -> length(fixture.owner.resources), fixture.owner.lock))
            end
        end
        fixture.finish()
        push!(results, Dict("owner" => mode, "counts" => counts, "trace" => trace))
    end
    return normalize(results)
end

function replacement_specification(specification, trace)
    setup = context -> begin
        push!(trace, Dict("action" => "activate", "generation" => specification["generation"]))
        for (name, value) in specification["provides"]
            JuliaForever2.provide!(context, Symbol(name), value)
        end
        for label in get(specification, "effects", [])
            JuliaForever2.effect!(context) do
                push!(trace, Dict("action" => "dispose", "generation" => specification["generation"], "effect" => label))
            end
        end
        if get(specification, "fail", false)
            error("fixture setup failure")
        end
        return nothing
    end
    return JuliaForever2.PluginSpec(Symbol(specification["name"]), setup;
        provides=Symbol.(collect(keys(specification["provides"]))), requires=Symbol.(get(specification, "requires", [])))
end

function replacement_result(input)
    input["kind"] == "retained" && return retained_replacement_result(input)
    input["kind"] == "async_binding" && return retained_async_binding_result(input)
    trace = Any[]
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, replacement_specification(input["initial"], trace))
    kernel = Kernel()
    host = JuliaForever2.PluginHost(kernel, registry)
    initial_name = Symbol(input["initial"]["name"])
    replacement_name = Symbol(input["replacement"]["name"])
    if input["kind"] == "service"
        JuliaForever2.register_plugin!(registry, replacement_specification(input["replacement"], trace))
        JuliaForever2.activate!(host, JuliaForever2.Profile(:differential, [initial_name, replacement_name];
            bindings=Dict(Symbol(input["service"]) => replacement_name)))
        services = Dict(name => component(host, Symbol(name)) for name in input["services"])
        close(host)
        close(kernel)
        return normalize(Dict("services" => services, "trace" => trace))
    end
    profile = JuliaForever2.Profile(:differential, [initial_name])
    JuliaForever2.activate!(host, profile)
    before = Dict(name => component(host, Symbol(name)) for name in input["services"])
    JuliaForever2.register_plugin!(registry, replacement_specification(input["replacement"], trace); replace=true)
    accepted = JuliaForever2.activate!(host, profile).ok
    after = Dict(name => component(host, Symbol(name)) for name in input["services"])
    close(host)
    close(kernel)
    return normalize(Dict("accepted" => accepted, "before" => before, "after" => after, "trace" => trace))
end

function retained_async_binding_result(input)
    trace = Any[]
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, replacement_specification(input["initial"], trace))
    kernel = Kernel()
    host = JuliaForever2.PluginHost(kernel, registry)
    profile = JuliaForever2.Profile(:retained_async, [Symbol(input["initial"]["name"])])
    JuliaForever2.activate!(host, profile)
    entered = Channel{Nothing}(1)
    continuation = Channel{Nothing}(1)
    pending = Threads.@spawn JuliaForever2.with_component(host, Symbol(input["service"])) do value
        @async begin
            push!(trace, Dict("action" => "enter", "value" => value))
            put!(entered, nothing)
            take!(continuation)
            push!(trace, Dict("action" => "use", "value" => value))
            value
        end
    end
    ready = timedwait(() -> isready(entered), 10)
    if ready !== :ok
        put!(continuation, nothing)
        close(host)
        close(kernel)
        error("Retained asynchronous component callback did not start")
    end
    JuliaForever2.register_plugin!(registry, replacement_specification(input["replacement"], trace); replace=true)
    JuliaForever2.activate!(host, profile)
    put!(continuation, nothing)
    timedwait(() -> istaskdone(pending), 10) === :ok || error("Retained asynchronous component callback did not finish")
    value = fetch(pending)
    if value isa Task
        timedwait(() -> istaskdone(value), 10) === :ok || error("Returned asynchronous component callback did not finish")
        value = fetch(value)
    end
    current = component(host, Symbol(input["service"]))
    close(host)
    close(kernel)
    return normalize(Dict("value" => value, "current" => current, "trace" => trace))
end

function retained_replacement_specification(specification, trace)
    setup = context -> begin
        push!(trace, Dict("action" => "activate", "generation" => specification["generation"]))
        scope = JuliaForever2.ExtensionScope()
        JuliaForever2.provide!(context, :scope, scope; cleanup=close)
        JuliaForever2.on!(scope, :fixture; owner=context) do value
            push!(trace, Dict("action" => "event", "generation" => specification["generation"], "value" => value))
        end
        tool = JuliaForever2.ToolSpec(:version, Dict("type" => "object"), arguments -> begin
            push!(trace, Dict("action" => "tool", "generation" => specification["generation"], "arguments" => arguments))
            return specification["value"]
        end)
        JuliaForever2.register_tool!(scope, tool; owner=context)
        JuliaForever2.effect!(context) do
            push!(trace, Dict("action" => "dispose", "generation" => specification["generation"]))
        end
        return nothing
    end
    return JuliaForever2.PluginSpec(Symbol(specification["name"]), setup; provides=[:scope])
end

function retained_replacement_result(input)
    trace = Any[]
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, retained_replacement_specification(input["initial"], trace))
    kernel = Kernel()
    host = JuliaForever2.PluginHost(kernel, registry)
    profile = JuliaForever2.Profile(:retained, [Symbol(input["initial"]["name"])])
    JuliaForever2.activate!(host, profile)
    retained_scope = component(host, :scope)
    retained_session = Session(host; executor=JuliaForever2.ToolExecutor(retained_scope))
    JuliaForever2.register_plugin!(registry, retained_replacement_specification(input["replacement"], trace); replace=true)
    JuliaForever2.activate!(host, profile)
    old_result = evaluate!(retained_session, JuliaForever2.ToolCall(:version, input["arguments"]))
    JuliaForever2.emit!(ExecutionContext(event_scope=retained_scope), HarnessEvent(:fixture, input["event"]))
    current_result = JuliaForever2.with_component(host, :scope) do scope
        result = JuliaForever2.invoke_tool!(scope, :version, input["arguments"])
        JuliaForever2.emit!(ExecutionContext(event_scope=scope), HarnessEvent(:fixture, input["event"]))
        return result
    end
    close(retained_session)
    released_result = JuliaForever2.invoke_tool!(retained_scope, :version, input["arguments"])
    JuliaForever2.emit!(ExecutionContext(event_scope=retained_scope), HarnessEvent(:fixture, input["event"]))
    close(host)
    close(kernel)
    project(result) = Dict("ok" => result.ok, "value" => result.value)
    return normalize(Dict("old" => project(old_result), "current" => project(current_result),
        "afterRelease" => project(released_result), "trace" => trace))
end

function event_result(input)
    get(input, "retained_waterfall", false) && return retained_waterfall_result(input)
    root = JuliaForever2.ExtensionScope()
    scopes = Dict("root" => root)
    for specification in get(input, "scopes", [])
        scopes[specification["name"]] = JuliaForever2.ExtensionScope(scopes[get(specification, "parent", "root")])
    end
    trace = Any[]
    listeners = Dict{String,Any}()
    for specification in input["listeners"]
        callback = (arguments...) -> begin
            values = Any[arguments...]
            next = get(specification, "waterfall", false) ? pop!(values) : nothing
            push!(trace, Dict("listener" => specification["id"], "arguments" => values))
            if get(specification, "waterfall", false) && !get(specification, "veto", false)
                result = next()
                return haskey(specification, "suffix") ? result * specification["suffix"] : result
            end
            return get(specification, "result", nothing)
        end
        scope = scopes[get(specification, "scope", "root")]
        listeners[specification["id"]] = JuliaForever2.on!(callback, scope, Symbol(get(specification, "event", "fixture"));
            prepend=get(specification, "prepend", false), global_listener=get(specification, "global", false),
            once=get(specification, "once", false))
    end
    results = Any[]
    for operation in input["operations"]
        if operation["type"] == "dispose"
            release!(listeners[operation["listener"]])
        elseif operation["type"] == "close"
            close(scopes[operation["scope"]])
        else
            scope = scopes[get(operation, "scope", "root")]
            arguments = Any[get(operation, "arguments", [])...]
            if operation["mode"] == "waterfall"
                push!(arguments, () -> begin
                    push!(trace, Dict("listener" => "<inner>", "arguments" => Any[]))
                    get(operation, "inner", "inner")
                end)
            end
            name = Symbol(get(operation, "event", "fixture"))
            if get(operation, "execution_context", false)
                context = ExecutionContext(; event_scope=scope)
                JuliaForever2.emit!(context, HarnessEvent(name, only(arguments)))
                push!(results, nothing)
            else
                push!(results, JuliaForever2.dispatch_event!(scope, name, arguments...; mode=Symbol(operation["mode"])))
            end
        end
    end
    close(root)
    return normalize(Dict("trace" => trace, "results" => results))
end

function retained_waterfall_result(input)
    scope = JuliaForever2.ExtensionScope()
    trace = Any[]
    alive = Threads.Atomic{Bool}(true)
    disposed = Threads.Atomic{Bool}(false)
    JuliaForever2.own_resource!(scope, nothing; cleanup=value -> begin
        alive[] = false
        push!(trace, Dict("action" => "dispose"))
        disposed[] = true
    end)
    gate = Channel{Nothing}(1)
    downstream = Ref{Any}(nothing)
    JuliaForever2.on!(scope, :fixture) do next
        push!(trace, Dict("action" => "outer-enter"))
        next()
        result = @async input["outer"]
        wait(result)
        return result
    end
    JuliaForever2.on!(scope, :fixture) do next
        push!(trace, Dict("action" => "downstream-start"))
        downstream[] = @async begin
            take!(gate)
            push!(trace, Dict("action" => "downstream-use", "alive" => alive[]))
            next()
        end
        return downstream[]
    end
    inner = () -> begin
        push!(trace, Dict("action" => "builtin", "alive" => alive[]))
        input["inner"]
    end
    pending = JuliaForever2.dispatch_event!(scope, :fixture, inner; mode=:waterfall)
    timedwait(() -> istaskdone(pending), 10) === :ok || error("Outer waterfall task did not finish")
    result = fetch(pending)
    push!(trace, Dict("action" => "outer-result", "value" => result))
    close(scope)
    push!(trace, Dict("action" => "after-retire", "alive" => alive[]))
    put!(gate, nothing)
    timedwait(() -> istaskdone(downstream[]), 10) === :ok || error("Downstream waterfall task did not finish")
    inner_result = fetch(downstream[])
    timedwait(() -> disposed[], 10) === :ok || error("Retained waterfall resources were not released")
    return normalize(Dict("result" => result, "inner" => inner_result, "trace" => trace))
end

function tool_result(input)
    root = JuliaForever2.ExtensionScope()
    scopes = Dict("root" => root)
    for specification in get(input, "scopes", [])
        scopes[specification["name"]] = JuliaForever2.ExtensionScope(scopes[get(specification, "parent", "root")])
    end
    registrations = Dict{String,Any}()
    results = Any[]
    executions = String[]
    guard_calls = String[]
    for operation in input["operations"]
        scope = scopes[get(operation, "scope", "root")]
        if operation["type"] == "register"
            specification = JuliaForever2.ToolSpec(Symbol(operation["name"]), get(operation, "schema", Dict("type" => "object")),
                arguments -> begin
                    push!(executions, operation["name"])
                    get(operation, "value", nothing)
                end; description=get(operation, "description", ""))
            registered = JuliaForever2.register_tool!(scope, specification)
            registered.ok && (registrations[operation["id"]] = registered.registration)
            push!(results, Dict("accepted" => registered.ok))
        elseif operation["type"] == "guard"
            registered = JuliaForever2.register_tool_guard!(scope, call -> begin
                push!(guard_calls, operation["id"])
                String(call.name) in operation["names"] ? operation["reason"] : nothing
            end)
            registered.ok && (registrations[operation["id"]] = registered.registration)
            push!(results, Dict("accepted" => registered.ok))
        elseif operation["type"] == "restrict"
            filter = operation["filter"]
            restricted = JuliaForever2.restrict_tools!(scope;
                allow=get(filter, "allow", nothing), deny=get(filter, "deny", nothing))
            restricted.ok && (registrations[operation["id"]] = restricted.registration)
            push!(results, Dict("accepted" => restricted.ok))
        elseif operation["type"] == "dispose"
            release!(registrations[operation["id"]])
        elseif operation["type"] == "close"
            close(scope)
        elseif operation["type"] == "snapshot"
            push!(results, [Dict("name" => String(tool.name), "schema" => tool.schema, "description" => tool.description)
                for tool in JuliaForever2.tools_snapshot(scope)])
        elseif operation["type"] == "invoke"
            name = Symbol(operation["name"])
            arguments = get(operation, "arguments", Dict())
            result = if get(operation, "session", false)
                kernel = Kernel()
                session = Session(kernel; executor=JuliaForever2.ToolExecutor(scope))
                outcome = evaluate!(session, JuliaForever2.ToolCall(name, arguments))
                close(session)
                close(kernel)
                outcome
            else
                JuliaForever2.invoke_tool!(scope, name, arguments)
            end
            push!(results, Dict("ok" => result.ok, "value" => result.value))
        elseif operation["type"] == "invoke_guarded"
            result = JuliaForever2.invoke_tool!(scope, Symbol(operation["name"]), get(operation, "arguments", Dict()))
            push!(results, Dict("ok" => result.ok, "value" => result.value,
                "reason" => result.ok ? nothing : result.text))
        elseif operation["type"] == "trace"
            push!(results, Dict("executions" => copy(executions), "guards" => copy(guard_calls)))
        end
    end
    close(root)
    return normalize(results)
end

function profile_group_result(input)
    original = deepcopy(input["profiles"])
    layers = [JuliaForever2.Profile(:layer, Symbol.(layer["plugins"]);
        config=get(layer, "config", Dict())) for layer in input["profiles"]]
    if !get(input, "stored", false)
        profile = JuliaForever2.compose_profiles(:composed, layers...)
        return normalize(Dict("plugins" => String.(profile.plugins),
            "config" => Dict(String(plugin) => value for (plugin, value) in profile.config),
            "originalProfiles" => original))
    end
    return mktempdir() do directory
        store = JuliaForever2.ProfileStore(directory)
        for (index, layer) in enumerate(layers)
            named = JuliaForever2.Profile(Symbol("layer_$index"), layer.plugins;
                config=layer.config, bindings=layer.bindings)
            saved = JuliaForever2.save_profile!(store, named)
            saved.ok || error(saved.reason)
        end
        restored = [JuliaForever2.load_profile(store, Symbol("layer_$index")) for index in eachindex(layers)]
        identity = Symbol(get(input, "storage_name", "composed"))
        composed = JuliaForever2.compose_profiles(identity, restored...)
        saved = JuliaForever2.save_profile!(store, composed)
        saved.ok || error(saved.reason)
        identity in JuliaForever2.profile_names(store) || error("Named profile was not discoverable")
        observed = Dict{String,Any}()
        registry = JuliaForever2.PluginRegistry()
        for plugin in composed.plugins
            setup = let plugin = plugin
                context -> begin
                    haskey(composed.config, plugin) && (observed[String(plugin)] = context.config)
                    nothing
                end
            end
            JuliaForever2.register_plugin!(registry, JuliaForever2.PluginSpec(plugin, setup))
        end
        kernel = Kernel()
        host = JuliaForever2.PluginHost(kernel; registry)
        activated = JuliaForever2.activate!(host, store, identity)
        activated.ok || error(activated.reason)
        snapshot = JuliaForever2.plugin_snapshot(host)
        output = Dict("plugins" => String.(snapshot.active), "config" => observed,
            "originalProfiles" => original)
        close(host)
        close(kernel)
        return normalize(output)
    end
end

final_response_result(input) = dsh_final_response(input["events"])

function launch_result(input)
    options = input["options"]
    environment = get(options, "env", Dict{String,Any}())
    profile = DSHProfile(get(options, "profile", "sdk");
        command=Cmd(["<node>", abspath(options["dshBin"])]), patches=get(options, "patches", String[]),
        directory=get(options, "processCwd", pwd()), environment, home=get(options, "dshHome", nothing))
    command = dsh_command(profile)
    selected = Dict{String,String}()
    for (name, value) in environment
        selected[name] = value
    end
    haskey(options, "dshHome") && (selected["DSH_HOME"] = abspath(options["dshHome"]))
    # Only caller-selected variables are compared; inherited process environments differ by API.
    actual = Dict{String,String}()
    for value in something(command.env, String[])
        pair = split(value, '='; limit=2)
        if first(pair) in keys(selected)
            actual[first(pair)] = last(pair)
        end
    end
    return normalize(Dict("arguments" => collect(command), "directory" => command.dir, "environment" => actual))
end


function tool_arguments_result(input)
    schema = JuliaForever2.CheckedJSONSchema(input["schema"])
    called = Ref(0)
    scope = JuliaForever2.ExtensionScope()
    specification = JuliaForever2.ToolSpec(:checked_arguments, schema, arguments -> begin
        called[] += 1
        return "accepted"
    end)
    registration = JuliaForever2.register_tool!(scope, specification)
    registration.ok || error(registration.reason)
    exposed = only(JuliaForever2.tools_snapshot(scope)).schema
    actual = JuliaForever2.invoke_tool!(scope, :checked_arguments, input["value"])
    violations = sort!(JuliaForever2.tool_argument_violations(schema, input["value"]))
    close(scope)
    expected_calls = isempty(violations) ? 1 : 0
    called[] == expected_calls || error("Tool callback bypassed checked argument admission")
    actual.ok == isempty(violations) || error("Tool result disagreed with checked argument admission")
    return normalize(Dict("violations" => violations, "accepted" => actual.ok, "schema" => exposed))
end

function tool_outputs_result(input)
    schema = JuliaForever2.CheckedJSONSchema(input["schema"])
    called = Ref(0)
    scope = JuliaForever2.ExtensionScope()
    specification = JuliaForever2.ToolSpec(:checked_output, Dict("type" => "object"), arguments -> begin
        called[] += 1
        input["value"]
    end; output_schema=schema)
    registration = JuliaForever2.register_tool!(scope, specification)
    registration.ok || error(registration.reason)
    exposed = only(JuliaForever2.tools_snapshot(scope)).schema
    exposed == Dict("type" => "object") || error("Output policy leaked into the model argument schema")
    actual = JuliaForever2.invoke_tool!(scope, :checked_output, Dict{String,Any}())
    violations = sort!(JuliaForever2.tool_output_violations(schema, input["value"]))
    close(scope)
    called[] == 1 || error("Checked output prevented tool execution")
    actual.ok == isempty(violations) || error("Tool result disagreed with checked output admission")
    if actual.ok
        actual.value == input["value"] || error("Checked output changed a valid result")
    else
        isnothing(actual.value) || error("Invalid tool output escaped in the result value")
        startswith(actual.text, "Invalid tool result: ") || error("Invalid output was not diagnosed")
    end
    return normalize(Dict("violations" => violations, "accepted" => actual.ok,
        "schema" => JuliaForever2.tool_schema_definition(schema)))
end

"""Use Julia tool output renderers without converting canonical values to display text."""
function tool_output_projection_result(input)
    scope = JuliaForever2.ExtensionScope()
    invoked = Ref(0)
    rendered = Ref(0)
    function renderer(arguments, value)
        rendered[] += 1
        format = input["format"]
        format == "label" && return string(get(arguments, "prefix", ""), value["label"])
        format == "joined" && return join(value["lines"], "|")
        format == "summary" && return string(value["label"], " (", value["count"], ")")
        format == "silent" && return ""
        format == "scalar" && return string(value)
        error("Unknown fixture presentation")
    end
    specification = JuliaForever2.ToolSpec(:projection, Dict("type" => "object"),
        arguments -> begin
            invoked[] += 1
            return deepcopy(input["value"])
        end; output_schema=JuliaForever2.CheckedJSONSchema(input["schema"]), render_output=renderer)
    registration = JuliaForever2.register_tool!(scope, specification)
    registration.ok || error(registration.reason)
    result = JuliaForever2.invoke_tool!(scope, :projection, input["arguments"])
    result.ok || isnothing(result.value) || error("Tool failure exposed the canonical value")
    close(scope)
    return normalize(Dict("accepted" => result.ok, "invoked" => invoked[],
        "rendered" => rendered[], "display" => result.ok ? result.text : nothing,
        "value" => result.ok ? result.value : nothing))
end

"""Produce an independently authored model-facing representation for completion fixtures."""
function completion_display(input, value)
    format = get(input, "format", "scalar")
    format == "label" && return string(get(input, "prefix", ""), value["label"])
    format == "joined" && return join(value["lines"], "|")
    return string(value)
end

"""Compare post-execute decisions and replacement validation with the pinned DSH stage."""
function tool_completion_result(input)
    root = JuliaForever2.ExtensionScope()
    scope = JuliaForever2.ExtensionScope(root)
    invoked = Ref(0)
    rendered = Ref(0)
    initial = get(input, "initial", "success")
    policy = get(input, "policy", "none")
    initial_value = get(input, "initial_value", "done")
    schema = policy == "value" ? JuliaForever2.CheckedJSONSchema(input["schema"]) : nothing
    renderer = policy == "value" ? ((arguments, value) -> begin
        rendered[] += 1
        completion_display(input, value)
    end) : nothing
    specification = JuliaForever2.ToolSpec(:fixture, Dict("type" => "object"), arguments -> begin
        invoked[] += 1
        return initial == "failed" ? ExecutionResult(false, "denied") : deepcopy(initial_value)
    end; output_schema=schema, render_output=renderer)
    installed = JuliaForever2.register_tool!(root, specification)
    installed.ok || error(installed.reason)
    if initial == "guard"
        guarded = JuliaForever2.register_tool_guard!(root, call -> "denied")
        guarded.ok || error(guarded.reason)
    end
    if policy != "none"
        JuliaForever2.on!(scope, :tool_completion) do call, result
            policy == "block" && return JuliaForever2.ToolResultBlock(input["message"])
            policy == "replace" && return JuliaForever2.ToolResultText(input["message"])
            policy == "value" && return JuliaForever2.ToolResultValue(deepcopy(input["value"]))
            return nothing
        end
    end
    result = JuliaForever2.invoke_tool!(scope, :fixture, Dict{String,Any}())
    close(scope)
    close(root)
    observed = Dict("ok" => result.ok, "text" => result.text,
        "retained" => result.ok ? result.value : nothing, "called" => invoked[] > 0)
    if policy == "value"
        observed["text"] = result.ok ? result.text : "completion rejected"
        observed["replacementRenders"] = rendered[] - Int(initial == "success")
    end
    return normalize(observed)
end

"""Compare Julia-owned approval routing against the original pinned upstream approval service outcomes."""
function tool_approval_result(input)
    root = JuliaForever2.ExtensionScope()
    scope = JuliaForever2.ExtensionScope(root)
    executed = Ref(0)
    approvals = Ref(0)
    observed = Ref{Any}(nothing)
    registered = JuliaForever2.register_tool!(root,
        JuliaForever2.ToolSpec(:fixture, Dict("type" => "object"), arguments -> begin
            executed[] += 1
            return "done"
        end))
    registered.ok || error(registered.reason)
    guarded = JuliaForever2.register_tool_guard!(root,
        call -> JuliaForever2.ToolApprovalRequest(get(input, "reason", nothing)))
    guarded.ok || error(guarded.reason)
    registration = if get(input, "channel", "present") == "missing"
        nothing
    else
        JuliaForever2.on!((call, request) -> begin
            approvals[] += 1
            selected = approvals[] == 1 ? input["outcome"] :
                get(input, "next_outcome", input["outcome"])
            outcome = selected == "allowed-once" ? :allowed_once : Symbol(selected)
            observed[] = outcome
            get(input, "async", false) ? (@async begin
                yield()
                outcome
            end) : outcome
        end, scope, :tool_approval)
    end
    function observe()
        observed[] = nothing
        result = JuliaForever2.invoke_tool!(scope, :fixture, Dict{String,Any}())
        isnothing(result.value) || result.ok || error("Denied approval exposed a tool value")
        return Dict("allowed" => result.ok, "reason" => result.ok ? nothing : result.text,
            "approvalCancelled" => observed[] === :cancelled)
    end
    first = observe()
    repeated = get(input, "withdraw", false) || haskey(input, "next_outcome")
    if get(input, "withdraw", false)
        isnothing(registration) || JuliaForever2.release!(registration)
    end
    outcomes = repeated ? [first, observe()] : first
    expected_calls = repeated ? count(item -> item["allowed"], outcomes) : Int(first["allowed"])
    executed[] == expected_calls || error("Approval was bypassed or incorrectly cached")
    close(scope)
    close(root)
    return normalize(outcomes)
end

"""Compare cancellation after a Julia-owned tool body starts with the pinned DSH lifecycle."""
function tool_cancellation_result(input)
    scope = JuliaForever2.ExtensionScope()
    context = ExecutionContext()
    invoked = Ref(0)
    specification = JuliaForever2.ToolSpec(:fixture, Dict("type" => "object"), arguments -> begin
        invoked[] += 1
        get(input, "async", false) && yield()
        get(input, "cancel_during", false) && cancel!(context)
        return input["value"]
    end)
    registration = JuliaForever2.register_tool!(scope, specification)
    registration.ok || error(registration.reason)
    get(input, "cancel_before", false) && cancel!(context)
    result = JuliaForever2.invoke_tool!(scope, :fixture, Dict{String,Any}(); context)
    close(scope)
    close(context)
    return normalize(Dict("allowed" => result.ok, "invoked" => invoked[],
        "retained" => result.ok ? result.value : nothing))
end

"""Compare native tool-batch scheduling with the original pinned DSH scheduler."""
function tool_batch_result(input)
    scope = JuliaForever2.ExtensionScope()
    context = ExecutionContext()
    entered = Dict(specification["id"] => Base.Event() for specification in input["calls"])
    started = String[]
    active = Ref(0)
    peak = Ref(0)
    exclusive_safe = Ref(true)
    state_lock = ReentrantLock()
    for specification in input["calls"]
        get(specification, "registered", true) || continue
        callback = arguments -> begin
            lock(state_lock) do
                active[] += 1
                peak[] = max(peak[], active[])
                if get(specification, "mode", "exclusive") != "parallel" && active[] != 1
                    exclusive_safe[] = false
                end
                push!(started, specification["id"])
                notify(entered[specification["id"]])
            end
            haskey(specification, "wait_for") && wait(entered[specification["wait_for"]])
            lock(state_lock) do
                active[] -= 1
            end
            get(specification, "cancel", false) && cancel!(context)
            return specification["id"]
        end
        tool_spec = JuliaForever2.ToolSpec(Symbol(specification["id"]), Dict("type" => "object"),
            callback; concurrency_safe=get(specification, "mode", "exclusive") == "parallel")
        registered = JuliaForever2.register_tool!(scope, tool_spec)
        registered.ok || error(registered.reason)
        if get(specification, "deny", false)
            denied_name = Symbol(specification["id"])
            guard = JuliaForever2.register_tool_guard!(scope,
                call -> call.name === denied_name ? "Tool unavailable" : nothing)
            guard.ok || error(guard.reason)
        end
    end
    get(input, "cancel_before", false) && cancel!(context)
    calls = JuliaForever2.ToolCall[
        JuliaForever2.ToolCall(Symbol(specification["id"]), Dict{String,Any}())
        for specification in input["calls"]
    ]
    results = if get(input, "session", false)
        kernel = Kernel()
        session = Session(kernel; executor=JuliaForever2.ToolExecutor(scope))
        outcome = evaluate!(session, JuliaForever2.ToolBatch(calls; max_parallel=input["max_parallel"]); context)
        close(session)
        close(kernel)
        outcome.value
    else
        JuliaForever2.invoke_tool_batch!(scope, calls; max_parallel=input["max_parallel"], context)
    end
    close(scope)
    close(context)
    return normalize(Dict(
        "results" => [Dict("id" => input["calls"][index]["id"], "ok" => result.ok)
            for (index, result) in enumerate(results)],
        "executed" => sort!(started),
        "barrierSafe" => exclusive_safe[],
        "overlap" => get(input, "check_overlap", false) ? peak[] >= 2 : nothing,
    ))
end


"""Evaluate scoped per-step tool admission against pinned upstream registry decisions."""
function tool_activation_result(input)
    root = JuliaForever2.ExtensionScope()
    scopes = Dict{String,JuliaForever2.ExtensionScope}("root" => root)
    for specification in get(input, "scopes", [])
        scopes[specification["name"]] = JuliaForever2.ExtensionScope(scopes[get(specification, "parent", "root")])
    end
    scope_of(specification) = scopes[get(specification, "scope", get(input, "scope",
        haskey(scopes, "agent") ? "agent" : "root"))]
    registrations = Dict{String,Any}()
    admitted = Dict{String,Any}()
    conditions = String[]
    outcomes = Any[]
    active_context = Ref{Any}(nothing)

    function register(specification)
        category = get(specification, "when", nothing)
        predicate = isnothing(category) ? nothing : activation -> begin
            push!(conditions, specification["id"])
            category == "error" && error("fixture condition failed")
            category == "abort" && JuliaForever2.cancel!(active_context[])
            enabled = category in ("always", "abort") ||
                (category in ("enabled", "async-enabled") &&
                    get(activation.model_selection, "enabled", false) === true)
            return startswith(category, "async-") ? Threads.@spawn(enabled) : enabled
        end
        tool = JuliaForever2.ToolSpec(Symbol(specification["name"]), Dict("type" => "object"),
            arguments -> get(specification, "value", nothing); when=predicate)
        registration = JuliaForever2.register_tool!(scope_of(specification), tool)
        registration.ok || error(registration.reason)
        registrations[specification["id"]] = registration.registration
    end
    for specification in input["tools"]
        register(specification)
    end
    for operation in input["operations"]
        scope = scope_of(operation)
        kind = operation["type"]
        selected = get(admitted, get(operation, "set", ""), nothing)
        if kind == "prepare"
            context = JuliaForever2.ExecutionContext()
            get(operation, "cancel_before", false) && JuliaForever2.cancel!(context)
            active_context[] = context
            result = JuliaForever2.resolve_tool_set(scope; context,
                model_selection=Dict("enabled" => get(operation, "enabled", false)))
            if result.ok
                admitted[operation["id"]] = result.tool_set
                names = [String(item.name) for item in JuliaForever2.tools_snapshot(scope; tool_set=result.tool_set)]
                push!(outcomes, Dict("ok" => true, "names" => names))
            else
                push!(outcomes, Dict("ok" => false,
                    "error" => JuliaForever2.cancelled(context) ? "aborted" : "activation"))
            end
            close(context)
        elseif kind == "snapshot"
            push!(outcomes, Dict("names" => [String(item.name)
                for item in JuliaForever2.tools_snapshot(scope; tool_set=selected)]))
        elseif kind == "check"
            result = JuliaForever2.invoke_tool!(scope, Symbol(operation["name"]), Dict{String,Any}(); tool_set=selected)
            push!(outcomes, Dict("allowed" => result.ok, "value" => result.ok ? result.value : nothing))
        elseif kind == "register"
            register(operation["tool"])
        elseif kind == "remove"
            JuliaForever2.release!(registrations[operation["id"]])
        elseif kind == "restrict"
            filter = operation["filter"]
            restriction = JuliaForever2.restrict_tools!(scope; allow=get(filter, "allow", nothing),
                deny=get(filter, "deny", nothing))
            restriction.ok || error(restriction.reason)
            registrations[operation["id"]] = restriction.registration
        elseif kind == "close_set"
            close(admitted[operation["id"]])
        elseif kind == "close_scope"
            close(scope)
        elseif kind == "trace"
            push!(outcomes, Dict("conditions" => copy(conditions)))
        else
            error("Unknown tool admission fixture operation: $kind")
        end
    end
    close(root)
    return normalize(outcomes)
end

function session_query_result(input)
    return mktempdir() do directory
        matches = if get(input, "source", "stored") == "live"
            specification = only(input["sessions"])
            messages = Message[Message(Symbol(entry["role"]), entry["content"]) for entry in specification["messages"]]
            session = Session(Kernel(); messages, owns_kernel=true)
            results = JuliaForever2.search_history(session, input["text"];
                roles=get(input, "roles", nothing), limit=get(input, "limit", typemax(Int)))
            close(session)
            results
        else
            registry = JuliaForever2.PluginRegistry()
            JuliaForever2.register_plugin!(registry, JuliaForever2.session_store_plugin(directory))
            JuliaForever2.register_plugin!(registry, JuliaForever2.session_query_plugin())
            base = Kernel()
            host = JuliaForever2.PluginHost(base; registry)
            activated = JuliaForever2.activate!(host, JuliaForever2.Profile(:query, [:session_store, :session_query]))
            activated.ok || error(activated.reason)
            store = component(host, :session_store)
            for specification in input["sessions"]
                messages = Message[Message(Symbol(entry["role"]), entry["content"]) for entry in specification["messages"]]
                session = Session(Kernel(); messages, owns_kernel=true)
                saved = JuliaForever2.save_session!(store, specification["name"], session)
                saved.ok || error(saved.reason)
                close(session)
            end
            results = JuliaForever2.search_history(component(host, :session_query), input["text"];
                roles=get(input, "roles", nothing), limit=get(input, "limit", typemax(Int)))
            close(host)
            close(base)
            results
        end
        return normalize(Dict("ok" => true, "hits" => [
            Dict("session" => hit.session, "index" => hit.index,
                "role" => String(hit.role), "kind" => String(hit.kind), "content" => hit.content)
            for hit in matches]))
    end
end


"""Check reindexing against upstream text-query results after each native persisted rewrite."""
function indexed_rewrite_differential()
    fixtures = [
        Dict("name" => "initial", "text" => "sapphire", "sessions" => [
            Dict("name" => "rewritten", "messages" => [
                Dict("role" => "user", "content" => "one sapphire")])]),
        Dict("name" => "updated", "text" => "sapphire", "sessions" => [
            Dict("name" => "rewritten", "messages" => [
                Dict("role" => "user", "content" => "no match"),
                Dict("role" => "assistant", "content" => "SAPPHIRE restored")])]),
    ]
    expected = reference_results("session_query", fixtures)
    return mktempdir() do directory
        store = JuliaForever2.SessionStore(directory)
        index = JuliaForever2.SessionSearchIndex(store)
        observations = Any[]
        for fixture in fixtures
            specification = only(fixture["sessions"])
            messages = Message[Message(Symbol(entry["role"]), entry["content"]) for entry in specification["messages"]]
            session = Session(Kernel(); messages, owns_kernel=true)
            JuliaForever2.save_session!(store, specification["name"], session)
            close(session)
            matches = JuliaForever2.search_history(index, fixture["text"])
            push!(observations, normalize(Dict("ok" => true, "hits" => [
                Dict("session" => hit.session, "index" => hit.index, "role" => String(hit.role),
                    "kind" => String(hit.kind), "content" => hit.content) for hit in matches])))
        end
        return observations, expected
    end
end

@testset "Indexed search revision differentials against pinned upstream predicates" begin
    actual, expected = indexed_rewrite_differential()
    @test actual == expected
end

@testset "DSH full-product proof requires complete native differential evidence" begin
    verified = COVERAGE["verified_source_families"]
    cases = Set(area["kind"] for area in COVERAGE["native_comparisons"])
    evidence = !isempty(verified) && all(verified) do family
        get(family, "native", false) === true &&
            !isempty(get(family, "implementation_paths", String[])) &&
            !isempty(get(family, "differential_kinds", String[])) &&
            all(kind -> kind in cases, family["differential_kinds"])
    end
    proven = COVERAGE["inventory_complete"] === true &&
        isempty(COVERAGE["unverified_source_families"]) && evidence
    @test COVERAGE["superset_proven"] === proven
end

@testset "Pinned DSH differential behavior" begin
    candidates = (("patches", patch_result), ("layers", layer_result), ("profile_groups", profile_group_result),
            ("session_query", session_query_result),
            ("tool_arguments", tool_arguments_result), ("tool_outputs", tool_outputs_result),
            ("tool_output_projection", tool_output_projection_result),
            ("tool_activation", tool_activation_result), ("tool_batch", tool_batch_result), ("tool_cancellation", tool_cancellation_result),
            ("tool_approval", tool_approval_result), ("tool_completion", tool_completion_result),
            ("transport", transport_result), ("outgoing", outgoing_result), ("lifecycle", lifecycle_result),
            ("recovery", recovery_result), ("events", event_result), ("final_response", final_response_result),
            ("launch", launch_result), ("tools", tool_result), ("replacements", replacement_result),
            ("callback_close", callback_close_result))
    required = vcat(COVERAGE["native_comparisons"], COVERAGE["reference_only_comparisons"])
    @test Set(keys(CASES)) == Set(first.(candidates)) == Set(area["kind"] for area in required) && length(required) == length(candidates)
    for (kind, candidate) in candidates
        cases = CASES[kind]
        expected = reference_results(kind, cases)
        area = only(filter(area -> area["kind"] == kind, required))
        @test length(expected) == length(cases) == area["case_count"]
        @testset "$kind: $(input["name"])" for (input, reference) in zip(cases, expected)
            @test candidate(input) == reference
        end
    end
end

end
