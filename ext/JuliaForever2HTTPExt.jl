module JuliaForever2HTTPExt

using HTTP
using JSON
using UUIDs: uuid4
using JuliaForever2

struct WebServer{S}
    backend::S
    host::String
    port::Int
    token::String
end

Base.close(server::WebServer) = HTTP.forceclose(server.backend)
JuliaForever2.web_url(server::WebServer) = "http://$(server.host):$(server.port)"

function response(status::Integer, body::AbstractString, mime::AbstractString="application/json")
    return HTTP.Response(status; headers=["Content-Type" => mime, "Cache-Control" => "no-store",
        "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer"], body)
end

function rpc_response(api::JuliaForever2.SessionAPI, request::HTTP.Request)
    length(request.body) <= 1_048_576 || return response(413, "{\"error\":\"Payload too large\"}")
    frame = JSON.parse(String(request.body))
    frame isa AbstractDict && get(frame, "jsonrpc", nothing) == "2.0" ||
        return response(400, "{\"error\":\"Invalid JSON-RPC request\"}")
    method = get(frame, "method", nothing)
    method isa AbstractString || return response(400, "{\"error\":\"Missing method\"}")
    params = get(frame, "params", Dict{String,Any}())
    params isa AbstractDict || return response(400, "{\"error\":\"Invalid params\"}")
    result = JuliaForever2.session_api_request!(api, method, params)
    reply = Dict{String,Any}("jsonrpc" => "2.0", "id" => get(frame, "id", nothing))
    if result isa JuliaForever2.RpcError
        detail = Dict{String,Any}("code" => result.code, "message" => result.message)
        ismissing(result.data) || (detail["data"] = result.data)
        reply["error"] = detail
    else
        reply["result"] = result
    end
    return response(200, JSON.json(reply))
end

function web_request(api::JuliaForever2.SessionAPI, token::AbstractString, request::HTTP.Request)
    HTTP.header(request, "Authorization") == "Bearer $token" ||
        return HTTP.Response(401; headers=["WWW-Authenticate" => "Bearer", "Cache-Control" => "no-store"], body="Unauthorized")
    target = HTTP.URI(String(request.target)).path
    if request.method == "GET" && target == "/"
        return response(200, "<!doctype html><html lang=\"en\"><head><title>JuliaForever2</title></head><body><h1>JuliaForever2</h1><p>Native session API: /api/rpc</p></body></html>", "text/html; charset=utf-8")
    elseif request.method == "GET" && target == "/api/sessions"
        return response(200, JSON.json(JuliaForever2.session_api_request!(api, "session/list")))
    elseif request.method == "POST" && target == "/api/rpc"
        return rpc_response(api, request)
    end
    return response(404, "{\"error\":\"Not found\"}")
end

"""Start a token-authenticated loopback Web server backed only by Julia-native sessions."""
function JuliaForever2.start_web_server(api::JuliaForever2.SessionAPI;
        host::AbstractString="127.0.0.1", port::Integer=0, token=string(uuid4()), handler=web_request)
    host in ("127.0.0.1", "localhost", "::1") ||
        error("Native Web binds loopback only; use a TLS reverse proxy for remote access")
    0 <= port <= 65535 || error("Invalid Web port")
    server = HTTP.serve!(request -> Base.invokelatest(handler, api, token, request),
        String(host), Int(port); verbose=false, max_body_bytes=1_048_576)
    return WebServer(server, String(host), Int(HTTP.port(server)), String(token))
end

"""An optional HTTP extension publishes an independently replaceable native Web service."""
function JuliaForever2.web_server_plugin(; name=:web_server, service_name=:web_server,
        api_service=:session_api, host="127.0.0.1", port=0, token=string(uuid4()), handler=web_request)
    contract = Symbol(service_name)
    dependency = Symbol(api_service)
    setup = context -> JuliaForever2.provide!(context, contract,
        JuliaForever2.start_web_server(JuliaForever2.service(context, dependency);
            host, port, token, handler); cleanup=close)
    return JuliaForever2.PluginSpec(name, setup; requires=[dependency], provides=[contract])
end

end
