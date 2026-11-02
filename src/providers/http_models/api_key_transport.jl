"""Keep metadata bounded and replies genuinely incremental behind a successful-header gate."""
Base.@kwdef struct APIKeyHTTPTransport
    urls::Vector{String}
    pagination_urls::Vector{String}=String[]
    allow_loopback::Bool=false
    timeout::Float64=60.0
    max_catalog_bytes::Int=1024*1024
    max_response_bytes::Int=32*1024*1024
    max_request_bytes::Int=32*1024*1024
end
APIKeyHTTPTransport(urls,pagination_urls,allow_loopback,timeout,max_catalog_bytes,max_response_bytes)=
    APIKeyHTTPTransport(;urls,pagination_urls,allow_loopback,timeout,max_catalog_bytes,max_response_bytes)
Base.show(io::IO,::APIKeyHTTPTransport)=print(io,"APIKeyHTTPTransport(fixed endpoints, redirects disabled)")
function api_key_endpoint_allowed(transport::APIKeyHTTPTransport,url::AbstractString)
    parts=split(String(url),'?';limit=2)
    paginated=length(parts)==2 && any(isequal(first(parts)),transport.pagination_urls) && occursin(r"^after_id=[A-Za-z0-9._~%\-]{1,768}$",last(parts))
    declared=any(isequal(url),transport.urls) || paginated
    safe=occursin(r"^https://[a-zA-Z0-9.-]+(?::[0-9]+)?/[^\s#]*$",url)
    local_fixture=transport.allow_loopback && occursin(r"^http://127\.0\.0\.1:[0-9]+/[^\s#]*$",url)
    declared && (safe || local_fixture) && !any(iscntrl,url)
end
api_key_transport_response(response::Downloads.RequestError,output)= (status=0,body="",reason="API key transport failed.")
function api_key_transport_response(response::Downloads.Response,output)
    valid=200<=response.status<300
    body=valid && output isa IOBuffer ? String(take!(output)) : ""
    (status=response.status,body,reason=valid ? "" : "API key provider request failed.")
end
"""Copy bounded POST data into libcurl instead of leaving an upload coroutine pending during cancellation."""
function api_key_request_options!(easy,method::AbstractString,body::AbstractString)
    Downloads.Curl.setopt(easy,Downloads.Curl.CURLOPT_FOLLOWLOCATION,false)
    if method=="POST"
        data=String(body)
        Downloads.Curl.setopt(easy,Downloads.Curl.CURLOPT_POSTFIELDSIZE,sizeof(data))
        GC.@preserve data begin
            Downloads.Curl.setopt(easy,Downloads.Curl.CURLOPT_COPYPOSTFIELDS,pointer(data))
        end
    end
    nothing
end
function (transport::APIKeyHTTPTransport)(url,method,body,headers,context::ExecutionContext,sink)
    if cancelled(context) || !api_key_endpoint_allowed(transport,url) || !(method in ("GET","POST")) || sizeof(body)>transport.max_request_bytes
        (status=0,body="",reason="API key request cancelled or rejected by endpoint, method, or size limits.")
    else
        interrupt=Base.Event()
        gate=APIKeyHeaderGate(;interrupt,maximum_body=transport.max_response_bytes)
        output=isnothing(sink) ? IOBuffer(;maxsize=transport.max_catalog_bytes) : APIKeyStreamSink(sink,gate,context)
        register_cancellation!(context,interrupt;owned=false)
        ownership=own_resource!(context,interrupt;cleanup=event->unregister_cancellation!(context,event))
        downloader=Downloads.Downloader()
        downloader.easy_hook=(easy,info)->api_key_request_options!(easy,method,body)
        operation=Task(()->Downloads.request(url;method,output,headers,throw=false,downloader,
            timeout=min(transport.timeout,remaining_time(context)),interrupt,
            debug=isnothing(sink) ? nothing : (kind,data)->api_key_header_debug!(gate,kind,data)))
        schedule(operation)
        wait(operation;throw=false)
        release!(ownership)
        if istaskfailed(operation)
            (status=0,body="",reason="API key transport failed; any partial output is incomplete.")
        elseif cancelled(context)
            (status=0,body="",reason=api_key_gate_reason(Val(:cancelled)))
        else
            response=fetch(operation)::Union{Downloads.Response,Downloads.RequestError}
            isnothing(sink) ? api_key_transport_response(response,output) : api_key_stream_response(response,gate)
        end
    end
end

"""Do not turn provider error payloads or unknown finish strings into credential-bearing diagnostics."""
function sanitize_model_failure!(::APIKeyHTTPTransport,state::ModelStreamState)
    if !isempty(state.error)
        if !startswith(state.error,"Model HTTP request failed (")
            state.error="API key model stream failed; any partial output is incomplete."
        end
        reason=get(state.message,"rawStopReason",nothing)
        if !(reason in (nothing,"stop","end","length","function_call","tool_calls","end_turn","max_tokens","tool_use","pause_turn","stop_sequence","refusal","sensitive"))
            state.message["rawStopReason"]="unrecognized"
        end
    end
    nothing
end
