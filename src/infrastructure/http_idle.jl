const DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300_000
const MODEL_HTTP_IDLE_TIMEOUT_MS = Base.ScopedValues.ScopedValue(DEFAULT_HTTP_IDLE_TIMEOUT_MS)
http_idle_timeout_ms() = MODEL_HTTP_IDLE_TIMEOUT_MS[]

"""Bind a model request's idle policy without changing authentication or process-global networking."""
function with_http_idle_timeout(callback, milliseconds::Int)
    milliseconds >= 0 || error("HTTP idle timeout must be nonnegative")
    Base.ScopedValues.with(callback, MODEL_HTTP_IDLE_TIMEOUT_MS => milliseconds)
end

"""Own one request's idle clock independently of its absolute execution deadline."""
Base.@kwdef mutable struct HTTPIdleWatch{F}
    timeout_ms::Int = DEFAULT_HTTP_IDLE_TIMEOUT_MS
    clock::F = monotonic_seconds
    activity::Float64 = clock()
    interrupt::Base.Event = Base.Event()
    lock::ReentrantLock = ReentrantLock()
    phase::Symbol = :headers
    armed::Bool = true
    status::Int = 0
    paused::Int = 0
    expired::Bool = false
    expired_phase::Symbol = :headers
    closed::Bool = false
    timer::Union{Nothing,Timer} = nothing
end

function idle_expired!(watch::HTTPIdleWatch)
    lock(watch.lock) do
        if !watch.closed && !watch.expired && watch.armed && watch.timeout_ms > 0 && watch.paused == 0 &&
                watch.clock() - watch.activity >= watch.timeout_ms / 1000
            watch.expired = true
            watch.expired_phase = watch.phase
            notify(watch.interrupt)
        end
        watch.expired
    end
end

"""Observe framing and byte activity, never retain or log request/response contents."""
function idle_debug!(watch::HTTPIdleWatch, kind::AbstractString, data::AbstractString)
    lock(watch.lock) do
        idle_expired!(watch)
        if !watch.closed && !watch.expired
            if kind == "HEADER OUT"
                watch.phase = :headers
                watch.armed = true
                watch.status = 0
                watch.activity = watch.clock()
            elseif kind == "DATA OUT" && !isempty(data)
                watch.activity = watch.clock()
            elseif kind == "HEADER IN"
                if startswith(data, "HTTP/")
                    parts = split(data; limit=3)
                    watch.status = length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
                elseif isempty(strip(data))
                    watch.phase = watch.status >= 200 ? :body : :headers
                    watch.activity = watch.clock()
                end
            elseif kind == "DATA IN" && !isempty(data) && watch.phase == :body
                watch.activity = watch.clock()
            end
        end
    end
    nothing
end

function idle_pause!(watch::HTTPIdleWatch)
    lock(watch.lock) do
        watch.paused += 1
    end
    nothing
end
function idle_resume!(watch::HTTPIdleWatch)
    lock(watch.lock) do
        watch.paused = max(0, watch.paused - 1)
        watch.activity = watch.clock()
    end
    nothing
end
function start_idle_watch!(watch::HTTPIdleWatch)
    lock(watch.lock) do
        if !watch.closed && watch.timeout_ms > 0 && isnothing(watch.timer)
            interval = min(0.1, max(0.001, watch.timeout_ms / 4000))
            watch.timer = Timer(_ -> idle_expired!(watch), interval; interval)
        end
    end
    watch
end
function Base.close(watch::HTTPIdleWatch)
    lock(watch.lock) do
        watch.closed = true
        notify(watch.interrupt)
        timer = watch.timer
        isnothing(timer) || close(timer)
        watch.timer = nothing
    end
    nothing
end

"""Do not count application backpressure as a stalled network response."""
struct HTTPIdleSink{I<:IO,W<:HTTPIdleWatch} <: IO
    output::I
    watch::W
end
Base.isopen(sink::HTTPIdleSink) = isopen(sink.output)
Base.iswritable(sink::HTTPIdleSink) = iswritable(sink.output)
Base.flush(sink::HTTPIdleSink) = flush(sink.output)
function Base.unsafe_write(sink::HTTPIdleSink, pointer::Ptr{UInt8}, count::UInt)
    idle_pause!(sink.watch)
    written = unsafe_write(sink.output, pointer, count)
    idle_resume!(sink.watch)
    written
end

const MODEL_DOWNLOADER_LOCK = ReentrantLock()
const MODEL_DOWNLOADER = Ref{Union{Nothing,Downloads.Downloader}}(nothing)
function model_downloader()
    lock(MODEL_DOWNLOADER_LOCK) do
        downloader = MODEL_DOWNLOADER[]
        if isnothing(downloader)
            downloader = Downloads.Downloader()
            downloader.easy_hook = (easy, info) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, 0)
            MODEL_DOWNLOADER[] = downloader
        end
        downloader
    end
end

function close_idle_watch!(watch::HTTPIdleWatch, context::ExecutionContext)
    close(watch)
    unregister_cancellation!(context, watch.interrupt)
    nothing
end
idle_reason(watch::HTTPIdleWatch) = "HTTP $(watch.expired_phase) idle timeout after $(watch.timeout_ms) ms."
