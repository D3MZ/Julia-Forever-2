"""Buffer bounded responses before decoding so rejected HTTP bodies cannot leak into model events."""
Base.@kwdef struct APIKeyHTTPTransport
    urls::Vector{String}
    pagination_urls::Vector{String}=String[]
    allow_loopback::Bool=false
    timeout::Float64=60.0
    max_catalog_bytes::Int=1024*1024
    max_response_bytes::Int=32*1024*1024
end
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
function (transport::APIKeyHTTPTransport)(url,method,body,headers,context::ExecutionContext,sink)
    if cancelled(context) || !api_key_endpoint_allowed(transport,url)
        (status=0,body="",reason="API key request cancelled or endpoint rejected.")
    else
        output=IOBuffer(;maxsize=isnothing(sink) ? transport.max_catalog_bytes : transport.max_response_bytes)
        input=method=="GET" ? nothing : IOBuffer(body)
        interrupt=Base.Event()
        register_cancellation!(context,interrupt;owned=false)
        ownership=own_resource!(context,interrupt;cleanup=event->unregister_cancellation!(context,event))
        downloader=Downloads.Downloader()
        downloader.easy_hook=(easy,info)->Downloads.Curl.setopt(easy,Downloads.Curl.CURLOPT_FOLLOWLOCATION,false)
        operation=Task(()->Downloads.request(url;method,input,output,headers,throw=false,downloader,
            timeout=min(transport.timeout,remaining_time(context)),interrupt))
        schedule(operation)
        wait(operation;throw=false)
        release!(ownership)
        response=istaskfailed(operation) ? (status=0,body="",reason="API key transport failed.") : api_key_transport_response(fetch(operation),output)
        if !isnothing(sink) && 200<=response.status<300 && !cancelled(context)
            write(sink,response.body)
            (status=response.status,body="",reason=response.reason)
        else
            response
        end
    end
end
