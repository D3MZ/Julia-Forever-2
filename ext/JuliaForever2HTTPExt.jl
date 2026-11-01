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
    length(request.body) <= 1_048_576 ? dispatch(api, JSON.parse(String(request.body))) : response(413, "{\"error\":\"Payload too large\"}")
end

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
function JuliaForever2.start_web_server(api::JuliaForever2.SessionAPI; host::AbstractString="127.0.0.1", port::Integer=0, token=string(uuid4()), handler=web_request)
    serve(api, WebAddress(host, port), token, handler)
end

function serve(api, address::WebAddress, token, handler)
    server = HTTP.serve!(request -> Base.invokelatest(handler, api, token, request), address.host, address.port; verbose=false, max_body_bytes=1_048_576)
    WebServer(server, address.host, Int(HTTP.port(server)), String(token))
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
