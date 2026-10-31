using Base64
using SHA
using Random
using Sockets

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
    valid_authorization_client(Val(attempt.provider), attempt, client) || return bad
    return (ok=true, code=code, client_id=client, reason="")
end

authorization_url(attempt::OAuthAttempt) = authorization_url(Val(attempt.provider), attempt)
valid_authorization_client(provider, attempt, client) = true
authorization_registration(provider, dir) = (host_id="", client_id="")
remember_authorization_registration!(provider, dir, flow, attempt, callback) = true
finish_authorization_registration!(provider, dir) = nothing

auth_request(url::AbstractString, body::String, headers, context::ExecutionContext=ExecutionContext()) = http_request(url, "POST", body, headers, context; timeout=60.0)

"""Complete a provider authorization through its own exchange protocol."""
function complete_authorization!(dir::AbstractString, attempt::OAuthAttempt, callback;
        transport=auth_request, identity=nothing, context=ExecutionContext(),
        persist=(provider, data) -> (save_credentials!(dir, provider, data); true))
    callback.ok || return (ok=false, reason=callback.reason)
    return complete_authorization!(Val(attempt.provider), dir, attempt, callback;
        transport, identity, context, persist)
end

mutable struct AuthFlow{C}
    lock::ReentrantLock
    cancelled::Bool
    listener::Union{Sockets.TCPServer,Nothing}
    context::C
end
AuthFlow(; timeout=180.0) = AuthFlow(ReentrantLock(), false, nothing, ExecutionContext(; timeout))

Base.close(flow::AuthFlow) = close(flow.context)

function cancel_auth!(flow::AuthFlow)
    listener = lock(flow.lock) do
        flow.cancelled = true
        flow.listener
    end
    cancel!(flow.context)
    isnothing(listener) || close(listener)
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
        client_ownership = own_resource!(flow.context, client)
        reader = Threads.@spawn read_request_line(client)
        request_deadline = min(deadline, monotonic_seconds() + 5)
        while !istaskdone(reader) && active_auth(flow) && monotonic_seconds() < request_deadline
            sleep(0.02)
        end
        if !istaskdone(reader) || !active_auth(flow) || monotonic_seconds() >= request_deadline
            release!(client_ownership)
            wait(reader; throw=false)
            continue
        end
        request = split(fetch(reader), ' ')
        callback = length(request) == 3 && request[1] == "GET" ? finish_callback(attempt, callback_params(request[2])) : (ok=false, code="", client_id="", reason="Invalid authorization callback.")
        if callback.reason == "Invalid authorization callback."
            write(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            release!(client_ownership)
            continue
        end
        message = callback.ok ? "Authorization received. You can return to Julia Forever 2." : "Authorization was not completed. You can return to Julia Forever 2."
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: $(ncodeunits(message))\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$message")
        release!(client_ownership)
        return callback
    end
    return (ok=false, code="", client_id="", reason="Sign-in cancelled or timed out.")
end
