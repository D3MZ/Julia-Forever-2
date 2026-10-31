using Base64
using SHA
using Random
using Sockets
using UUIDs
using JWTs

const OPENAI_ISSUER = "https://auth.openai.com"
const OPENAI_RESOURCE = "https://api.openai.com/v1"
const OPENAI_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
const AUTH_LOCK = ReentrantLock()

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
    mkpath(dir; mode=0o700)
    path = joinpath(dir, "$(provider).json")
    mktemp(dir) do temp, io
        chmod(temp, 0o600)
        write(io, JSON.json(credentials))
        close(io)
        Base.Filesystem.rename(temp, path)
    end
    return nothing
end

function load_credentials(dir::AbstractString, provider::Symbol)
    path = joinpath(dir, "$(provider).json")
    isfile(path) || return nothing
    return JSON.parse(read(path, String))
end

function host_id!(dir::AbstractString)
    lock(AUTH_LOCK) do
        saved = load_credentials(dir, :host)
        !isnothing(saved) && return saved["id"]
        id = "urn:uuid:" * string(uuid4())
        save_credentials!(dir, :host, Dict("id" => id))
        return id
    end
end

function chatgpt_reply(stream::AbstractString)
    text = IOBuffer()
    completed = false
    for line in split(stream, '\n')
        startswith(line, "data:") || continue
        data = strip(line[6:end])
        (isempty(data) || data == "[DONE]") && continue
        event = JSON.parse(data)
        kind = get(event, "type", "")
        kind == "response.output_text.delta" && print(text, get(event, "delta", ""))
        kind in ("response.failed", "response.incomplete", "error") && return (ok=false, text="ChatGPT response failed or was incomplete.")
        kind == "response.completed" && (completed = true)
    end
    completed || return (ok=false, text="ChatGPT response ended before completion.")
    return (ok=true, text=String(take!(text)))
end

function auth_request(url::AbstractString, body::String, headers)
    output = IOBuffer()
    response = Downloads.request(url; method="POST", input=IOBuffer(body), output, headers, throw=false, timeout=60)
    return (status=response.status, body=String(take!(output)))
end

function verify_chatgpt_identity(token::AbstractString, client::AbstractString, nonce::Union{AbstractString,Nothing}; keyset=nothing)
    required = ["iss", "aud", "exp", "sub"]
    isnothing(nonce) || push!(required, "nonce")
    verifier = isnothing(keyset) ? JWTs.Verifier(OPENAI_ISSUER; algorithms=["RS256"], audience=String(client), nonce, required_claims=required) : JWTs.Verifier(keyset; algorithms=["RS256"], issuer=OPENAI_ISSUER, audience=String(client), nonce, required_claims=required)
    return JWTs.claims(JWTs.verify(verifier, String(token)))
end

function valid_token_response(data; require_id=false)
    data isa AbstractDict || return false
    fields = require_id ? ("access_token", "refresh_token", "id_token", "scope", "token_type") : ("access_token", "refresh_token", "token_type")
    for field in fields
        value = get(data, field, nothing)
        value isa AbstractString && !isempty(value) || return false
    end
    lowercase(data["token_type"]) == "bearer" || return false
    lifetime = get(data, "expires_in", nothing)
    lifetime isa Real && !(lifetime isa Bool) && isfinite(lifetime) && lifetime > 0 || return false
    haskey(data, "scope") && !(data["scope"] isa AbstractString) && return false
    return true
end

function complete_authorization!(dir::AbstractString, attempt::OAuthAttempt, callback; transport=auth_request, identity=verify_chatgpt_identity, persist=(provider, data) -> (save_credentials!(dir, provider, data); true))
    callback.ok || return (ok=false, reason=callback.reason)
    if attempt.provider == :chatgpt
        body = query_string(["grant_type" => "authorization_code", "client_id" => callback.client_id, "code" => callback.code, "code_verifier" => attempt.verifier, "redirect_uri" => attempt.redirect_uri, "resource" => OPENAI_RESOURCE])
        response = transport(OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"])
        200 <= response.status < 300 || return (ok=false, reason="ChatGPT authorization exchange failed (HTTP $(response.status)).")
        data = JSON.parse(response.body)
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
    response = transport("https://openrouter.ai/api/v1/auth/keys", body, ["Content-Type" => "application/json"])
    200 <= response.status < 300 || return (ok=false, reason="OpenRouter authorization exchange failed (HTTP $(response.status)).")
    data = JSON.parse(response.body)
    key = get(data, "key", "")
    key isa AbstractString && !isempty(key) || return (ok=false, reason="OpenRouter did not return a key.")
    persist(:openrouter, Dict("key" => key)) || return (ok=false, reason="Sign-in cancelled.")
    return (ok=true, reason="OpenRouter connected.")
end

function refresh_chatgpt!(dir::AbstractString; transport=auth_request, identity=verify_chatgpt_identity)
    lock(AUTH_LOCK) do
        saved = load_credentials(dir, :chatgpt)
        isnothing(saved) && return (ok=false, reason="Sign in to ChatGPT first.", credentials=nothing)
        get(saved, "expires_at", 0) > time() + 60 && return (ok=true, reason="", credentials=saved)
        body = query_string(["grant_type" => "refresh_token", "client_id" => saved["client_id"], "refresh_token" => saved["refresh_token"], "resource" => OPENAI_RESOURCE])
        response = transport(OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"])
        200 <= response.status < 300 || return (ok=false, reason="ChatGPT session expired. Sign in again.", credentials=nothing)
        data = JSON.parse(response.body)
        valid_token_response(data) || return (ok=false, reason="ChatGPT returned invalid refreshed credentials.", credentials=nothing)
        if haskey(data, "id_token")
            claims = identity(data["id_token"], saved["client_id"], nothing)
            get(claims, "sub", "") == saved["subject"] || return (ok=false, reason="ChatGPT account changed during refresh.", credentials=nothing)
            saved["id_token"] = data["id_token"]
        end
        scope = get(data, "scope", saved["scope"])
        "chatgpt.tokens.use.direct" in split(scope) || return (ok=false, reason="ChatGPT plan access is no longer granted.", credentials=nothing)
        saved["access_token"] = data["access_token"]
        saved["refresh_token"] = data["refresh_token"]
        saved["scope"] = scope
        saved["expires_at"] = time() + data["expires_in"]
        save_credentials!(dir, :chatgpt, saved)
        return (ok=true, reason="", credentials=saved)
    end
end

mutable struct AuthFlow
    lock::ReentrantLock
    cancelled::Bool
    listener::Union{Sockets.TCPServer,Nothing}
end
AuthFlow() = AuthFlow(ReentrantLock(), false, nothing)

function cancel_auth!(flow::AuthFlow)
    lock(flow.lock) do
        flow.cancelled = true
        listener = flow.listener
        isnothing(listener) || close(listener)
    end
    return nothing
end

function active_auth(flow::AuthFlow)
    lock(flow.lock) do
        return !flow.cancelled
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

function receive_callback(server, flow::AuthFlow, attempt::OAuthAttempt; timeout=180.0)
    deadline = time() + timeout
    while active_auth(flow) && time() < deadline
        connection = @async accept(server)
        while !istaskdone(connection) && active_auth(flow) && time() < deadline
            sleep(0.05)
        end
        istaskdone(connection) || return (ok=false, code="", client_id="", reason="Sign-in cancelled or timed out.")
        istaskfailed(connection) && return (ok=false, code="", client_id="", reason="Sign-in listener stopped.")
        client = connection.result
        reader = @async read_request_line(client)
        request_deadline = min(deadline, time() + 5)
        while !istaskdone(reader) && active_auth(flow) && time() < request_deadline
            sleep(0.02)
        end
        if !istaskdone(reader) || istaskfailed(reader)
            close(client)
            continue
        end
        request = split(reader.result, ' ')
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

function sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), opener=open_auth_browser, transport=auth_request, identity=verify_chatgpt_identity, timeout=180.0)
    server = listen(ip"127.0.0.1", 0)
    started = lock(flow.lock) do
        flow.cancelled && return false
        flow.listener = server
        return true
    end
    if !started
        close(server)
        return (ok=false, reason="Sign-in cancelled.")
    end
    try
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
                flow.cancelled && return false
                save_credentials!(dir, :chatgpt_pending, Dict("client_id" => callback.client_id, "host_id" => host))
                return true
            end
            registered || return (ok=false, reason="Sign-in cancelled.")
        end
        persist = (kind, credentials) -> lock(flow.lock) do
            flow.cancelled && return false
            save_credentials!(dir, kind, credentials)
            return true
        end
        result = complete_authorization!(dir, attempt, callback; transport, identity, persist)
        result.ok && provider == :chatgpt && rm(joinpath(dir, "chatgpt_pending.json"); force=true)
        return result
    finally
        lock(flow.lock) do
            close(server)
            flow.listener = nothing
        end
    end
end
