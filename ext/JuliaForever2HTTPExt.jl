module JuliaForever2HTTPExt

using HTTP
using JSON
using UUIDs: uuid4
using JuliaForever2

mutable struct WebAccess
    token::String
    cookie::String
    lock::ReentrantLock
    redeemed::Bool

    WebAccess(token::String) = isempty(token) ? error("Web token must not be empty") : new(token, string(uuid4(), uuid4()), ReentrantLock(), false)
end

WebAccess(token::AbstractString) = WebAccess(String(token))

struct WebServer{S}
    backend::S
    host::String
    port::Int
    token::String
end

Base.close(server::WebServer) = HTTP.forceclose(server.backend)
JuliaForever2.web_url(server::WebServer) = "http://$(server.host):$(server.port)"
JuliaForever2.web_launch_url(server::WebServer) = JuliaForever2.web_url(server) * "/?access=" * HTTP.URIs.escapeuri(server.token)

response(status::Integer, body::AbstractString, mime::AbstractString="application/json") = HTTP.Response(status; headers=["Content-Type" => mime, "Cache-Control" => "no-store", "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer"], body)

rpc_response(api::JuliaForever2.SessionAPI, request::HTTP.Request) = length(request.body) <= 1_048_576 ? dispatch(api, JSON.parse(String(request.body))) : response(413, "{\"error\":\"Payload too large\"}")

dispatch(api::JuliaForever2.SessionAPI, frame) = response(400, "{\"error\":\"Invalid JSON-RPC request\"}")

function dispatch(api::JuliaForever2.SessionAPI, frame::AbstractDict)
    method = get(frame, "method", nothing)
    params = get(frame, "params", Dict{String,Any}())
    if get(frame, "jsonrpc", nothing) != "2.0"
        response(400, "{\"error\":\"Invalid JSON-RPC request\"}")
    elseif !(method isa AbstractString)
        response(400, "{\"error\":\"Missing method\"}")
    elseif params isa AbstractDict
        result = JuliaForever2.session_api_request!(api, method, params)
        response(200, JSON.json(envelope(get(frame, "id", nothing), result)))
    else
        response(400, "{\"error\":\"Invalid params\"}")
    end
end

envelope(id, result) = Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "result" => result)

function envelope(id, result::JuliaForever2.RpcError)
    detail = Dict{String,Any}("code" => result.code, "message" => result.message)
    if !ismissing(result.data)
        detail["data"] = result.data
    end
    Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "error" => detail)
end
function web_request(api::JuliaForever2.SessionAPI, token::AbstractString, request::HTTP.Request)
    if HTTP.header(request, "Authorization") == "Bearer $token"
        route(api, request, HTTP.URI(String(request.target)).path)
    else
        HTTP.Response(401; headers=["WWW-Authenticate" => "Bearer", "Cache-Control" => "no-store"], body="Unauthorized")
    end
end

function route(api, request, target)
    if request.method == "GET" && target == "/"
        response(200, "<!doctype html><html lang=\"en\"><head><title>JuliaForever2</title></head><body><h1>JuliaForever2</h1><p>Native session API: /api/rpc</p></body></html>", "text/html; charset=utf-8")
    elseif request.method == "GET" && target == "/api/sessions"
        response(200, JSON.json(JuliaForever2.session_api_request!(api, "session/list")))
    elseif request.method == "POST" && target == "/api/rpc"
        rpc_response(api, request)
    else
        response(404, "{\"error\":\"Not found\"}")
    end
end

"""Redeem a browser launch credential once while retaining the existing bearer handler."""
function redeem_web_access!(access::WebAccess, credential::AbstractString)
    lock(access.lock) do
        accepted = !access.redeemed && credential == access.token
        access.redeemed |= accepted
        accepted
    end
end

web_session_cookie(access::WebAccess, request::HTTP.Request) = any(part -> strip(part) == "juliaforever2_session=$(access.cookie)", split(HTTP.header(request, "Cookie"), ';'))


const LOCAL_WEB_AUTHORITY = r"^(127\.0\.0\.1|localhost|\[::1\])(?::([0-9]{1,5}))?$"i

"""Parse a literal loopback HTTP authority, using absence for invalid authority values."""
local_web_authority(value::AbstractString, scheme::AbstractString) = local_web_authority(match(LOCAL_WEB_AUTHORITY, value), scheme)
local_web_authority(::Nothing, ::AbstractString) = nothing

function local_web_authority(matched::RegexMatch, scheme::AbstractString)
    digits = matched.captures[2]
    port = isnothing(digits) ? (scheme == "https" ? 443 : 80) : tryparse(Int, digits)
    isnothing(port) || !(1 <= port <= 65535) ? nothing : (lowercase(matched.captures[1]), port)
end

"""Compare the browser's Origin to its actual HTTP Host, including the listener port."""
matching_web_origin(host::AbstractString, origin::AbstractString) = matching_web_origin(host, match(r"^(https?)://(.+)$"i, origin))
matching_web_origin(::AbstractString, ::Nothing) = false

function matching_web_origin(host::AbstractString, matched::RegexMatch)
    scheme = lowercase(matched.captures[1])
    authority = local_web_authority(host, scheme)
    !isnothing(authority) && authority == local_web_authority(matched.captures[2], scheme)
end

"""Protect every browser entry point and API from DNS rebinding and cross-site initiation."""
function trusted_web_request(request::HTTP.Request)
    host = HTTP.header(request, "Host")
    origin = HTTP.header(request, "Origin")
    valid_host = !isnothing(local_web_authority(host, "http"))
    same_site = lowercase(HTTP.header(request, "Sec-Fetch-Site")) != "cross-site"
    valid_host && same_site && (isempty(origin) || matching_web_origin(host, origin))
end

function authorize_web_request(api, access::WebAccess, handler, trust, request::HTTP.Request)
    trusted = Base.invokelatest(trust, request) === true
    if trusted
        authorize_trusted_web_request(api, access, handler, request)
    else
        response(403, "{\"error\":\"Untrusted browser authority\"}")
    end
end

function authorize_trusted_web_request(api, access::WebAccess, handler, request::HTTP.Request)
    uri = HTTP.URI(String(request.target))
    query = HTTP.queryparams(uri)
    if request.method == "GET" && uri.path == "/" && haskey(query, "access")
        redeem_web_access!(access, query["access"]) ? redirect(access) : response(401, "{\"error\":\"Invalid or redeemed launch token\"}")
    else
        authorize(api, access, handler, request)
    end
end

redirect(access::WebAccess) = HTTP.Response(303; headers=["Location" => "/", "Set-Cookie" => "juliaforever2_session=$(access.cookie); HttpOnly; SameSite=Strict; Path=/", "Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer", "X-Content-Type-Options" => "nosniff"], body="")

function authorize(api, access::WebAccess, handler, request::HTTP.Request)
    browser = web_session_cookie(access, request) && HTTP.header(request, "Authorization") != "Bearer $(access.token)"
    if browser && request.method in ("POST", "PUT", "PATCH", "DELETE") && HTTP.header(request, "X-JuliaForever2-Request") != "1"
        response(403, "{\"error\":\"Browser request token required\"}")
    else
        if browser
            HTTP.setheader(request, "Authorization" => "Bearer $(access.token)")
        end
        Base.invokelatest(handler, api, access.token, request)
    end
end

struct WebAddress
    host::String
    port::Int

    function WebAddress(host::String, port::Int)
        if !(host in ("127.0.0.1", "localhost", "::1"))
            error("Native Web binds loopback only; use a TLS reverse proxy for remote access")
        elseif 0 <= port <= 65535
            new(host, port)
        else
            error("Invalid Web port")
        end
    end
end

WebAddress(host::AbstractString, port::Integer) = WebAddress(String(host), Int(port))
"""Start a token-authenticated loopback Web server backed only by Julia-native sessions."""
function JuliaForever2.start_web_server(api::JuliaForever2.SessionAPI;
        host::AbstractString="127.0.0.1", port::Integer=0,
        token=string(uuid4()), handler=web_request, trust=trusted_web_request)
    serve(api, WebAddress(host, port), token, handler, trust)
end

function serve(api, address::WebAddress, token, handler, trust)
    access = WebAccess(String(token))
    server = HTTP.serve!(request -> authorize_web_request(api, access, handler, trust, request), address.host, address.port; verbose=false, max_body_bytes=1_048_576)
    WebServer(server, address.host, Int(HTTP.port(server)), String(token))
end
"""An optional HTTP extension publishes an independently replaceable native Web service."""
function JuliaForever2.web_server_plugin(; name=:web_server, service_name=:web_server,
        api_service=:session_api, host="127.0.0.1", port=0, token=string(uuid4()),
        handler=web_request, trust=trusted_web_request)
    contract = Symbol(service_name)
    dependency = Symbol(api_service)
    setup = context -> JuliaForever2.provide!(context, contract,
        JuliaForever2.start_web_server(JuliaForever2.service(context, dependency);
            host, port, token, handler, trust); cleanup=close)
    return JuliaForever2.PluginSpec(name, setup; requires=[dependency], provides=[contract])
end

end
