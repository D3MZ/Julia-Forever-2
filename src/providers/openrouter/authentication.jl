using JSON

function authorization_url(::Val{:openrouter}, attempt::OAuthAttempt)
    challenge = base64url(sha256(attempt.verifier))
    params = ["callback_url" => attempt.redirect_uri, "state" => attempt.state,
        "code_challenge" => challenge, "code_challenge_method" => "S256",
        "key_label" => "Julia Forever 2"]
    return "https://openrouter.ai/auth?" * query_string(params)
end

function complete_authorization!(::Val{:openrouter}, dir, attempt, callback; transport, identity, context, persist)
    body = JSON.json(Dict("code" => callback.code, "code_verifier" => attempt.verifier, "code_challenge_method" => "S256"))
    response = transport_request(transport, "https://openrouter.ai/api/v1/auth/keys", body, ["Content-Type" => "application/json"], context)
    200 <= response.status < 300 ? connect!(Val(:openrouter), parse_json(response.body), persist) : (ok=false, reason=transport_reason(response, "OpenRouter authorization exchange"))
end

connect!(::Val{:openrouter}, data, persist) = (ok=false, reason="OpenRouter returned invalid credentials.")

function connect!(::Val{:openrouter}, data::AbstractDict, persist)
    key = get(data, "key", "")
    if !(key isa AbstractString && !isempty(key))
        (ok=false, reason="OpenRouter did not return a key.")
    else
        persist(:openrouter, Dict("key" => key)) ? (ok=true, reason="OpenRouter connected.") : (ok=false, reason="Sign-in cancelled.")
    end
end
