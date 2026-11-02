function run_authorization!(server::Sockets.TCPServer, flow::AuthFlow, provider::Symbol,
        dir::AbstractString; announce, opener, transport, identity, timeout)
    redirect = "http://127.0.0.1:$(Int(getsockname(server)[2]))/auth/callback"
    protocol = Val(provider)
    attempt = OAuthAttempt(provider, redirect; authorization_registration(protocol, dir)...)
    begin_auth_callback!(flow, attempt, timeout)
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
"""Claim one listener per flow; a rejected concurrent start never closes the owner's resources."""
function start_auth_listener!(flow::AuthFlow)
    lock(flow.lock) do
        if active_auth(flow) && isnothing(flow.listener) && isnothing(flow.inbox)
            server=listen(ip"127.0.0.1",0)
            ownership=own_resource!(flow.context,server)
            flow.listener=server
            (;server,ownership)
        else
            nothing
        end
    end
end

function sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), opener=open_auth_browser, transport=auth_request, identity=nothing, timeout=180.0)
    owned=start_auth_listener!(flow)
    sign_in_owned!(owned,flow,provider,dir;announce,opener,transport,identity,timeout)
end
sign_in_owned!(::Nothing,flow,provider,dir;kwargs...) = (ok=false,reason="Sign-in cancelled or another authorization is already active.")

function sign_in_owned!(owned::NamedTuple,flow::AuthFlow,provider::Symbol,dir::AbstractString;announce,opener,transport,identity,timeout)
    operation=Threads.@spawn run_authorization!(owned.server,flow,provider,dir;announce,opener,transport,identity,timeout)
    wait(operation;throw=false)
    lock(flow.lock) do
        release!(owned.ownership)
        flow.listener=nothing
        flow.inbox=nothing
    end
    close(flow)
    fetch(operation)
end
