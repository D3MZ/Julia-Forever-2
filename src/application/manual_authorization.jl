"""Prepare a bounded callback inbox for the same native OAuth attempt and deadline."""
function begin_auth_callback!(flow::AuthFlow, attempt::OAuthAttempt, timeout::Real)
    lock(flow.lock) do
        if active_auth(flow) && isnothing(flow.inbox)
            flow.inbox = AuthorizationInbox(; attempt, deadline=monotonic_seconds()+max(0,timeout))
            true
        else
            false
        end
    end
end

manual_auth_available(::Nothing) = false
function manual_auth_available(flow::AuthFlow)
    lock(flow.lock) do
        active_auth(flow) && auth_inbox_available(flow.inbox)
    end
end

auth_inbox_available(::Nothing) = false
auth_inbox_available(inbox::AuthorizationInbox) = isnothing(inbox.result) && monotonic_seconds() < inbox.deadline

"""Validate a full callback URL against the exact active redirect without recording its contents."""
function manual_auth_callback(attempt::OAuthAttempt, input::AbstractString)
    bounded = isvalid(input) && ncodeunits(input) <= 8192
    text = bounded ? strip(String(input)) : ""
    safe = bounded && !any(c -> iscntrl(c) || isspace(c),text) && !occursin('#',text)
    pieces = split(text,'?';limit=2)
    if safe && length(pieces)==2 && pieces[1]==attempt.redirect_uri
        finish_callback(attempt,callback_params(string("/auth/callback?",pieces[2])))
    else
        rejectedcallback("Invalid authorization callback.")
    end
end

"""Accept a private manual callback once; acceptance is not token exchange or login success."""
function submit_auth_callback!(flow::AuthFlow, input::AbstractString)
    lock(flow.lock) do
        if active_auth(flow) && auth_inbox_available(flow.inbox)
            submit_auth_callback!(flow.inbox,input)
        else
            (ok=false,reason="No active authorization callback is awaiting input.")
        end
    end
end

submit_auth_callback!(::Nothing, input::AbstractString) = (ok=false,reason="No active authorization callback is awaiting input.")

function submit_auth_callback!(inbox::AuthorizationInbox, input::AbstractString)
    callback = manual_auth_callback(inbox.attempt,input)
    if callback.reason == "Invalid authorization callback."
        (ok=false,reason=callback.reason)
    else
        inbox.result = callback
        (ok=true,reason="Authorization callback received.")
    end
end

function received_auth_callback(flow::AuthFlow)
    lock(flow.lock) do
        received_auth_callback(flow.inbox)
    end
end
received_auth_callback(::Nothing) = nothing
received_auth_callback(inbox::AuthorizationInbox) = inbox.result

"""Resolve native and manual delivery exactly once while preserving cancellation and expiry."""
function claim_auth_callback!(flow::AuthFlow, callback::AuthorizationCallback)
    lock(flow.lock) do
        if !active_auth(flow)
            rejectedcallback("Sign-in cancelled or timed out.")
        else
            claim_auth_callback!(flow.inbox,callback)
        end
    end
end
claim_auth_callback!(::Nothing, callback::AuthorizationCallback) = callback
function claim_auth_callback!(inbox::AuthorizationInbox, callback::AuthorizationCallback)
    if !isnothing(inbox.result)
        inbox.result
    elseif monotonic_seconds() >= inbox.deadline
        rejectedcallback("Sign-in cancelled or timed out.")
    else
        inbox.result = callback
        callback
    end
end
