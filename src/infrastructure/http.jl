module HTTPTransport

using Downloads
using ..JuliaForever2: ExecutionContext, cancelled, remaining_time, register_cancellation!,
    unregister_cancellation!, own_resource!, release!, monotonic_seconds

include("http_idle.jl")

response_result(response::Downloads.Response, body::AbstractString) = (status=response.status, body=String(body), reason="")
response_result(response::Downloads.RequestError, body::AbstractString) = (status=0, body="", reason=response.message)

http_request(url, method, body, headers, context::ExecutionContext; kwargs...) = cancelled(context) ? (status=0, body="", reason="Request cancelled or timed out.") : request(url, method, body, headers, context; kwargs...)

function request(url, method, body, headers, context::ExecutionContext; timeout=120.0, sink=nothing,
        idle_timeout_ms::Union{Nothing,Int}=nothing, requester=Downloads.request, clock=monotonic_seconds, watch_timer::Bool=true)
    output = isnothing(sink) ? IOBuffer() : sink
    input = method == "GET" ? nothing : IOBuffer(body)
    interrupt = Base.Event()
    register_cancellation!(context, interrupt; owned=false)
    ownership = own_resource!(context, interrupt;
        cleanup=event -> unregister_cancellation!(context, event))
    response = perform_request(requester, url, method, input, output, headers, context, interrupt,
        min(timeout, remaining_time(context)), idle_timeout_ms, clock, watch_timer)
    release!(ownership)
    text = isnothing(sink) ? String(take!(output)) : ""
    cancelled(context) ? (status=0, body="", reason="Request cancelled or timed out.") : response_result(response, text)
end


function perform_request(requester, url, method, input, output, headers, context::ExecutionContext,
        interrupt::Base.Event, timeout::Real, ::Nothing, clock, watch_timer::Bool)
    requester(url; method, input, output, headers, throw=false, timeout, interrupt)
end
function perform_request(requester, url, method, input, output::IO, headers, context::ExecutionContext,
        interrupt::Base.Event, timeout::Real, milliseconds::Int, clock, watch_timer::Bool)
    milliseconds >= 0 || error("HTTP idle timeout must be nonnegative")
    watch = HTTPIdleWatch(; timeout_ms=milliseconds, clock, interrupt, armed=false)
    ownership = own_resource!(context, watch; cleanup=value -> close_idle_watch!(value, context))
    watch_timer && start_idle_watch!(watch)
    response = requester(url; method, input, output=HTTPIdleSink(output, watch), headers, throw=false,
        timeout, interrupt, downloader=model_downloader(), debug=(kind, data) -> idle_debug!(watch, kind, data))
    release!(ownership)
    watch.expired ? Downloads.RequestError(String(url), 0, idle_reason(watch),
        Downloads.Response(nothing, String(url), 0, "", Pair{String,String}[])) : response
end

transport_request(transport, url, body, headers, context::ExecutionContext) =  applicable(transport, url, body, headers, context) ? transport(url, body, headers, context) : transport(url, body, headers)

transport_request(transport, url, method, body, headers, context::ExecutionContext, sink=nothing) = applicable(transport, url, method, body, headers, context, sink) ? transport(url, method, body, headers, context, sink) : buffered(transport, url, method, body, headers, context, sink)

function buffered(transport, url, method, body, headers, context, sink)
    response = applicable(transport, url, method, body, headers, context) ? transport(url, method, body, headers, context) : transport(url, method, body, headers)
    if !isnothing(sink)
        write(sink, response.body)
    end
    response
end

transport_reason(response, label) = isempty(get(response, :reason, "")) ? "$label returned HTTP $(response.status)." : "$label: $(response.reason)"

end

using .HTTPTransport: http_request, transport_request, transport_reason, response_result
