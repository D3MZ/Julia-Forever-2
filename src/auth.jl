using Base64
using SHA
using Random
using Sockets
using UUIDs
using JWTs
using JSON
using Downloads

const OPENAI_ISSUER = "https://auth.openai.com"
const OPENAI_RESOURCE = "https://api.openai.com/v1"
const OPENAI_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
const AUTH_LOCK = ReentrantLock()
const AUTH_ACCOUNT_LOCKS = Dict{Tuple{String,Symbol},ReentrantLock}()

function auth_lock(dir::AbstractString, provider::Symbol)
    lock(AUTH_LOCK) do
        return get!(ReentrantLock, AUTH_ACCOUNT_LOCKS, (abspath(dir), provider))
    end
end

base64url(bytes) = rstrip(replace(base64encode(bytes), '+' => '-', '/' => '_'), '=')
random_secret() = base64url(rand(RandomDevice(), UInt8, 32))

function url_encode(value::AbstractString)
    io = IOBuffer()
    for byte in codeunits(value)
        if 0x41 <= byte <= 0x5a || 0x61 <= byte <= 0x7a || 0x30 <= byte <= 0x39 || byte in (0x2d, 0x2e, 0x5f, 0x7e)
            write(io, byte)
        else
            print(io, '%', uppercase(string(byte; base=16, pad=2)))
        end
    end
    return String(take!(io))
end

function url_decode(value::AbstractString)
    bytes = codeunits(value)
    io = IOBuffer()
    i = 1
    while i <= length(bytes)
        byte = bytes[i]
        if byte == UInt8('%')
            i + 2 <= length(bytes) || return nothing
            hex = String(UInt8[bytes[i + 1], bytes[i + 2]])
            parsed = tryparse(UInt8, hex; base=16)
            isnothing(parsed) && return nothing
            write(io, parsed)
            i += 3
        else
            write(io, byte == UInt8('+') ? UInt8(' ') : byte)
            i += 1
        end
    end
    text = String(take!(io))
    return isvalid(text) ? text : nothing
end

function query_string(params)
    io = IOBuffer()
    for (index, (key, value)) in enumerate(params)
        index == 1 || print(io, '&')
        print(io, url_encode(string(key)), '=', url_encode(string(value)))
    end
    return String(take!(io))
end

struct OAuthAttempt
    provider::Symbol
    redirect_uri::String
    state::String
    verifier::String
    nonce::String
    host_id::String
    client_id::String
end

Base.show(io::IO, attempt::OAuthAttempt) = print(io, "OAuthAttempt(", attempt.provider, ", [redacted])")

function oauth_attempt(provider::Symbol, redirect_uri::AbstractString; host_id="", client_id="")
    return OAuthAttempt(provider, String(redirect_uri), random_secret(), random_secret(), random_secret(), String(host_id), String(client_id))
end

function authorization_url(attempt::OAuthAttempt)
    challenge = base64url(sha256(attempt.verifier))
    if attempt.provider == :chatgpt
        client = isempty(attempt.client_id) ? "dynamic_agent_client" : attempt.client_id
        params = Pair{String,String}["client_id" => client, "ext_agent_host_id" => attempt.host_id, "response_type" => "code", "redirect_uri" => attempt.redirect_uri, "scope" => OPENAI_SCOPE, "resource" => OPENAI_RESOURCE, "state" => attempt.state, "nonce" => attempt.nonce, "code_challenge_method" => "S256", "code_challenge" => challenge]
        isempty(attempt.client_id) && push!(params, "agent_name_hint" => "Julia Forever 2")
        return OPENAI_ISSUER * "/api/accounts/authorize?" * query_string(params)
    end
    params = ["callback_url" => attempt.redirect_uri, "state" => attempt.state, "code_challenge" => challenge, "code_challenge_method" => "S256", "key_label" => "Julia Forever 2"]
    return "https://openrouter.ai/auth?" * query_string(params)
end

function callback_params(target::AbstractString)
    parts = split(target, '?'; limit=2)
    values = Dict{String,String}()
    valid = length(parts) == 2
    if valid
        for pair in split(parts[2], '&')
            fields = split(pair, '='; limit=2)
            key = url_decode(fields[1])
            value = length(fields) == 2 ? url_decode(fields[2]) : ""
            if isnothing(key) || isnothing(value) || haskey(values, key)
                valid = false
                break
            end
            values[key] = value
        end
    end
    return (path=String(parts[1]), values=values, valid=valid)
end

function finish_callback(attempt::OAuthAttempt, callback)
    bad = (ok=false, code="", client_id="", reason="Invalid authorization callback.")
    callback.valid && callback.path == "/auth/callback" || return bad
    get(callback.values, "state", "") == attempt.state || return bad
    haskey(callback.values, "error") && return (ok=false, code="", client_id="", reason="Authorization was declined or cancelled.")
    code = get(callback.values, "code", "")
    isempty(code) && return bad
    client = get(callback.values, "client_id", attempt.client_id)
    if attempt.provider == :chatgpt
        (isempty(client) || client == "dynamic_agent_client") && return bad
        !isempty(attempt.client_id) && client != attempt.client_id && return bad
    end
    return (ok=true, code=code, client_id=client, reason="")
end

config_dir() = get(ENV, "JULIAFOREVER_CONFIG_DIR", joinpath(homedir(), ".config", "juliaforever2"))

function save_credentials!(dir::AbstractString, provider::Symbol, credentials)
    lock(auth_lock(dir, provider)) do
        mkpath(dir; mode=0o700)
        path = joinpath(dir, "$(provider).json")
        mktemp(dir) do temp, io
            chmod(temp, 0o600)
            write(io, JSON.json(credentials))
            close(io)
            Base.Filesystem.rename(temp, path)
        end
    end
    return nothing
end

function load_credentials(dir::AbstractString, provider::Symbol)
    path = joinpath(dir, "$(provider).json")
    isfile(path) || return nothing
    data = parse_json(read(path, String))
    return data isa AbstractDict ? data : nothing
end

function host_id!(dir::AbstractString)
    lock(auth_lock(dir, :host)) do
        saved = load_credentials(dir, :host)
        !isnothing(saved) && return saved["id"]
        id = "urn:uuid:" * string(uuid4())
        save_credentials!(dir, :host, Dict("id" => id))
        return id
    end
end

struct SSEEvent
    event::String
    data::String
    id::String
end

mutable struct SSEDecoder{F} <: IO
    sink::F
    line::Vector{UInt8}
    data::Vector{String}
    event::String
    id::String
    after_cr::Bool
    first_line::Bool
end
SSEDecoder(sink) = SSEDecoder(sink, UInt8[], String[], "", "", false, true)
Base.isopen(::SSEDecoder) = true
Base.iswritable(::SSEDecoder) = true
Base.flush(::SSEDecoder) = nothing
Base.close(::SSEDecoder) = nothing

function sse_line!(decoder::SSEDecoder)
    line = String(copy(decoder.line))
    empty!(decoder.line)
    if decoder.first_line
        startswith(line, "\ufeff") && (line = chop(line; head=1, tail=0))
        decoder.first_line = false
    end
    if isempty(line)
        if !isempty(decoder.data)
            decoder.sink(SSEEvent(isempty(decoder.event) ? "message" : decoder.event, join(decoder.data, '\n'), decoder.id))
        end
        empty!(decoder.data)
        decoder.event = ""
        return nothing
    end
    startswith(line, ':') && return nothing
    parts = split(line, ':'; limit=2)
    field = parts[1]
    value = length(parts) == 2 ? String(parts[2]) : ""
    startswith(value, ' ') && (value = chop(value; head=1, tail=0))
    if field == "data"
        push!(decoder.data, value)
    elseif field == "event"
        decoder.event = value
    elseif field == "id" && !occursin('\0', value)
        decoder.id = value
    end
    return nothing
end

function Base.write(decoder::SSEDecoder, byte::UInt8)
    if decoder.after_cr
        decoder.after_cr = false
        byte == 0x0a && return 1
    end
    if byte == 0x0d || byte == 0x0a
        sse_line!(decoder)
        decoder.after_cr = byte == 0x0d
    else
        push!(decoder.line, byte)
    end
    return 1
end

function Base.unsafe_write(decoder::SSEDecoder, source::Ptr{UInt8}, count::UInt)
    for index in 1:Int(count)
        write(decoder, unsafe_load(source, index))
    end
    return Int(count)
end

function chatgpt_reply(stream::AbstractString)
    result = ChatGPTStream(ExecutionContext())
    write(SSEDecoder(result), stream)
    result.completed && !result.failed || return (ok=false, text="ChatGPT response ended before successful completion.")
    return (ok=true, text=String(take!(result.text)))
end

auth_request(url::AbstractString, body::String, headers, context::ExecutionContext=ExecutionContext()) = http_request(url, "POST", body, headers, context; timeout=60.0)

function verify_chatgpt_identity(token::AbstractString, client::AbstractString, nonce::Union{AbstractString,Nothing}; keyset=nothing)
    required = ["iss", "aud", "exp", "sub"]
    isnothing(nonce) || push!(required, "nonce")
    verifier = isnothing(keyset) ? JWTs.Verifier(OPENAI_ISSUER; algorithms=["RS256"], audience=String(client), nonce, required_claims=required) : JWTs.Verifier(keyset; algorithms=["RS256"], issuer=OPENAI_ISSUER, audience=String(client), nonce, required_claims=required)
    return JWTs.claims(JWTs.verify(verifier, String(token)))
end

function valid_token_response(data; require_id=false)
    data isa AbstractDict || return false
    fields = require_id ? ("access_token", "refresh_token", "id_token", "scope", "token_type") : ("access_token", "token_type")
    for field in fields
        value = get(data, field, nothing)
        value isa AbstractString && !isempty(value) || return false
    end
    refresh = get(data, "refresh_token", nothing)
    !isnothing(refresh) && !(refresh isa AbstractString && !isempty(refresh)) && return false
    lowercase(data["token_type"]) == "bearer" || return false
    lifetime = get(data, "expires_in", nothing)
    lifetime isa Real && !(lifetime isa Bool) && isfinite(lifetime) && lifetime > 0 || return false
    haskey(data, "scope") && !(data["scope"] isa AbstractString) && return false
    return true
end

function complete_authorization!(dir::AbstractString, attempt::OAuthAttempt, callback; transport=auth_request, identity=verify_chatgpt_identity, context=ExecutionContext(), persist=(provider, data) -> (save_credentials!(dir, provider, data); true))
    callback.ok || return (ok=false, reason=callback.reason)
    if attempt.provider == :chatgpt
        body = query_string(["grant_type" => "authorization_code", "client_id" => callback.client_id, "code" => callback.code, "code_verifier" => attempt.verifier, "redirect_uri" => attempt.redirect_uri, "resource" => OPENAI_RESOURCE])
        response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
        200 <= response.status < 300 || return (ok=false, reason=transport_reason(response, "ChatGPT authorization exchange"))
        data = parse_json(response.body)
        valid_token_response(data; require_id=true) || return (ok=false, reason="ChatGPT returned invalid credentials.")
        "chatgpt.tokens.use.direct" in split(data["scope"]) || return (ok=false, reason="ChatGPT plan access was not granted.")
        claims = identity(data["id_token"], callback.client_id, attempt.nonce)
        subject = get(claims, "sub", nothing)
        subject isa AbstractString && !isempty(subject) || return (ok=false, reason="ChatGPT returned an invalid identity.")
        previous = load_credentials(dir, :chatgpt)
        if !isempty(attempt.client_id) && !isnothing(previous) && get(previous, "subject", "") != get(claims, "sub", "")
            return (ok=false, reason="ChatGPT account did not match the saved account.")
        end
        credentials = Dict("client_id" => callback.client_id, "host_id" => attempt.host_id, "subject" => claims["sub"], "email" => get(claims, "email", ""), "access_token" => data["access_token"], "refresh_token" => data["refresh_token"], "id_token" => data["id_token"], "scope" => data["scope"], "expires_at" => time() + data["expires_in"])
        persist(:chatgpt, credentials) || return (ok=false, reason="Sign-in cancelled.")
        return (ok=true, reason="ChatGPT connected.")
    end
    body = JSON.json(Dict("code" => callback.code, "code_verifier" => attempt.verifier, "code_challenge_method" => "S256"))
    response = transport_request(transport, "https://openrouter.ai/api/v1/auth/keys", body, ["Content-Type" => "application/json"], context)
    200 <= response.status < 300 || return (ok=false, reason=transport_reason(response, "OpenRouter authorization exchange"))
    data = parse_json(response.body)
    data isa AbstractDict || return (ok=false, reason="OpenRouter returned invalid credentials.")
    key = get(data, "key", "")
    key isa AbstractString && !isempty(key) || return (ok=false, reason="OpenRouter did not return a key.")
    persist(:openrouter, Dict("key" => key)) || return (ok=false, reason="Sign-in cancelled.")
    return (ok=true, reason="OpenRouter connected.")
end

function refresh_chatgpt!(dir::AbstractString; transport=auth_request, identity=verify_chatgpt_identity, context=ExecutionContext())
    lock(auth_lock(dir, :chatgpt)) do
        saved = load_credentials(dir, :chatgpt)
        isnothing(saved) && return (ok=false, reason="Sign in to ChatGPT first.", credentials=nothing)
        get(saved, "expires_at", 0) > time() + 60 && return (ok=true, reason="", credentials=saved)
        body = query_string(["grant_type" => "refresh_token", "client_id" => saved["client_id"], "refresh_token" => saved["refresh_token"], "resource" => OPENAI_RESOURCE])
        response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
        200 <= response.status < 300 || return (ok=false, reason=transport_reason(response, "ChatGPT token refresh"), credentials=nothing)
        data = parse_json(response.body)
        valid_token_response(data) || return (ok=false, reason="ChatGPT returned invalid refreshed credentials.", credentials=nothing)
        if haskey(data, "id_token")
            claims = identity(data["id_token"], saved["client_id"], nothing)
            get(claims, "sub", "") == saved["subject"] || return (ok=false, reason="ChatGPT account changed during refresh.", credentials=nothing)
            saved["id_token"] = data["id_token"]
        end
        scope = get(data, "scope", saved["scope"])
        "chatgpt.tokens.use.direct" in split(scope) || return (ok=false, reason="ChatGPT plan access is no longer granted.", credentials=nothing)
        saved["access_token"] = data["access_token"]
        saved["refresh_token"] = get(data, "refresh_token", saved["refresh_token"])
        saved["scope"] = scope
        saved["expires_at"] = time() + data["expires_in"]
        save_credentials!(dir, :chatgpt, saved)
        return (ok=true, reason="", credentials=saved)
    end
end

mutable struct AuthFlow{C}
    lock::ReentrantLock
    cancelled::Bool
    listener::Union{Sockets.TCPServer,Nothing}
    context::C
end
AuthFlow(; timeout=180.0) = AuthFlow(ReentrantLock(), false, nothing, ExecutionContext(; timeout))

function cancel_auth!(flow::AuthFlow)
    lock(flow.lock) do
        flow.cancelled = true
        cancel!(flow.context)
        close(flow.context)
        listener = flow.listener
        isnothing(listener) || close(listener)
    end
    return nothing
end

function active_auth(flow::AuthFlow)
    lock(flow.lock) do
        return !flow.cancelled && !cancelled(flow.context)
    end
end

function open_auth_browser(url::AbstractString)
    command = Sys.isapple() ? "open" : Sys.iswindows() ? "rundll32" : "xdg-open"
    executable = Sys.which(command)
    isnothing(executable) && return false
    cmd = Sys.iswindows() ? `$(executable) url.dll,FileProtocolHandler $url` : `$(executable) $url`
    run(pipeline(ignorestatus(cmd), stdout=devnull, stderr=devnull); wait=false)
    return true
end

function read_request_line(client)
    bytes = UInt8[]
    while length(bytes) < 8192
        byte = read(client, UInt8)
        byte == 0x0a && return strip(String(bytes))
        push!(bytes, byte)
    end
    return ""
end

function receive_callback(server::Sockets.TCPServer, flow::AuthFlow, attempt::OAuthAttempt; timeout=180.0)
    deadline = monotonic_seconds() + timeout
    while active_auth(flow) && monotonic_seconds() < deadline
        connection = Threads.@spawn accept(server)
        while !istaskdone(connection) && active_auth(flow) && monotonic_seconds() < deadline
            sleep(0.05)
        end
        if !istaskdone(connection)
            close(server)
            wait(connection; throw=false)
            return (ok=false, code="", client_id="", reason="Sign-in cancelled or timed out.")
        end
        if !active_auth(flow) || monotonic_seconds() >= deadline
            istaskfailed(connection) || close(fetch(connection))
            return (ok=false, code="", client_id="", reason="Sign-in cancelled or timed out.")
        end
        client = fetch(connection)
        reader = Threads.@spawn read_request_line(client)
        request_deadline = min(deadline, monotonic_seconds() + 5)
        while !istaskdone(reader) && active_auth(flow) && monotonic_seconds() < request_deadline
            sleep(0.02)
        end
        if !istaskdone(reader) || !active_auth(flow) || monotonic_seconds() >= request_deadline
            close(client)
            wait(reader; throw=false)
            continue
        end
        request = split(fetch(reader), ' ')
        callback = length(request) == 3 && request[1] == "GET" ? finish_callback(attempt, callback_params(request[2])) : (ok=false, code="", client_id="", reason="Invalid authorization callback.")
        if callback.reason == "Invalid authorization callback."
            write(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            close(client)
            continue
        end
        message = callback.ok ? "Authorization received. You can return to Julia Forever 2." : "Authorization was not completed. You can return to Julia Forever 2."
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: $(ncodeunits(message))\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$message")
        close(client)
        return callback
    end
    return (ok=false, code="", client_id="", reason="Sign-in cancelled or timed out.")
end

function codex_sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), executable=Sys.which("codex"))
    active_auth(flow) || return (ok=false, reason="Sign-in cancelled.")
    if isnothing(executable)
        close(flow.context)
        return (ok=false, reason="Install the Codex CLI to sign in with ChatGPT.")
    end
    output = Pipe()
    process = run(pipeline(ignorestatus(`$executable login`); stdin=devnull, stdout=output, stderr=output); wait=false)::Base.Process
    close(output.in)
    reader = Threads.@spawn for line in eachline(output)
        url = match(r"https://[^\s]+", line)
        isnothing(url) || announce(String(url.match))
    end
    completed = wait_process!(process, flow.context)
    wait(reader)
    close(output)
    close(flow.context)
    if !active_auth(flow)
        return (ok=false, reason="Sign-in cancelled.")
    end
    return completed ? (ok=true, reason="ChatGPT / Codex connected.") : (ok=false, reason="Codex sign-in failed. Run codex login to retry.")
end

function run_authorization!(server::Sockets.TCPServer, flow::AuthFlow, provider::Symbol, dir::AbstractString; announce, opener, transport, identity, timeout)
    port = Int(getsockname(server)[2])
    redirect = "http://127.0.0.1:$port/auth/callback"
    host = provider == :chatgpt ? host_id!(dir) : ""
    saved = provider == :chatgpt ? load_credentials(dir, :chatgpt) : nothing
    pending = provider == :chatgpt && isnothing(saved) ? load_credentials(dir, :chatgpt_pending) : nothing
    registration = isnothing(saved) ? pending : saved
    client_id = isnothing(registration) ? "" : get(registration, "client_id", "")
    attempt = oauth_attempt(provider, redirect; host_id=host, client_id)
    url = authorization_url(attempt)
    announce(url)
    opener(url)
    callback = receive_callback(server, flow, attempt; timeout)
    callback.ok || return (ok=false, reason=callback.reason)
    if provider == :chatgpt && isempty(attempt.client_id)
        registered = lock(flow.lock) do
            active_auth(flow) || return false
            save_credentials!(dir, :chatgpt_pending, Dict("client_id" => callback.client_id, "host_id" => host))
            return true
        end
        registered || return (ok=false, reason="Sign-in cancelled.")
    end
    persist = (kind, credentials) -> lock(flow.lock) do
        active_auth(flow) || return false
        save_credentials!(dir, kind, credentials)
        return true
    end
    result = complete_authorization!(dir, attempt, callback; transport, identity, persist, context=flow.context)
    result.ok && provider == :chatgpt && rm(joinpath(dir, "chatgpt_pending.json"); force=true)
    return result
end

function sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), opener=open_auth_browser, transport=auth_request, identity=verify_chatgpt_identity, timeout=180.0)
    server = listen(ip"127.0.0.1", 0)
    started = lock(flow.lock) do
        active_auth(flow) || return false
        flow.listener = server
        return true
    end
    result = started ? run_authorization!(server, flow, provider, dir; announce, opener, transport, identity, timeout) : (ok=false, reason="Sign-in cancelled.")
    lock(flow.lock) do
        close(server)
        flow.listener = nothing
    end
    close(flow.context)
    return result
end
