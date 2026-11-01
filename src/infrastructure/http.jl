module HTTPTransport

using Downloads
using ..JuliaForever2: ExecutionContext, cancelled, remaining_time, register_cancellation!,
    unregister_cancellation!, own_resource!, release!

response_result(response::Downloads.Response, body::AbstractString) = (status=response.status, body=String(body), reason="")
response_result(response::Downloads.RequestError, body::AbstractString) = (status=0, body="", reason=response.message)

function http_request(url, method, body, headers, context::ExecutionContext; timeout=120.0, sink=nothing)
    cancelled(context) && return (status=0, body="", reason="Request cancelled or timed out.")
    output = isnothing(sink) ? IOBuffer() : sink
    input = method == "GET" ? nothing : IOBuffer(body)
    interrupt = Base.Event()
    register_cancellation!(context, interrupt; owned=false)
    ownership = own_resource!(context, interrupt;
        cleanup=event -> unregister_cancellation!(context, event))
    response = Downloads.request(url; method, input, output, headers, throw=false,
        timeout=min(timeout, remaining_time(context)), interrupt)
    release!(ownership)
    text = isnothing(sink) ? String(take!(output)) : ""
    return response_result(response, text)
end

function transport_request(transport, url, body, headers, context::ExecutionContext)
    return applicable(transport, url, body, headers, context) ? transport(url, body, headers, context) : transport(url, body, headers)
end

function transport_request(transport, url, method, body, headers, context::ExecutionContext, sink=nothing)
    if applicable(transport, url, method, body, headers, context, sink)
        return transport(url, method, body, headers, context, sink)
    end
    response = applicable(transport, url, method, body, headers, context) ?
        transport(url, method, body, headers, context) :
        transport(url, method, body, headers)
    isnothing(sink) || write(sink, response.body)
    return response
end

transport_reason(response, label) = isempty(get(response, :reason, "")) ? "$label returned HTTP $(response.status)." : "$label: $(response.reason)"

end

using .HTTPTransport: http_request, transport_request, transport_reason, response_result
