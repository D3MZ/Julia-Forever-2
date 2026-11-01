module JSONRPCTransport

using JSON
using UUIDs: uuid4
using ..JuliaForever2: ExecutionContext, cancelled, monotonic_seconds, parse_json

struct RpcError{C,D}
    code::C
    message::String
    data::D
end

RpcError(code, message::AbstractString; data=missing) = RpcError(code, String(message), data)

struct RpcResult{V,E}
    ok::Bool
    value::V
    error::E
end

RpcResult(value) = RpcResult(true, value, nothing)
RpcResult(error::RpcError) = RpcResult(false, nothing, error)

mutable struct JsonRpcPeer{I,O}
    input::I
    output::O
    lock::ReentrantLock
    write_lock::ReentrantLock
    buffer::Vector{UInt8}
    pending::Dict{Any,Channel{RpcResult}}
    handlers::Vector{Task}
    reader::Union{Nothing,Task}
    reader_worker::Union{Nothing,Task}
    failure::Union{Nothing,RpcError}
    on_request::Any
    on_notification::Any
end

"""Create a line-delimited JSON-RPC peer over caller-owned streams, without starting a reader."""
function JsonRpcPeer(input, output; on_request=nothing, on_notification=nothing)
    return JsonRpcPeer(input, output, ReentrantLock(), ReentrantLock(), UInt8[],
        Dict{Any,Channel{RpcResult}}(), Task[], nothing, nothing, nothing, on_request, on_notification)
end

Base.isopen(peer::JsonRpcPeer) = lock(() -> isnothing(peer.failure), peer.lock)

function task_failure_message(task::Task)
    exceptions = Base.current_exceptions(task; backtrace=false)
    return isempty(exceptions) ? "Operation failed" : sprint(showerror, first(exceptions).exception)
end

function fail_peer!(peer::JsonRpcPeer, failure::RpcError)
    lock(peer.lock) do
        isnothing(peer.failure) && (peer.failure = failure)
        for channel in values(peer.pending)
            put!(channel, RpcResult(peer.failure))
        end
        empty!(peer.pending)
        empty!(peer.buffer)
    end
    return nothing
end

"""Reject pending and future requests; the caller retains ownership of the streams."""
Base.close(peer::JsonRpcPeer) = fail_peer!(peer, RpcError(nothing, "JSON-RPC transport closed"))

function write_frame!(peer::JsonRpcPeer, frame; active=Returns(true))
    worker = Threads.@spawn lock(peer.write_lock) do
        if active()
            write(peer.output, JSON.json(frame), '\n')
            flush(peer.output)
        end
    end
    wait(worker; throw=false)
    if istaskfailed(worker)
        error = RpcError(nothing, task_failure_message(worker))
        return RpcResult(error)
    end
    return RpcResult(nothing)
end

function error_frame(id, error::RpcError)
    detail = Dict{String,Any}("message" => error.message)
    isnothing(error.code) || (detail["code"] = error.code)
    ismissing(error.data) || (detail["data"] = error.data)
    return Dict("jsonrpc" => "2.0", "id" => id, "error" => detail)
end

object_params(value::AbstractDict) = value
object_params(value) = Dict{String,Any}()
rpc_id(value) = value isa AbstractString || (value isa Real && !(value isa Bool))

function resolve_handler_result(worker::Task)
    wait(worker; throw=false)
    istaskfailed(worker) && return RpcError(-32603, task_failure_message(worker))
    result = fetch(worker)
    return result isa Task ? resolve_handler_result(result) : result
end

function respond_to_request!(peer::JsonRpcPeer, id, method, worker)
    if isnothing(worker)
        return write_frame!(peer, error_frame(id, RpcError(-32601, "method not found: $method")))
    end
    result = resolve_handler_result(worker)
    frame = result isa RpcError ? error_frame(id, result) :
        Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "result" => result)
    return write_frame!(peer, frame)
end

function receive_response!(peer::JsonRpcPeer, id, frame)
    lock(peer.lock) do
        channel = pop!(peer.pending, id, nothing)
        if !isnothing(channel)
            error = get(frame, "error", nothing)
            result = if error isa AbstractDict || error isa AbstractVector
                detail = object_params(error)
                code = get(detail, "code", nothing)
                message = get(detail, "message", "JSON-RPC error")
                RpcResult(RpcError(code isa Real && !(code isa Bool) ? code : nothing,
                    message isa AbstractString ? message : "JSON-RPC error";
                    data=get(detail, "data", missing)))
            else
                RpcResult(get(frame, "result", nothing))
            end
            put!(channel, result)
        end
    end
    return nothing
end

function track_handler!(peer::JsonRpcPeer, task::Task)
    lock(peer.lock) do
        filter!(!istaskdone, peer.handlers)
        push!(peer.handlers, task)
    end
    return task
end

function settle_notification!(peer::JsonRpcPeer, worker::Task)
    wait(worker; throw=false)
    if istaskfailed(worker)
        fail_peer!(peer, RpcError(nothing, task_failure_message(worker)))
    else
        result = fetch(worker)
        result isa Task && settle_notification!(peer, result)
    end
    return nothing
end

function dispatch_frame!(peer::JsonRpcPeer, frame::AbstractDict)
    id, method = get(frame, "id", nothing), get(frame, "method", nothing)
    if rpc_id(id) && method isa AbstractString
        handler = lock(() -> peer.on_request, peer.lock)
        params = object_params(get(frame, "params", nothing))
        worker = isnothing(handler) ? nothing : @async Base.invokelatest(handler, method, params)
        task = @async respond_to_request!(peer, id, method, worker)
        track_handler!(peer, task)
        yield()
    elseif rpc_id(id)
        receive_response!(peer, id, frame)
    elseif method isa AbstractString
        handler = lock(() -> peer.on_notification, peer.lock)
        if !isnothing(handler)
            params = object_params(get(frame, "params", nothing))
            worker = @async Base.invokelatest(handler, method, params)
            task = @async settle_notification!(peer, worker)
            track_handler!(peer, task)
            yield()
        end
    end
    return nothing
end

dispatch_frame!(peer::JsonRpcPeer, frame) = nothing

"""Consume complete UTF-8 lines, retaining partial frames and ignoring malformed JSON as DSH does."""
function feed!(peer::JsonRpcPeer, bytes::AbstractVector{UInt8})
    lines = lock(peer.lock) do
        isnothing(peer.failure) || return Vector{Vector{UInt8}}()
        # The retained bytes have already been scanned and contain no newline.
        # Only scan newly appended data to avoid quadratic work on fragmented frames.
        scan_from = length(peer.buffer) + 1
        append!(peer.buffer, bytes)
        complete = Vector{Vector{UInt8}}()
        start = 1
        for index in scan_from:length(peer.buffer)
            if peer.buffer[index] == 0x0a
                push!(complete, peer.buffer[start:index-1])
                start = index + 1
            end
        end
        start == 1 || deleteat!(peer.buffer, 1:start-1)
        return complete
    end
    for line in lines
        text = strip(String(line))
        isempty(text) || dispatch_frame!(peer, parse_json(text))
    end
    return peer
end

feed!(peer::JsonRpcPeer, text::AbstractString) = feed!(peer, codeunits(text))

function read_frames!(peer::JsonRpcPeer)
    while isopen(peer) && !eof(peer.input)
        feed!(peer, readavailable(peer.input))
    end
    fail_peer!(peer, RpcError(nothing, "JSON-RPC input closed"))
    return nothing
end

"""Start one reader; failed or closed peers never regain request capability."""
function start!(peer::JsonRpcPeer)
    lock(peer.lock) do
        if isnothing(peer.reader) && isnothing(peer.failure)
            worker = Threads.@spawn read_frames!(peer)
            peer.reader_worker = worker
            peer.reader = Threads.@spawn begin
                wait(worker; throw=false)
                istaskfailed(worker) && fail_peer!(peer, RpcError(nothing, task_failure_message(worker)))
                nothing
            end
        end
    end
    return peer
end

"""Wait for incoming request and notification callbacks already dispatched by this peer."""
function drain!(peer::JsonRpcPeer)
    handlers = lock(() -> copy(peer.handlers), peer.lock)
    foreach(task -> wait(task; throw=false), handlers)
    lock(peer.lock) do
        filter!(!istaskdone, peer.handlers)
    end
    return nothing
end

function fail_request!(peer::JsonRpcPeer, id, error::RpcError)
    lock(peer.lock) do
        channel = pop!(peer.pending, id, nothing)
        isnothing(channel) || put!(channel, RpcResult(error))
    end
    return nothing
end

function write_request!(peer::JsonRpcPeer, id, frame)
    active = () -> lock(() -> haskey(peer.pending, id), peer.lock)
    result = write_frame!(peer, frame; active)
    failure = result.error
    isnothing(failure) || fail_request!(peer, id, failure)
    return nothing
end

"""Request any method, preserving remote errors and abandoning cancelled local waiters."""
function request!(peer::JsonRpcPeer, method::AbstractString, params=Dict{String,Any}(); context=nothing, timeout::Real=Inf)
    deadline = monotonic_seconds() + timeout
    id = "req_" * replace(string(uuid4()), "-" => "")
    channel = Channel{RpcResult}(1)
    failure = lock(peer.lock) do
        if isnothing(peer.failure)
            peer.pending[id] = channel
        end
        peer.failure
    end
    isnothing(failure) || return RpcResult(failure)
    if cancelled(context) || timeout <= 0
        lock(() -> pop!(peer.pending, id, nothing), peer.lock)
        return RpcResult(RpcError(nothing, "Request cancelled or timed out"))
    end
    frame = Dict("jsonrpc" => "2.0", "id" => id, "method" => String(method), "params" => params)
    Threads.@spawn write_request!(peer, id, frame)
    while !isready(channel) && !cancelled(context) && monotonic_seconds() < deadline
        sleep(0.001)
    end
    if !isready(channel)
        lock(peer.lock) do
            pending = pop!(peer.pending, id, nothing)
            isnothing(pending) || put!(channel, RpcResult(RpcError(nothing, "Request cancelled or timed out")))
        end
    end
    return take!(channel)
end

"""Send an uncorrelated notification, omitting params when they are not provided."""
function notify!(peer::JsonRpcPeer, method::AbstractString, params=nothing)
    frame = Dict{String,Any}("jsonrpc" => "2.0", "method" => String(method))
    isnothing(params) || (frame["params"] = params)
    return write_frame!(peer, frame)
end

end

using .JSONRPCTransport: RpcError, RpcResult, JsonRpcPeer, request!, notify!, feed!, start!, drain!
