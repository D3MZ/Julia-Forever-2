using JWTs
using UUIDs

const OPENAI_ISSUER = "https://auth.openai.com"
const OPENAI_RESOURCE = "https://api.openai.com/v1"
const OPENAI_SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

function host_id!(dir::AbstractString)
    lock(auth_lock(dir, :host)) do
        identifier!(dir, load_credentials(dir, :host))
    end
end

identifier!(dir, saved::AbstractDict) = saved["id"]

function identifier!(dir, ::Nothing)
    id = "urn:uuid:" * string(uuid4())
    save_credentials!(dir, :host, Dict("id" => id))
    id
end
function verify_chatgpt_identity(token::AbstractString, client::AbstractString, nonce::Union{AbstractString,Nothing}; keyset=nothing)
    required = ["iss", "aud", "exp", "sub"]
    isnothing(nonce) || push!(required, "nonce")
    verifier = isnothing(keyset) ? JWTs.Verifier(OPENAI_ISSUER; algorithms=["RS256"], audience=String(client), nonce, required_claims=required) : JWTs.Verifier(keyset; algorithms=["RS256"], issuer=OPENAI_ISSUER, audience=String(client), nonce, required_claims=required)
    return JWTs.claims(JWTs.verify(verifier, String(token)))
end

valid_token_response(data; require_id=false) = false

function valid_token_response(data::AbstractDict; require_id=false)
    fields = require_id ? ("access_token", "refresh_token", "id_token", "scope", "token_type") : ("access_token", "token_type")
    refresh = get(data, "refresh_token", nothing)
    all(field -> nonempty(get(data, field, nothing)), fields) &&
        (isnothing(refresh) || nonempty(refresh)) &&
        lowercase(data["token_type"]) == "bearer" &&
        lifetime(get(data, "expires_in", nothing)) &&
        (!haskey(data, "scope") || data["scope"] isa AbstractString)
end

nonempty(value) = false
nonempty(value::AbstractString) = !isempty(value)
lifetime(value) = false
lifetime(value::Real) = isfinite(value) && value > 0
lifetime(::Bool) = false
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

valid_authorization_client(::Val{:chatgpt}, attempt, client) = !isempty(client) && client != "dynamic_agent_client" && (isempty(attempt.client_id) || client == attempt.client_id)
function authorization_registration(::Val{:chatgpt}, dir)
    saved = load_credentials(dir, :chatgpt)
    registration = isnothing(saved) ? load_credentials(dir, :chatgpt_pending) : saved
    client_id = isnothing(registration) ? "" : get(registration, "client_id", "")
    return (host_id=host_id!(dir), client_id=client_id)
end

function remember_authorization_registration!(::Val{:chatgpt}, dir, flow, attempt, callback)
    if isempty(attempt.client_id)
        persist!(flow, dir, :chatgpt_pending, Dict("client_id" => callback.client_id, "host_id" => attempt.host_id))
    else
        true
    end
end
finish_authorization_registration!(::Val{:chatgpt}, dir::AbstractString) = rm(joinpath(dir, "chatgpt_pending.json"); force=true)

function complete_authorization!(::Val{:chatgpt}, dir, attempt, callback; transport, identity, context, persist)
    verifier = isnothing(identity) ? verify_chatgpt_identity : identity
    body = query_string(["grant_type" => "authorization_code", "client_id" => callback.client_id, "code" => callback.code, "code_verifier" => attempt.verifier, "redirect_uri" => attempt.redirect_uri, "resource" => OPENAI_RESOURCE])
    response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
    200 <= response.status < 300 ? authenticate!(dir, attempt, callback, parse_json(response.body), verifier, persist) : (ok=false, reason=transport_reason(response, "ChatGPT authorization exchange"))
end

function authenticate!(dir, attempt::OAuthAttempt, callback, data, verifier, persist)
    if !valid_token_response(data; require_id=true)
        (ok=false, reason="ChatGPT returned invalid credentials.")
    elseif "chatgpt.tokens.use.direct" in split(data["scope"])
        claims = verifier(data["id_token"], callback.client_id, attempt.nonce)
        connect!(dir, attempt, callback, data, claims, persist)
    else
        (ok=false, reason="ChatGPT plan access was not granted.")
    end
end

function connect!(dir, attempt::OAuthAttempt, callback, data, claims, persist)
    subject = get(claims, "sub", nothing)
    if nonempty(subject)
        previous = load_credentials(dir, :chatgpt)
        if !isempty(attempt.client_id) && !isnothing(previous) && get(previous, "subject", "") != subject
            (ok=false, reason="ChatGPT account did not match the saved account.")
        else
            credentials = Dict("client_id" => callback.client_id, "host_id" => attempt.host_id, "subject" => subject, "email" => get(claims, "email", ""), "access_token" => data["access_token"], "refresh_token" => data["refresh_token"], "id_token" => data["id_token"], "scope" => data["scope"], "expires_at" => time() + data["expires_in"])
            persist(:chatgpt, credentials) ? (ok=true, reason="ChatGPT connected.") : (ok=false, reason="Sign-in cancelled.")
        end
    else
        (ok=false, reason="ChatGPT returned an invalid identity.")
    end
end
function refresh_chatgpt!(dir::AbstractString; transport=auth_request, identity=verify_chatgpt_identity, context=ExecutionContext())
    lock(auth_lock(dir, :chatgpt)) do
        refresh!(dir, load_credentials(dir, :chatgpt), transport, identity, context)
    end
end

refresh!(dir, ::Nothing, transport, identity, context) = (ok=false, reason="Sign in to ChatGPT first.", credentials=nothing)

function refresh!(dir, saved::AbstractDict, transport, identity, context)
    if get(saved, "expires_at", 0) > time() + 60
        (ok=true, reason="", credentials=saved)
    else
        body = query_string(["grant_type" => "refresh_token", "client_id" => saved["client_id"], "refresh_token" => saved["refresh_token"], "resource" => OPENAI_RESOURCE])
        response = transport_request(transport, OPENAI_ISSUER * "/api/accounts/oauth/token", body, ["Content-Type" => "application/x-www-form-urlencoded"], context)
        200 <= response.status < 300 ? refresh!(dir, saved, parse_json(response.body), identity) : (ok=false, reason=transport_reason(response, "ChatGPT token refresh"), credentials=nothing)
    end
end

function refresh!(dir, saved::AbstractDict, data, identity)
    if !valid_token_response(data)
        (ok=false, reason="ChatGPT returned invalid refreshed credentials.", credentials=nothing)
    elseif haskey(data, "id_token") && get(identity(data["id_token"], saved["client_id"], nothing), "sub", "") != saved["subject"]
        (ok=false, reason="ChatGPT account changed during refresh.", credentials=nothing)
    else
        renew!(dir, saved, data)
    end
end

function renew!(dir, saved, data)
    if haskey(data, "id_token")
        saved["id_token"] = data["id_token"]
    end
    scope = get(data, "scope", saved["scope"])
    if "chatgpt.tokens.use.direct" in split(scope)
        saved["access_token"] = data["access_token"]
        saved["refresh_token"] = get(data, "refresh_token", saved["refresh_token"])
        saved["scope"] = scope
        saved["expires_at"] = time() + data["expires_in"]
        save_credentials!(dir, :chatgpt, saved)
        (ok=true, reason="", credentials=saved)
    else
        (ok=false, reason="ChatGPT plan access is no longer granted.", credentials=nothing)
    end
end
