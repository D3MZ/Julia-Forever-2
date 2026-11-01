function run_authorization!(server::Sockets.TCPServer, flow::AuthFlow, provider::Symbol,
        dir::AbstractString; announce, opener, transport, identity, timeout)
    redirect = "http://127.0.0.1:$(Int(getsockname(server)[2]))/auth/callback"
    protocol = Val(provider)
    attempt = OAuthAttempt(provider, redirect; authorization_registration(protocol, dir)...)
    url = authorization_url(attempt)
    announce(url)
    opener(url)
    callback = receive_callback(server, flow, attempt; timeout)
    if !callback.ok
        (ok=false, reason=callback.reason)
    elseif remember_authorization_registration!(protocol, dir, flow, attempt, callback)
        exchange!(flow, dir, attempt, callback; transport, identity)
    else
        (ok=false, reason="Sign-in cancelled.")
    end
end

function persist!(flow::AuthFlow, dir, kind, credentials)
    lock(flow.lock) do
        if active_auth(flow)
            save_credentials!(dir, kind, credentials)
            true
        else
            false
        end
    end
end

function exchange!(flow::AuthFlow, dir, attempt, callback; transport, identity)
    persist = (kind, credentials) -> persist!(flow, dir, kind, credentials)
    result = complete_authorization!(dir, attempt, callback; transport, identity, persist, context=flow.context)
    if result.ok
        finish_authorization_registration!(Val(attempt.provider), dir)
    end
    result
end
function sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), opener=open_auth_browser, transport=auth_request, identity=nothing, timeout=180.0)
    server = listen(ip"127.0.0.1", 0)
    listener_ownership = own_resource!(flow.context, server)
    started = lock(flow.lock) do
        active = active_auth(flow)
        if active
            flow.listener = server
        end
        active
    end
    result = started ? run_authorization!(server, flow, provider, dir; announce, opener, transport, identity, timeout) : (ok=false, reason="Sign-in cancelled.")
    lock(flow.lock) do
        release!(listener_ownership)
        flow.listener = nothing
    end
    close(flow.context)
    return result
end
