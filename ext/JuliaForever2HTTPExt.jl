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

const WEB_ASSET_DIRECTORY = normpath(joinpath(@__DIR__, "..", "assets", "web"))

"""Load fixed, packaged Julia-native browser assets without any upstream runtime dependency."""
web_asset(::Val{:index}) = read(joinpath(WEB_ASSET_DIRECTORY, "index.html"), String)
web_asset(::Val{:script}) = read(joinpath(WEB_ASSET_DIRECTORY, "app.js"), String)
web_asset(::Val{:style}) = read(joinpath(WEB_ASSET_DIRECTORY, "app.css"), String)

function web_index()
    page = response(200, web_asset(Val(:index)), "text/html; charset=utf-8")
    HTTP.setheader(page, "Content-Security-Policy" =>
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; " *
        "base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
    HTTP.setheader(page, "X-Frame-Options" => "DENY")
    page
end

function route(api, request, target)
    if request.method == "GET" && target == "/"
        web_index()
    elseif request.method == "GET" && target == "/app.js"
        response(200, web_asset(Val(:script)), "text/javascript; charset=utf-8")
    elseif request.method == "GET" && target == "/app.css"
        response(200, web_asset(Val(:style)), "text/css; charset=utf-8")
    elseif request.method == "GET" && target == "/api/sessions"
        response(200, JSON.json(JuliaForever2.session_api_request!(api, "session/list")))
    elseif request.method == "POST" && target == "/api/rpc"
        rpc_response(api, request)
    else
        response(404, "{\"error\":\"Not found\"}")
    end
end

"""Parse a browser-facing bare authority without trusting forwarded headers."""
function web_authority(value::AbstractString)
    parsed = match(r"\A(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\z"i, value)
    if isnothing(parsed)
        nothing
    else
        digits = parsed.captures[2]
        port = isnothing(digits) ? nothing : parse(Int, digits)
        if isnothing(port) || port <= 65535
            (host=lowercase(String(parsed.captures[1])), port=port)
        else
            nothing
        end
    end
end

"""Recognize loopback host authorities without accepting deceptive DNS suffixes."""
function web_loopback_host(host::AbstractString)
    parts = split(host, '.')
    host in ("localhost", "[::1]") || (length(parts) == 4 && parts[1] == "127" &&
        all(part -> !isempty(part) && length(part) <= 3 &&
            all(isdigit, part) && parse(Int, part) <= 255, parts[2:end]))
end

web_origin_port(port, scheme) = isnothing(port) ? (scheme == "https" ? 443 : 80) : port

"""Require a complete HTTP(S) Origin with the same normalized Host authority."""
function web_same_origin(authority, origin::AbstractString)
    parsed = match(r"\A(https?)://(.+)\z"i, origin)
    if isnothing(parsed)
        false
    else
        other = web_authority(parsed.captures[2])
        scheme = lowercase(String(parsed.captures[1]))
        !isnothing(other) && authority.host == other.host &&
            web_origin_port(authority.port, scheme) == web_origin_port(other.port, scheme)
    end
end

web_has_header(request::HTTP.Request, name::AbstractString) =
    any(field -> lowercase(first(field)) == lowercase(name), request.headers)

"""Default loopback Web policy: reject DNS rebinding and cross-site browser requests."""
function trusted_web_request(request::HTTP.Request)
    authority = web_authority(HTTP.header(request, "Host"))
    if isnothing(authority) || !web_loopback_host(authority.host)
        false
    elseif lowercase(HTTP.header(request, "Sec-Fetch-Site")) == "cross-site"
        false
    else
        !web_has_header(request, "Origin") ||
            web_same_origin(authority, HTTP.header(request, "Origin"))
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

function authorize_web_request(api, access::WebAccess, handler, request::HTTP.Request, request_trust)
    if Base.invokelatest(request_trust, request)
        authorize_trusted_web_request(api, access, handler, request)
    else
        response(403, JSON.json(Dict("error" => "Untrusted request authority or origin")))
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
JuliaForever2.start_web_server(api::JuliaForever2.SessionAPI; host::AbstractString="127.0.0.1", port::Integer=0, token=string(uuid4()), handler=web_request, request_trust=trusted_web_request) =
    serve(api, WebAddress(host, port), token, handler, request_trust)

function serve(api, address::WebAddress, token, handler, request_trust)
    access = WebAccess(String(token))
    server = HTTP.serve!(request -> authorize_web_request(api, access, handler, request, request_trust), address.host, address.port; verbose=false, max_body_bytes=1_048_576)
    WebServer(server, address.host, Int(HTTP.port(server)), String(token))
end
"""An optional HTTP extension publishes an independently replaceable native Web service."""
function JuliaForever2.web_server_plugin(; name=:web_server, service_name=:web_server,
        api_service=:session_api, host="127.0.0.1", port=0, token=string(uuid4()), handler=web_request, request_trust=trusted_web_request)
    contract = Symbol(service_name)
    dependency = Symbol(api_service)
    setup = context -> JuliaForever2.provide!(context, contract,
        JuliaForever2.start_web_server(JuliaForever2.service(context, dependency);
            host, port, token, handler, request_trust); cleanup=close)
    return JuliaForever2.PluginSpec(name, setup; requires=[dependency], provides=[contract])
end

end
