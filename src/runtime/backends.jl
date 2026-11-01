abstract type AbstractRuntimeBackend end

"""Extend this method to expose a runtime's operations independently of its transport or framework."""
function runtime_request! end

"""Extend this method to forward an uncorrelated runtime event."""
function runtime_notify! end

"""Finish a gracefully stopped backend; alternative runtimes may extend their own shutdown wait."""
finish_runtime!(backend::AbstractRuntimeBackend; timeout=2.0) = close(backend)

mutable struct JsonRpcRuntime{P} <: AbstractRuntimeBackend
    peer::P
    process::Base.Process
    lock::ReentrantLock
    closed::Bool
end

"""Launch a caller-selected executable with a bidirectional, framework-neutral JSON-RPC transport."""
function start_runtime(command::Cmd; on_request=nothing, on_notification=nothing, stderr=Base.stderr)
    worker = Threads.@spawn open(pipeline(ignorestatus(command); stderr), "r+")
    wait(worker; throw=false)
    if istaskfailed(worker)
        return RpcResult(RpcError(nothing, JSONRPCTransport.task_failure_message(worker)))
    end
    process = fetch(worker)
    peer = JsonRpcPeer(process, process; on_request, on_notification)
    runtime = JsonRpcRuntime(peer, process, ReentrantLock(), false)
    start!(peer)
    return RpcResult(runtime)
end

runtime_request!(runtime::JsonRpcRuntime, method, params=Dict{String,Any}(); kwargs...) =
    request!(runtime.peer, method, params; kwargs...)
runtime_notify!(runtime::JsonRpcRuntime, method, params=nothing) = notify!(runtime.peer, method, params)
Base.isopen(runtime::JsonRpcRuntime) = !runtime.closed && isopen(runtime.peer)

function finish_runtime!(runtime::JsonRpcRuntime; timeout=2.0)
    timedwait(() -> !process_running(runtime.process), max(0.0, timeout); pollint=0.01)
    return close(runtime)
end

"""Stop and reap a runtime process; callers choose any protocol-specific graceful shutdown first."""
function Base.close(runtime::JsonRpcRuntime)
    lock(runtime.lock) do
        if !runtime.closed
            runtime.closed = true
            close(runtime.peer)
            stop_process!(runtime.process)
            close(runtime.process.in)
            close(runtime.process.out)
        end
    end
    reader = runtime.peer.reader
    isnothing(reader) || reader === current_task() || runtime.peer.reader_worker === current_task() ||
        wait(reader; throw=false)
    return nothing
end

mutable struct ProcessFeature
    process::Base.Process
    lock::ReentrantLock
    closed::Bool
end

"""Run a frontend or other process feature with caller-selected IO and an owned lifetime."""
function launch_feature(command::Cmd; stdin=devnull, stdout=Base.stdout, stderr=Base.stderr)
    worker = Threads.@spawn run(pipeline(ignorestatus(command); stdin, stdout, stderr); wait=false)
    wait(worker; throw=false)
    return istaskfailed(worker) ? RpcResult(RpcError(nothing, JSONRPCTransport.task_failure_message(worker))) :
        RpcResult(ProcessFeature(fetch(worker), ReentrantLock(), false))
end

Base.isopen(feature::ProcessFeature) = !feature.closed && process_running(feature.process)
Base.wait(feature::ProcessFeature) = (wait(feature.process); feature)
Base.success(feature::ProcessFeature) = success(feature.process)

function Base.close(feature::ProcessFeature)
    lock(feature.lock) do
        if !feature.closed
            feature.closed = true
            stop_process!(feature.process)
        end
    end
    return nothing
end
