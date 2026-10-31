using JWTs
using UUIDs

const OPENAI_ISSUER = "https://auth.openai.com"
const OPENAI_RESOURCE = "https://api.openai.com/v1"
const OPENAI_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

function host_id!(dir::AbstractString)
    lock(auth_lock(dir, :host)) do
        saved = load_credentials(dir, :host)
        !isnothing(saved) && return saved["id"]
        id = "urn:uuid:" * string(uuid4())
        save_credentials!(dir, :host, Dict("id" => id))
        return id
    end
end

function verify_chatgpt_identity(token::AbstractString, client::AbstractString, nonce::Union{AbstractString,Nothing}; keyset=nothing)
    required = ["iss", "aud", "exp", "sub"]
    isnothing(nonce) || push!(required, "nonce")
    verifier = isnothing(keyset) ? JWTs.Verifier(OPENAI_ISSUER; algorithms=["RS256"], audience=String(client), nonce, required_claims=required) : JWTs.Verifier(keyset; algorithms=["RS256"], issuer=OPENAI_ISSUER, audience=String(client), nonce, required_claims=required)
    return JWTs.claims(JWTs.verify(verifier, String(token)))
end

function valid_token_response(data; require_id=false)
    data isa AbstractDict || return false
    fields = require_id ? ("access_token", "refresh_token", "id_token", "scope", "token_type") : ("access_token", "token_type")
    for field in fields
        value = get(data, field, nothing)
        value isa AbstractString && !isempty(value) || return false
    end
    refresh = get(data, "refresh_token", nothing)
    !isnothing(refresh) && !(refresh isa AbstractString && !isempty(refresh)) && return false
    lowercase(data["token_type"]) == "bearer" || return false
    lifetime = get(data, "expires_in", nothing)
    lifetime isa Real && !(lifetime isa Bool) && isfinite(lifetime) && lifetime > 0 || return false
    haskey(data, "scope") && !(data["scope"] isa AbstractString) && return false
    return true
end

function authorization_url(::Val{:chatgpt}, attempt::OAuthAttempt)
    challenge = base64url(sha256(attempt.verifier))
    client = isempty(attempt.client_id) ? "dynamic_agent_client" : attempt.client_id
    params = Pair{String,String}[
        "client_id" => client, "ext_agent_host_id" => attempt.host_id,
        "response_type" => "code", "redirect_uri" => attempt.redirect_uri,
        "scope" => OPENAI_SCOPE, "resource" => OPENAI_RESOURCE,
        "state" => attempt.state, "nonce" => attempt.nonce,
        "code_challenge_method" => "S256", "code_challenge" => challenge,
    ]
    isempty(attempt.client_id) && push!(params, "agent_name_hint" => "Julia Forever 2")
    return OPENAI_ISSUER * "/api/accounts/authorize?" * query_string(params)
end

function valid_authorization_client(::Val{:chatgpt}, attempt, client)
    (isempty(client) || client == "dynamic_agent_client") && return false
    return isempty(attempt.client_id) || client == attempt.client_id
end

function authorization_registration(::Val{:chatgpt}, dir)
    saved = load_credentials(dir, :chatgpt)
    registration = isnothing(saved) ? load_credentials(dir, :chatgpt_pending) : saved
    client_id = isnothing(registration) ? "" : get(registration, "client_id", "")
    return (host_id=host_id!(dir), client_id=client_id)
end

function remember_authorization_registration!(::Val{:chatgpt}, dir, flow, attempt, callback)
    isempty(attempt.client_id) || return true
    return lock(flow.lock) do
        active_auth(flow) || return false
        save_credentials!(dir, :chatgpt_pending,
            Dict("client_id" => callback.client_id, "host_id" => attempt.host_id))
        true
    end
end

finish_authorization_registration!(::Val{:chatgpt}, dir::AbstractString) = rm(joinpath(dir, "chatgpt_pending.json"); force=true)

function complete_authorization!(::Val{:chatgpt}, dir, attempt, callback;
        transport, identity, context, persist)
    verifier = isnothing(identity) ? verify_chatgpt_identity : identity
    body = query_string(["grant_type" => "authorization_code", "client_id" => callback.client_id, "code" => callback.code, "code_verifier" => attempt.verifier, "redirect_uri" => attempt.redirect_uri, "resource" => OPENAI_RESOURCE])
    response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
    200 <= response.status < 300 || return (ok=false, reason=transport_reason(response, "ChatGPT authorization exchange"))
    data = parse_json(response.body)
    valid_token_response(data; require_id=true) || return (ok=false, reason="ChatGPT returned invalid credentials.")
    "chatgpt.tokens.use.direct" in split(data["scope"]) || return (ok=false, reason="ChatGPT plan access was not granted.")
    claims = verifier(data["id_token"], callback.client_id, attempt.nonce)
    subject = get(claims, "sub", nothing)
    subject isa AbstractString && !isempty(subject) || return (ok=false, reason="ChatGPT returned an invalid identity.")
    previous = load_credentials(dir, :chatgpt)
    if !isempty(attempt.client_id) && !isnothing(previous) && get(previous, "subject", "") != get(claims, "sub", "")
        return (ok=false, reason="ChatGPT account did not match the saved account.")
    end
    credentials = Dict("client_id" => callback.client_id, "host_id" => attempt.host_id, "subject" => claims["sub"], "email" => get(claims, "email", ""), "access_token" => data["access_token"], "refresh_token" => data["refresh_token"], "id_token" => data["id_token"], "scope" => data["scope"], "expires_at" => time() + data["expires_in"])
    persist(:chatgpt, credentials) || return (ok=false, reason="Sign-in cancelled.")
    return (ok=true, reason="ChatGPT connected.")
end

function refresh_chatgpt!(dir::AbstractString; transport=auth_request, identity=verify_chatgpt_identity, context=ExecutionContext())
    lock(auth_lock(dir, :chatgpt)) do
        saved = load_credentials(dir, :chatgpt)
        isnothing(saved) && return (ok=false, reason="Sign in to ChatGPT first.", credentials=nothing)
        get(saved, "expires_at", 0) > time() + 60 && return (ok=true, reason="", credentials=saved)
        body = query_string(["grant_type" => "refresh_token", "client_id" => saved["client_id"], "refresh_token" => saved["refresh_token"], "resource" => OPENAI_RESOURCE])
        response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
        200 <= response.status < 300 || return (ok=false, reason=transport_reason(response, "ChatGPT token refresh"), credentials=nothing)
        data = parse_json(response.body)
        valid_token_response(data) || return (ok=false, reason="ChatGPT returned invalid refreshed credentials.", credentials=nothing)
        if haskey(data, "id_token")
            claims = identity(data["id_token"], saved["client_id"], nothing)
            get(claims, "sub", "") == saved["subject"] || return (ok=false, reason="ChatGPT account changed during refresh.", credentials=nothing)
            saved["id_token"] = data["id_token"]
        end
        scope = get(data, "scope", saved["scope"])
        "chatgpt.tokens.use.direct" in split(scope) || return (ok=false, reason="ChatGPT plan access is no longer granted.", credentials=nothing)
        saved["access_token"] = data["access_token"]
        saved["refresh_token"] = get(data, "refresh_token", saved["refresh_token"])
        saved["scope"] = scope
        saved["expires_at"] = time() + data["expires_in"]
        save_credentials!(dir, :chatgpt, saved)
        return (ok=true, reason="", credentials=saved)
    end
end
