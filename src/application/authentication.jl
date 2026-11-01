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
    output = IOBuffer()
    index = 1
    valid = true
    while valid && index <= length(bytes)
        byte, count = decode(bytes, index)
        valid = !isnothing(byte)
        if valid
            write(output, byte)
            index += count
        end
    end
    text = String(take!(output))
    valid && isvalid(text) ? text : nothing
end

function decode(bytes, index)
    byte = bytes[index]
    if byte == UInt8('%')
        parsed = index + 2 <= length(bytes) ? tryparse(UInt8, String(UInt8[bytes[index + 1], bytes[index + 2]]); base=16) : nothing
        (parsed, 3)
    else
        (byte == UInt8('+') ? UInt8(' ') : byte, 1)
    end
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

OAuthAttempt(provider::Symbol, redirect::AbstractString; host_id="", client_id="") = OAuthAttempt(provider, String(redirect), random_secret(), random_secret(), random_secret(), String(host_id), String(client_id))
oauth_attempt(provider::Symbol, redirect::AbstractString; kwargs...) = OAuthAttempt(provider, redirect; kwargs...)
function callback_params(target::AbstractString)
    parts = split(target, '?'; limit=2)
    values = Dict{String,String}()
    valid = length(parts) == 2
    fields = valid ? split(parts[2], '&') : SubString{String}[]
    index = 1
    while valid && index <= length(fields)
        pair = split(fields[index], '='; limit=2)
        key = url_decode(pair[1])
        value = length(pair) == 2 ? url_decode(pair[2]) : ""
        valid = !isnothing(key) && !isnothing(value) && !haskey(values, key)
        if valid
            values[key] = value
        end
        index += 1
    end
    (path=String(parts[1]), values, valid)
end
function finish_callback(attempt::OAuthAttempt, callback)
    if callback.valid && callback.path == "/auth/callback" && get(callback.values, "state", "") == attempt.state
        authorize(attempt, callback.values)
    else
        rejectedcallback("Invalid authorization callback.")
    end
end

rejectedcallback(reason) = (ok=false, code="", client_id="", reason)

function authorize(attempt::OAuthAttempt, values::AbstractDict)
    code = get(values, "code", "")
    client = get(values, "client_id", attempt.client_id)
    if haskey(values, "error")
        rejectedcallback("Authorization was declined or cancelled.")
    elseif !isempty(code) && valid_authorization_client(Val(attempt.provider), attempt, client)
        (ok=true, code, client_id=client, reason="")
    else
        rejectedcallback("Invalid authorization callback.")
    end
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
    callback.ok ? complete_authorization!(Val(attempt.provider), dir, attempt, callback; transport, identity, context, persist) : (ok=false, reason=callback.reason)
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
    launchbrowser(Sys.which(command), url)
end

launchbrowser(::Nothing, url) = false

function launchbrowser(executable::AbstractString, url)
    command = Sys.iswindows() ? `$executable url.dll,FileProtocolHandler $url` : `$executable $url`
    run(pipeline(ignorestatus(command), stdout=devnull, stderr=devnull); wait=false)
    true
end
function read_request_line(client)
    bytes = UInt8[]
    complete = false
    while length(bytes) < 8192 && !complete
        byte = read(client, UInt8)
        complete = byte == 0x0a
        if !complete
            push!(bytes, byte)
        end
    end
    complete ? strip(String(bytes)) : ""
end
function receive_callback(server::Sockets.TCPServer, flow::AuthFlow, attempt::OAuthAttempt; timeout=180.0)
    deadline = monotonic_seconds() + timeout
    callback = nothing
    while isnothing(callback) && active_auth(flow) && monotonic_seconds() < deadline
        callback = acceptcallback(server, flow, attempt, deadline)
    end
    isnothing(callback) ? rejectedcallback("Sign-in cancelled or timed out.") : callback
end

function acceptcallback(server, flow, attempt, deadline)
    connection = Threads.@spawn accept(server)
    while !istaskdone(connection) && active_auth(flow) && monotonic_seconds() < deadline
        sleep(0.05)
    end
    if !istaskdone(connection)
        close(server)
        wait(connection; throw=false)
        rejectedcallback("Sign-in cancelled or timed out.")
    elseif !active_auth(flow) || monotonic_seconds() >= deadline
        if !istaskfailed(connection)
            close(fetch(connection))
        end
        rejectedcallback("Sign-in cancelled or timed out.")
    else
        readcallback(fetch(connection), flow, attempt, deadline)
    end
end

function readcallback(client, flow, attempt, deadline)
    ownership = own_resource!(flow.context, client)
    reader = Threads.@spawn read_request_line(client)
    deadline = min(deadline, monotonic_seconds() + 5)
    while !istaskdone(reader) && active_auth(flow) && monotonic_seconds() < deadline
        sleep(0.02)
    end
    if !istaskdone(reader) || !active_auth(flow) || monotonic_seconds() >= deadline
        release!(ownership)
        wait(reader; throw=false)
        nothing
    else
        callback = replycallback(client, attempt, split(fetch(reader), ' '))
        release!(ownership)
        callback
    end
end

function replycallback(client, attempt, request)
    callback = length(request) == 3 && request[1] == "GET" ? finish_callback(attempt, callback_params(request[2])) : rejectedcallback("Invalid authorization callback.")
    if callback.reason == "Invalid authorization callback."
        write(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        nothing
    else
        message = callback.ok ? "Authorization received. You can return to Julia Forever 2." : "Authorization was not completed. You can return to Julia Forever 2."
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: $(ncodeunits(message))\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$message")
        callback
    end
end
