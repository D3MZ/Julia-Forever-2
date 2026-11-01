module DSHRuntimeDifferentialTests

using Test
using JSON
using JuliaForever2
using Downloads
using SHA
using HTTP

include("differential/dsh_reference_profiles.jl")
include("differential/dsh_reference_runtime.jl")

const RUNTIME_ORACLE = joinpath(@__DIR__, "differential", "runtime-oracle.mjs")
const RUNTIME_BINARY = get(ENV, "DSH_BIN", "")
const NODE_EXECUTABLE = get(ENV, "DSH_NODE", "node")
const LOCAL_MODEL_KEY = "dsh-differential-local-only"
const FIRST_PROMPT = "Remember the token sapphire."
const RESUMED_PROMPT = "What token did I ask you to remember?"
const LOCAL_RESPONSE = "Recorded sapphire."

normalize(value) = JSON.parse(JSON.json(value))

function isolated_environment(home)
    values = Dict{String,String}(ENV)
    for name in ("DEEPSEEK_BASE_URL", "DSH_PRIMARY_RUNTIME", "DSH_BUNDLED_PRIMARY_RUNTIME", "DSH_BUNDLED_OFFICE_CLI")
        delete!(values, name)
    end
    values["DSH_HOME"] = home
    values["DSH_TELEMETRY_DISABLED"] = "1"
    values["DEEPSEEK_API_KEY"] = ""
    values["DSH_PERMISSION_MODE"] = "read-only"
    return values
end

function runtime_profile(name, directory, home; arguments=String[], model_url=nothing)
    values = isolated_environment(home)
    if !isnothing(model_url)
        !isnothing(match(r"^http://127\.0\.0\.1:\d+$", model_url)) || error("Model fixture must bind IPv4 loopback")
        values["DEEPSEEK_BASE_URL"] = model_url
        values["DEEPSEEK_API_KEY"] = LOCAL_MODEL_KEY
    end
    executable = setenv(Cmd([NODE_EXECUTABLE, "--disable-warning=ExperimentalWarning", RUNTIME_BINARY]),
        values)
    return DSHProfile(name; command=executable, directory, home, arguments)
end

function reference_result(kind, directory, home; profile="sdk", model_url=nothing)
    request = Dict("kind" => kind, "directory" => directory, "home" => home,
        "binary" => RUNTIME_BINARY, "profile" => profile, "modelUrl" => model_url)
    command = Cmd([NODE_EXECUTABLE, "--disable-warning=ExperimentalWarning", RUNTIME_ORACLE])
    return JSON.parse(read(pipeline(command; stdin=IOBuffer(JSON.json(request))), String))
end

function result_value(result)
    error = isnothing(result.error) ? nothing : Dict("code" => result.error.code,
        "message" => result.error.message, "data" => result.error.data)
    return Dict("ok" => result.ok, "value" => result.value, "error" => error)
end

function record_operation!(operations, name, result)
    push!(operations, Dict("name" => name, "result" => result_value(result)))
    return result
end

function notification_value(method, params)
    if method == "session.event"
        return Dict("method" => method, "sessionId" => params["sessionId"], "type" => params["event"]["type"])
    end
    return Dict("method" => method, "params" => params)
end

function observe_sdk(profile, diagnostics, backend)
    operations = Any[]
    events = Any[]
    events_lock = ReentrantLock()
    observer = (method, params) -> lock(() -> push!(events, notification_value(method, params)), events_lock)
    factory = (command; kwargs...) -> begin
        started = JuliaForever2.start_runtime(command; kwargs...)
        started.ok || return started
        backend[] = started.value
        before = JuliaForever2.runtime_request!(started.value, "session/prompt",
            Dict("sessionId" => "differential-idle", "contentBlocks" =>
                [Dict("type" => "text", "text" => "must not execute")]); timeout=30)
        record_operation!(operations, "prompt-before-initialize", before)
        return started
    end
    connected = connect_dsh(profile; backend_factory=factory, on_notification=observer,
        initialize=Dict("provider" => "deepseek-official", "model" => "deepseek-flash"),
        timeout=30, stderr=diagnostics)
    connected.ok || error("Native SDK connection failed: $(connected.error.message)")
    client = connected.value
    record_operation!(operations, "initialize", JuliaForever2.RpcResult(Dict("serverInfo" => client.server_info)))
    session = DSHSession(client; id="differential-idle")
    record_operation!(operations, "working-directory-get", dsh_working_directory(session; timeout=30))
    record_operation!(operations, "working-directory-set", dsh_working_directory!(session, "child"; timeout=30))
    record_operation!(operations, "working-directory-after-set", dsh_working_directory(session; timeout=30))
    record_operation!(operations, "wait-idle", dsh_wait!(session; timeout=30))
    record_operation!(operations, "empty-query", dsh_query!(session, Any[]; timeout=30))
    record_operation!(operations, "blank-query", dsh_query!(session, " \n "; timeout=30))
    record_operation!(operations, "missing-directory", dsh_working_directory!(session, "does-not-exist"; timeout=30))
    record_operation!(operations, "directory-after-failure", dsh_working_directory(session; timeout=30))
    absent = DSHSession(client; id="differential-absent")
    record_operation!(operations, "missing-session-resume", dsh_resume!(absent; timeout=30))
    record_operation!(operations, "unknown-method", JuliaForever2.runtime_request!(client, "differential/unknown", Dict(); timeout=30))
    record_operation!(operations, "shutdown", JuliaForever2.runtime_request!(client, "shutdown", Dict(); timeout=30))
    process = client.backend.process
    timedwait(() -> !process_running(process), 10) === :ok || error("Native SDK runtime did not terminate after shutdown")
    wait(process)
    return normalize(Dict("release" => DSH_REFERENCE_VERSION,
        "referenceCommit" => DSH_REFERENCE_COMMIT, "operations" => operations,
        "events" => lock(() -> copy(events), events_lock), "exit" => process.exitcode))
end

function sdk_result(profile, diagnostics_path)
    backend = Ref{Any}(nothing)
    return open(diagnostics_path, "w") do diagnostics
        worker = Threads.@spawn observe_sdk(profile, diagnostics, backend)
        wait(worker; throw=false)
        isnothing(backend[]) || close(backend[])
        fetch(worker)
    end
end

function configuration_result(name, directory, home, temporary)
    profile = runtime_profile(name, directory, home; arguments=["--dump-config"])
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, JuliaForever2.process_launcher_plugin())
    output_path = joinpath(temporary, "$name.stdout")
    diagnostics_path = joinpath(temporary, "$name.stderr")
    code = open(output_path, "w") do output
        open(diagnostics_path, "w") do diagnostics
            JuliaForever2.register_plugin!(registry, dsh_frontend_plugin(:dsh_configuration;
                profile, stdout=output, stderr=diagnostics))
            base = Kernel()
            host = JuliaForever2.PluginHost(base; registry)
            worker = Threads.@spawn begin
                activated = JuliaForever2.activate!(host,
                    JuliaForever2.Profile(Symbol(name), [:process_launcher, :dsh_configuration]))
                activated.ok || error("Native configuration launch failed: $(activated.reason)")
                feature = component(host, :frontend)
                timedwait(() -> !process_running(feature.process), 10) === :ok || error("Native configuration dump did not exit")
                wait(feature)
                return feature.process.exitcode
            end
            wait(worker; throw=false)
            close(host)
            close(base)
            fetch(worker)
        end
    end
    clean(text) = replace(replace(text, home => "<home>"), "\r\n" => "\n")
    return Dict("profile" => name, "exit" => code, "output" => clean(read(output_path, String)),
        "diagnostics" => clean(read(diagnostics_path, String)))
end

function http_observation(url; method="GET", headers=Pair{String,String}[], replacements=Pair{String,String}[])
    downloader = Downloads.Downloader()
    downloader.easy_hook = (easy, _) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_FOLLOWLOCATION, false)
    output = IOBuffer()
    response = Downloads.request(String(url); method, headers, output, downloader, timeout=10)
    fields = Dict(lowercase(name) => value for (name, value) in response.headers)
    body = take!(output)
    if !isempty(replacements)
        body = Vector{UInt8}(codeunits(replace(String(body), replacements...)))
    end
    observation = Dict("status" => response.status, "contentType" => get(fields, "content-type", nothing),
        "cacheControl" => get(fields, "cache-control", nothing), "etag" => get(fields, "etag", nothing),
        "bodyBytes" => length(body), "bodySha256" => bytes2hex(sha256(body)))
    return (; observation, fields)
end

function browser_trust_cases(origin)
    return (
        ("plain", Pair{String,String}[]),
        ("same-origin", ["origin" => origin]),
        ("same-site", ["origin" => origin, "sec-fetch-site" => "same-site"]),
        ("foreign-origin", ["origin" => "https://untrusted.invalid"]),
        ("opaque-origin", ["origin" => "null"]),
        ("wrong-port-origin", ["origin" => "http://127.0.0.1:1"]),
        ("cross-site", ["origin" => origin, "sec-fetch-site" => "cross-site"]),
        ("foreign-host", ["host" => "untrusted.invalid"]),
        ("lookalike-host", ["host" => "127.0.0.1.untrusted.invalid"]),
    )
end

function observe_web(feature, home, output_path, diagnostics_path)
    pattern = r"dsh web: (http://127\.0\.0\.1:\d+/\S*)"
    ready() = !isnothing(match(pattern, read(output_path, String))) || !process_running(feature.process)
    timedwait(ready, 30; pollint=0.05) === :ok || error("Native DSH Web did not become ready")
    matched = match(pattern, read(output_path, String))
    isnothing(matched) && error("Native DSH Web exited before readiness: $(read(diagnostics_path, String))")
    authenticated_url = matched.captures[1]
    origin = match(r"^http://127\.0\.0\.1:\d+", authenticated_url).match
    responses = Any[]
    for (method, path) in (("GET", "/"), ("HEAD", "/"), ("GET", "/index.html"),
            ("GET", "/api/"), ("GET", "/connect"), ("POST", "/"), ("GET", "/__dsh_differential_missing__.js"))
        result = http_observation(origin * path; method)
        push!(responses, merge(Dict("method" => method, "path" => path), result.observation))
    end
    exchange = http_observation(authenticated_url)
    cookie_header = get(exchange.fields, "set-cookie", nothing)
    exchange.observation["status"] == 303 && !isnothing(cookie_header) ||
        error("Native DSH Web did not exchange its launch token for a browser cookie")
    cookie = String(first(split(cookie_header, ';')))
    authentication = Dict("status" => exchange.observation["status"], "location" => get(exchange.fields, "location", nothing),
        "cacheControl" => get(exchange.fields, "cache-control", nothing),
        "referrerPolicy" => get(exchange.fields, "referrer-policy", nothing))
    index = http_observation(origin * "/"; headers=["cookie" => cookie], replacements=[home => "<home>", origin => "<origin>"])
    asset = http_observation(origin * "/favicon.svg")
    cached = http_observation(origin * "/favicon.svg"; headers=["if-none-match" => asset.observation["etag"]])
    trust = Any[]
    for (name, extra_headers) in browser_trust_cases(origin)
        checked = http_observation(origin * "/api/"; headers=vcat(["cookie" => cookie], extra_headers))
        push!(trust, Dict("name" => name, "status" => checked.observation["status"]))
    end
    return Dict("release" => DSH_REFERENCE_VERSION, "referenceCommit" => DSH_REFERENCE_COMMIT,
        "responses" => responses, "authentication" => authentication,
        "index" => index.observation, "asset" => asset.observation,
        "cached" => cached.observation, "trust" => trust)
end

function web_result(directory, home, temporary)
    profile = runtime_profile("web", directory, home; arguments=["--no-open", "--host", "127.0.0.1", "--port", "0"])
    registry = JuliaForever2.PluginRegistry()
    JuliaForever2.register_plugin!(registry, JuliaForever2.process_launcher_plugin())
    output_path = joinpath(temporary, "web.stdout")
    diagnostics_path = joinpath(temporary, "web.stderr")
    return open(output_path, "w") do output
        open(diagnostics_path, "w") do diagnostics
            JuliaForever2.register_plugin!(registry, dsh_frontend_plugin(:dsh_web;
                profile, stdout=output, stderr=diagnostics))
            base = Kernel()
            host = JuliaForever2.PluginHost(base; registry)
            feature = Ref{Any}(nothing)
            worker = Threads.@spawn begin
                activated = JuliaForever2.activate!(host, JuliaForever2.Profile(:web, [:process_launcher, :dsh_web]))
                activated.ok || error("Native Web launch failed: $(activated.reason)")
                feature[] = component(host, :frontend)
                return observe_web(feature[], home, output_path, diagnostics_path)
            end
            wait(worker; throw=false)
            close(host)
            close(base)
            result = fetch(worker)
            result["exit"] = feature[].process.exitcode
            signal = feature[].process.termsignal
            result["signal"] = signal == 0 ? nothing : signal == 15 ? "SIGTERM" : "SIG$signal"
            return normalize(result)
        end
    end
end

function require_result(result)
    result.ok || error("Successful-turn differential failed: $(result.error.message)")
    return result.value
end

function successful_turn(profile, resume, diagnostics)
    notifications = Any[]
    events = Any[]
    event_lock = ReentrantLock()
    observer = (method, params) -> lock(event_lock) do
        push!(notifications, notification_value(method, params))
        method == "session.event" && push!(events, params["event"])
        nothing
    end
    initialized_directory = resume ? joinpath(profile.directory, "child") : profile.directory
    client = require_result(connect_dsh(profile; on_notification=observer, timeout=30, stderr=diagnostics,
        initialize=Dict("cwd" => initialized_directory, "provider" => "deepseek-official",
            "model" => "deepseek-v4-flash", "maxTokens" => 128)))
    worker = Threads.@spawn begin
        session = DSHSession(client; id="differential-persisted")
        restored = resume ? require_result(dsh_resume!(session; timeout=30)) : nothing
        directory = require_result(dsh_working_directory(session; timeout=30))["cwd"]
        receipt = require_result(dsh_prompt!(session, resume ? RESUMED_PROMPT : FIRST_PROMPT; timeout=30))
        waited = require_result(dsh_wait!(session; timeout=30))
        snapshot = lock(() -> deepcopy(events), event_lock)
        last_end = findlast(event -> event["type"] == "turn/end", snapshot)
        reason = isnothing(last_end) ? nothing : snapshot[last_end]["data"]["reason"]["kind"]
        return Dict("initialized" => client.server_info, "restored" => restored, "directory" => directory,
            "receipt" => get(receipt, "messageId", nothing) isa String && !isempty(receipt["messageId"]),
            "waited" => waited, "finalResponse" => dsh_final_response(snapshot), "finishReason" => reason,
            "notifications" => lock(() -> deepcopy(notifications), event_lock))
    end
    wait(worker; throw=false)
    close(client)
    return fetch(worker)
end

function successful_turns(profile, diagnostics_path)
    return open(diagnostics_path, "w") do diagnostics
        phases = [successful_turn(profile, resume, diagnostics) for resume in (false, true)]
        normalize(Dict("release" => DSH_REFERENCE_VERSION,
            "referenceCommit" => DSH_REFERENCE_COMMIT, "phases" => phases))
    end
end

function successful_turn_comparison(directory, temporary)
    command = Cmd([NODE_EXECUTABLE, "--disable-warning=ExperimentalWarning", RUNTIME_ORACLE])
    return open(joinpath(temporary, "local-model.stderr"), "w") do diagnostics
        fixture = open(pipeline(ignorestatus(command); stderr=diagnostics), "r+")
        worker = Threads.@spawn begin
            write(fixture, JSON.json(Dict("kind" => "model-fixture", "binary" => RUNTIME_BINARY)), '\n')
            close(fixture.in)
            ready = Threads.@spawn JSON.parse(readline(fixture))
            timedwait(() -> istaskdone(ready), 10; pollint=0.05) === :ok || error("Official local model fixture did not become ready")
            model_url = fetch(ready)["baseURL"]
            reference = reference_result("successful-turns", directory, joinpath(temporary, "reference-turns"); model_url)
            profile = runtime_profile("sdk", directory, joinpath(temporary, "native-turns"); model_url)
            candidate = successful_turns(profile, joinpath(temporary, "successful-turns.stderr"))
            return (; reference, candidate)
        end
        wait(worker; throw=false)
        if process_running(fixture)
            kill(fixture)
            timedwait(() -> !process_running(fixture), 10; pollint=0.05)
            process_running(fixture) && kill(fixture, Base.SIGKILL)
        end
        wait(fixture)
        compared = fetch(worker)
        captured = JSON.parse(read(fixture, String))["requests"]
        close(fixture.out)
        length(captured) == 4 || error("Expected exactly four local model requests from the paired prompt/resume scenarios")
        expected_history = [Dict("role" => "user", "text" => FIRST_PROMPT),
            Dict("role" => "assistant", "text" => LOCAL_RESPONSE), Dict("role" => "user", "text" => RESUMED_PROMPT)]
        captured[2]["history"] == expected_history || error("Upstream resume did not preserve the first turn's message history")
        return (; compared.reference, compared.candidate, reference_requests=captured[1:2], candidate_requests=captured[3:4])
    end
end


function native_workspace_comparison(reference, directory)
    operations = Dict(operation["name"] => operation["result"] for operation in reference["operations"])
    session = Session(Kernel(); owns_kernel=true, working_directory=directory)
    initial = JuliaForever2.working_directory(session)
    selected = JuliaForever2.set_working_directory!(session, "child")
    changed = JuliaForever2.working_directory(session)
    invalid = JuliaForever2.set_working_directory!(session, "does-not-exist")
    retained = JuliaForever2.working_directory(session)
    resolved = JuliaForever2.workspace_path(session, "example.txt")
    included = evaluate!(session, RunJulia("include(\"entry.jl\")"))
    included.ok || error("Native Julia session could not include a workspace-relative file")
    close(session)
    actual = Dict("initial" => initial, "set" => selected.ok, "changed" => changed,
        "missing" => invalid.ok, "retained" => retained, "resolved" => resolved,
        "include" => [included.value...])
    expected = Dict(
        "initial" => operations["working-directory-get"]["value"]["cwd"],
        "set" => operations["working-directory-set"]["ok"],
        "changed" => operations["working-directory-after-set"]["value"]["cwd"],
        "missing" => operations["missing-directory"]["ok"],
        "retained" => operations["directory-after-failure"]["value"]["cwd"],
        "resolved" => joinpath(operations["directory-after-failure"]["value"]["cwd"], "example.txt"),
        "include" => [joinpath(operations["directory-after-failure"]["value"]["cwd"], "nested", "sibling.jl"), 71])
    return actual, expected
end

function native_session_history(directory, temporary)
    registry = JuliaForever2.PluginRegistry()
    registered = JuliaForever2.register_plugin!(registry,
        JuliaForever2.session_store_plugin(joinpath(temporary, "julia-sessions")))
    registered.ok || error(registered.reason)
    base = Kernel()
    host = JuliaForever2.PluginHost(base; registry)
    activated = JuliaForever2.activate!(host, JuliaForever2.Profile(:resume, [:session_store]))
    activated.ok || error(activated.reason)
    store = component(host, :session_store)

    initial = Session(Kernel(); owns_kernel=true, working_directory=directory)
    JuliaForever2.append_message!(initial, Message(:user, FIRST_PROMPT))
    JuliaForever2.append_message!(initial, Message(:assistant, LOCAL_RESPONSE))
    saved = JuliaForever2.save_session!(store, "differential-persisted", initial)
    saved.ok || error(saved.reason)
    close(initial)

    resumed = JuliaForever2.load_session(store, "differential-persisted", Kernel(); owns_kernel=true)
    isnothing(resumed) && error("Native saved session was not found")
    restored_directory = JuliaForever2.working_directory(resumed)
    JuliaForever2.append_message!(resumed, Message(:user, RESUMED_PROMPT))
    history = [Dict("role" => String(message.role), "text" => message.content)
        for message in JuliaForever2.history_snapshot(resumed).messages]
    close(resumed)
    close(host)
    close(base)
    return Dict("directory" => restored_directory, "history" => history)
end


"""Compare the native Julia API's session operations with pinned upstream SDK behavior."""
function native_session_api_comparison(reference, directory, temporary)
    operations = Dict(item["name"] => item["result"] for item in reference["operations"])
    store = JuliaForever2.SessionStore(joinpath(temporary, "api-store"))
    api = JuliaForever2.SessionAPI(; store)
    open_result = JuliaForever2.session_api_request!(api, "session/open",
        Dict("session" => "api-reference", "workingDirectory" => directory))
    initial = JuliaForever2.session_api_request!(api, "session/workspace/get", Dict("session" => "api-reference"))
    selected = JuliaForever2.session_api_request!(api, "session/workspace/set",
        Dict("session" => "api-reference", "path" => "child"))
    changed = JuliaForever2.session_api_request!(api, "session/workspace/get", Dict("session" => "api-reference"))
    invalid = JuliaForever2.session_api_request!(api, "session/workspace/set",
        Dict("session" => "api-reference", "path" => "does-not-exist"))
    retained = JuliaForever2.session_api_request!(api, "session/workspace/get", Dict("session" => "api-reference"))
    blank = JuliaForever2.session_api_request!(api, "session/search",
        Dict("session" => "api-reference", "text" => " \n "))
    absent = JuliaForever2.session_api_request!(api, "session/resume", Dict("session" => "never-saved"))
    unknown = JuliaForever2.session_api_request!(api, "unrecognized/method")
    JuliaForever2.session_api_request!(api, "session/save", Dict("session" => "api-reference"))
    resumed_identity = open_result["id"]
    JuliaForever2.session_api_request!(api, "session/close", Dict("session" => "api-reference"))
    resumed = JuliaForever2.session_api_request!(api, "session/resume", Dict("session" => "api-reference"))
    actual = Dict("initial" => initial["workingDirectory"], "set" => selected isa AbstractDict,
        "changed" => changed["workingDirectory"], "missing" => !(invalid isa JuliaForever2.RpcError),
        "retained" => retained["workingDirectory"], "blank" => !(blank isa JuliaForever2.RpcError),
        "absent" => !(absent isa JuliaForever2.RpcError),
        "unknown" => !(unknown isa JuliaForever2.RpcError),
        "retainedIdentity" => resumed["id"] == resumed_identity)
    expected = Dict("initial" => operations["working-directory-get"]["value"]["cwd"],
        "set" => operations["working-directory-set"]["ok"],
        "changed" => operations["working-directory-after-set"]["value"]["cwd"],
        "missing" => operations["missing-directory"]["ok"],
        "retained" => operations["directory-after-failure"]["value"]["cwd"],
        "blank" => operations["blank-query"]["ok"],
        "absent" => operations["missing-session-resume"]["ok"],
        "unknown" => operations["unknown-method"]["ok"],
        "retainedIdentity" => true)
    close(api)
    return actual, expected
end

"""Compare Web authentication and HTML capability, not DSH's frontend bytes or URL layout."""
function native_web_comparison(reference, temporary)
    api = JuliaForever2.SessionAPI()
    server = JuliaForever2.start_web_server(api)
    origin = JuliaForever2.web_url(server)
    authorization = ["Authorization" => "Bearer $(server.token)"]
    unauthorized = HTTP.request("GET", origin * "/"; status_exception=false)
    authorized = HTTP.request("GET", origin * "/", authorization; status_exception=false)
    rpc = HTTP.request("POST", origin * "/api/rpc", authorization,
        JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "session/list"));
        status_exception=false)
    rpc_frame = JSON.parse(String(rpc.body))
    actual = Dict("unauthenticated" => unauthorized.status != 200,
        "authenticated" => authorized.status == 200,
        "html" => startswith(HTTP.header(authorized, "Content-Type"), "text/html"),
        "rpc" => rpc.status == 200 && rpc_frame["result"] == [])
    root = only(filter(row -> row["method"] == "GET" && row["path"] == "/", reference["responses"]))
    expected = Dict("unauthenticated" => root["status"] != 200,
        "authenticated" => reference["index"]["status"] == 200,
        "html" => startswith(reference["index"]["contentType"], "text/html"),
        "rpc" => true)
    close(server)
    close(api)
    return actual, expected
end

"""Compare a native Julia browser bootstrap against the pinned Web launch-cookie contract."""
function native_web_launch_comparison(reference)
    api = JuliaForever2.SessionAPI()
    server = JuliaForever2.start_web_server(api)
    origin = JuliaForever2.web_url(server)
    launch = JuliaForever2.web_launch_url(server)
    anonymous = HTTP.request("GET", origin * "/"; status_exception=false)
    invalid = HTTP.request("GET", launch * "invalid"; redirect=false, status_exception=false)
    exchange = HTTP.request("GET", launch; redirect=false, status_exception=false)
    cookie_header = HTTP.header(exchange, "Set-Cookie")
    cookie = first(split(cookie_header, ';'))
    session = HTTP.request("GET", origin * "/", ["Cookie" => cookie]; status_exception=false)
    payload = JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "session/list"))
    headers = ["Cookie" => cookie, "X-JuliaForever2-Request" => "1"]
    rpc = HTTP.request("POST", origin * "/api/rpc", headers, payload; status_exception=false)
    csrf = HTTP.request("POST", origin * "/api/rpc", ["Cookie" => cookie], payload; status_exception=false)
    replay = HTTP.request("GET", launch; redirect=false, status_exception=false)
    root = only(filter(row -> row["method"] == "GET" && row["path"] == "/", reference["responses"]))
    actual = Dict(
        "unauthenticated" => anonymous.status != 200,
        "invalidDenied" => invalid.status == 401,
        "exchangeStatus" => exchange.status,
        "redirectClearsToken" => HTTP.header(exchange, "Location") == "/",
        "cookieIssued" => !isempty(cookie_header),
        "cookieProtected" => occursin("HttpOnly", cookie_header) &&
            occursin("SameSite=Strict", cookie_header) && occursin("Path=/", cookie_header),
        "responseNoStore" => HTTP.header(exchange, "Cache-Control") == "no-store",
        "responseNoReferrer" => HTTP.header(exchange, "Referrer-Policy") == "no-referrer",
        "authenticatedHTML" => session.status == 200 &&
            startswith(HTTP.header(session, "Content-Type"), "text/html"),
        "authenticatedRPC" => rpc.status == 200 && JSON.parse(String(rpc.body))["result"] == [],
        "csrfDenied" => csrf.status == 403,
        "replayDenied" => replay.status == 401,
    )
    expected = Dict(
        "unauthenticated" => root["status"] != 200,
        "invalidDenied" => true,
        "exchangeStatus" => reference["authentication"]["status"],
        "redirectClearsToken" => true,
        "cookieIssued" => true,
        "cookieProtected" => true,
        "responseNoStore" => reference["authentication"]["cacheControl"] == "no-store",
        "responseNoReferrer" => reference["authentication"]["referrerPolicy"] == "no-referrer",
        "authenticatedHTML" => reference["index"]["status"] == 200 &&
            startswith(reference["index"]["contentType"], "text/html"),
        "authenticatedRPC" => true,
        "csrfDenied" => true,
        "replayDenied" => true,
    )
    close(server)
    close(api)
    return actual, expected
end

"""Compare live upstream trust decisions with the independently hosted Julia session API."""
function native_web_trust_comparison(reference)
    api = JuliaForever2.SessionAPI()
    server = JuliaForever2.start_web_server(api)
    origin = JuliaForever2.web_url(server)
    exchange = HTTP.request("GET", JuliaForever2.web_launch_url(server);
        redirect=false, status_exception=false)
    cookie = first(split(HTTP.header(exchange, "Set-Cookie"), ';'))
    actual = Dict{String,Bool}()
    for (name, extra_headers) in browser_trust_cases(origin)
        result = HTTP.request("GET", origin * "/api/sessions",
            vcat(["Cookie" => cookie], extra_headers); status_exception=false)
        actual[name] = result.status == 403
    end
    expected = Dict(String(entry["name"]) => entry["status"] == 403 for entry in reference["trust"])
    close(server)
    close(api)
    return actual, expected
end

@testset "Pinned DSH transport differentials using test-only protocol clients" begin
    isempty(RUNTIME_BINARY) && error("differential-runtime requires DSH_BIN pointing to the pinned DSH CLI JavaScript executable")
    mktempdir(pwd(); prefix="dsh-runtime-parity-") do temporary
        directory = mkpath(joinpath(temporary, "workspace with spaces"))
        mkpath(joinpath(directory, "child"))
        mkpath(joinpath(directory, "child", "nested"))
        write(joinpath(directory, "child", "entry.jl"), "include(\"nested/entry.jl\")\n")
        write(joinpath(directory, "child", "nested", "entry.jl"), "include(\"sibling.jl\")\n")
        write(joinpath(directory, "child", "nested", "sibling.jl"), "(@__FILE__, 71)\n")
        @testset "SDK process: $name" for name in ("sdk", "sdk-minimal")
            reference = reference_result("sdk", directory, joinpath(temporary, "reference-$name"); profile=name)
            profile = runtime_profile(name, directory, joinpath(temporary, "native-$name"))
            candidate = sdk_result(profile, joinpath(temporary, "$name-sdk.stderr"))
            @test candidate == reference
            @testset "Native session working directory: $name" begin
                actual, expected = native_workspace_comparison(reference, directory)
                @test actual == expected
            end
            @testset "Native session API: $name" begin
                actual, expected = native_session_api_comparison(reference, directory, temporary)
                @test actual == expected
            end
        end
        reference = reference_result("configuration", directory, joinpath(temporary, "reference-configurations"))
        length(reference["profiles"]) == length(DSH_SHIPPED_PROFILES) || error("Reference omitted a shipped DSH profile")
        @testset "Profile configuration: $(entry["profile"])" for entry in reference["profiles"]
            name = entry["profile"]
            candidate = configuration_result(name, directory, joinpath(temporary, "native-configurations", name), temporary)
            @test candidate == entry
        end
        @testset "Web process, authentication and static frontend" begin
            reference = reference_result("web", directory, joinpath(temporary, "reference-web"))
            candidate = web_result(directory, joinpath(temporary, "native-web"), temporary)
            @test candidate == reference
            @testset "Native Julia Web authentication and API" begin
                actual, expected = native_web_comparison(reference, temporary)
                @test actual == expected
            end
            @testset "Native Julia one-use browser launch and cookie authentication" begin
                actual, expected = native_web_launch_comparison(reference)
                @test actual == expected
            end
            @testset "Native Julia browser authority and Origin trust" begin
                actual, expected = native_web_trust_comparison(reference)
                @test expected["plain"] == false
                @test expected["same-origin"] == false
                @test expected["foreign-origin"] == true
                @test expected["opaque-origin"] == true
                @test expected["cross-site"] == true
                @test expected["foreign-host"] == true
                @test actual == expected
            end
        end
        @testset "Successful local model turn and persisted continuation" begin
            compared = successful_turn_comparison(directory, temporary)
            @test compared.candidate == compared.reference
            @test compared.candidate_requests == compared.reference_requests
            @testset "Native Julia persisted session history" begin
                resumed = native_session_history(directory, temporary)
                expected = Dict("directory" => compared.reference["phases"][1]["directory"],
                    "history" => compared.reference_requests[2]["history"])
                @test resumed == expected
            end
        end
    end
end

end
