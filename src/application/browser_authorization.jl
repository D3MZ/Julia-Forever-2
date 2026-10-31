function run_authorization!(server::Sockets.TCPServer, flow::AuthFlow, provider::Symbol,
        dir::AbstractString; announce, opener, transport, identity, timeout)
    port = Int(getsockname(server)[2])
    redirect = "http://127.0.0.1:$port/auth/callback"
    protocol = Val(provider)
    registration = authorization_registration(protocol, dir)
    attempt = oauth_attempt(provider, redirect; registration...)
    url = authorization_url(attempt)
    announce(url)
    opener(url)
    callback = receive_callback(server, flow, attempt; timeout)
    callback.ok || return (ok=false, reason=callback.reason)
    remember_authorization_registration!(protocol, dir, flow, attempt, callback) ||
        return (ok=false, reason="Sign-in cancelled.")
    persist = (kind, credentials) -> lock(flow.lock) do
        active_auth(flow) || return false
        save_credentials!(dir, kind, credentials)
        true
    end
    result = complete_authorization!(dir, attempt, callback;
        transport, identity, persist, context=flow.context)
    result.ok && finish_authorization_registration!(protocol, dir)
    return result
end

function sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), opener=open_auth_browser, transport=auth_request, identity=nothing, timeout=180.0)
    server = listen(ip"127.0.0.1", 0)
    listener_ownership = own_resource!(flow.context, server)
    started = lock(flow.lock) do
        active_auth(flow) || return false
        flow.listener = server
        return true
    end
    result = started ? run_authorization!(server, flow, provider, dir; announce, opener, transport, identity, timeout) : (ok=false, reason="Sign-in cancelled.")
    lock(flow.lock) do
        release!(listener_ownership)
        flow.listener = nothing
    end
    close(flow.context)
    return result
end
