"""Generate an independent 256-bit capability from the operating system random source."""
web_secret() = bytes2hex(rand(RandomDevice(), UInt8, 32))
web_digest(value::AbstractString) = sha256(codeunits(value))

"""Compare fixed-length capability hashes without a content-dependent early exit."""
function web_equal(left::AbstractVector{UInt8}, right::AbstractVector{UInt8})
    mismatch = UInt8(0)
    for index in eachindex(left)
        mismatch |= left[index] ⊻ right[index]
    end
    mismatch == 0
end

mutable struct WebAccess
    invitation::Vector{UInt8}
    cookie::String
    cookie_digest::Vector{UInt8}
    lock::ReentrantLock
    redeemed::Bool
    revoked::Bool
    origin::String
    expires_at::Float64
    deadline::UInt64
    browser_only::Bool
    local_bearer::String
end

function WebAccess(token::String; public_origin="", lifetime=86400, browser_only=!isempty(public_origin))
    origin = String(public_origin)
    if isempty(token) || !isempty(origin) && ncodeunits(token) < 32
        error("Web invitation requires at least 32 characters of random entropy")
    elseif !(lifetime isa Real && 0 < lifetime <= 86400 && isfinite(lifetime))
        error("Web lifetime must be positive and at most 24 hours")
    elseif !isempty(origin) && isnothing(match(r"\Ahttps://[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?\z", origin))
        error("Remote Web requires one exact HTTPS origin without a path")
    elseif !isempty(origin) && !browser_only
        error("Remote Web requires browser-only access; invitations are never bearer tokens")
    else
        cookie = web_secret()
        WebAccess(web_digest(token), cookie, web_digest(cookie), ReentrantLock(), false, false,
            origin, time() + lifetime, time_ns() + UInt64(round(lifetime * 1e9)), browser_only, browser_only ? "" : token)
    end
end

web_access_alive(access::WebAccess) = !access.revoked && time_ns() < access.deadline && time() < access.expires_at
web_cookie_name(access::WebAccess) = isempty(access.origin) ? "juliaforever2_session" : "__Host-jf2_session"

function revoke_web_access!(access::WebAccess)
    lock(access.lock) do
        access.revoked = true
        access.cookie = ""
    end
    nothing
end

"""Spend the invitation atomically; a second browser can never obtain the session cookie."""
function redeem_web_access!(access::WebAccess, credential::AbstractString)
    lock(access.lock) do
        accepted = web_access_alive(access) && !access.redeemed &&
            web_equal(access.invitation, web_digest(credential))
        access.redeemed |= accepted
        accepted
    end
end

function web_session_cookie(access::WebAccess, request::HTTP.Request)
    prefix = web_cookie_name(access) * "="
    values = [strip(part)[length(prefix)+1:end] for part in split(HTTP.header(request, "Cookie"), ';')
        if startswith(strip(part), prefix)]
    lock(access.lock) do
        web_access_alive(access) && access.redeemed && length(values) == 1 &&
            web_equal(access.cookie_digest, web_digest(only(values)))
    end
end

function web_cookie(access::WebAccess; clear=false)
    remaining = clear ? 0 : max(0, floor(Int, access.expires_at - time()))
    value = clear ? "" : access.cookie
    "$(web_cookie_name(access))=$value; Path=/; HttpOnly; SameSite=Strict; Max-Age=$remaining" *
        (isempty(access.origin) ? "" : "; Secure")
end

"""Pin the external authority and scheme; forwarded headers never establish trust."""
function trusted_remote_web_request(access::WebAccess, request::HTTP.Request)
    host = HTTP.header(request, "Host")
    origin = HTTP.header(request, "Origin")
    fetch_site = lowercase(HTTP.header(request, "Sec-Fetch-Site"))
    isempty(HTTP.header(request, "Authorization")) && host == access.origin[9:end] &&
        (isempty(origin) || origin == access.origin) &&
        fetch_site in ("", "none", "same-origin")
end

function browser_mutation(request::HTTP.Request, access::WebAccess)
    expected = isempty(access.origin) ? nothing : access.origin
    origin = HTTP.header(request, "Origin")
    HTTP.header(request, "X-JuliaForever2-Request") == "1" &&
        (isnothing(expected) ? !isempty(origin) && web_same_origin(web_authority(HTTP.header(request, "Host")), origin) : origin == expected)
end

function web_join_page()
    page = response(200, read(joinpath(WEB_ASSET_DIRECTORY, "join.html"), String), "text/html; charset=utf-8")
    HTTP.setheader(page, "Content-Security-Policy" => "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
    HTTP.setheader(page, "X-Frame-Options" => "DENY")
    page
end

function authorize_web_request(controller, access::WebAccess, handler, request::HTTP.Request, request_trust)
    unique_headers = all(name -> count(pair -> lowercase(first(pair)) == name, request.headers) <= 1,
        ("host", "origin", "cookie", "authorization", "sec-fetch-site", "x-juliaforever2-request"))
    trusted = unique_headers && (isempty(access.origin) ? Base.invokelatest(request_trust, request) : trusted_remote_web_request(access, request))
    if !trusted
        response(403, "{\"error\":\"Untrusted request authority or origin\"}")
    elseif !lock(() -> web_access_alive(access), access.lock)
        cancel_web_turns!(controller)
        response(401, "{\"error\":\"This private session has expired or was revoked\"}")
    else
        authorize_trusted_web_request(controller, access, handler, request)
    end
end

function authorize_trusted_web_request(controller, access::WebAccess, handler, request::HTTP.Request)
    uri = HTTP.URI(String(request.target))
    path = uri.path
    if request.method == "GET" && path == "/join"
        web_join_page()
    elseif request.method == "GET" && path == "/join.js"
        response(200, read(joinpath(WEB_ASSET_DIRECTORY, "join.js"), String), "text/javascript; charset=utf-8")
    elseif request.method == "GET" && path == "/join.css"
        response(200, read(joinpath(WEB_ASSET_DIRECTORY, "join.css"), String), "text/css; charset=utf-8")
    elseif request.method == "POST" && path == "/auth/redeem"
        credential = String(request.body)
        if !browser_mutation(request, access)
            response(403, "{\"error\":\"Claim from the invitation page\"}")
        elseif ncodeunits(credential) > 512 || !redeem_web_access!(access, credential)
            response(410, "{\"error\":\"Invitation expired or already claimed\"}")
        else
            result = response(200, "{\"claimed\":true}")
            HTTP.setheader(result, "Set-Cookie" => web_cookie(access))
            result
        end
    elseif web_session_cookie(access, request)
        if request.method in ("POST", "PUT", "PATCH", "DELETE") && !browser_mutation(request, access)
            response(403, "{\"error\":\"Same-origin browser request required\"}")
        elseif request.method == "POST" && path == "/auth/logout"
            revoke_web_access!(access)
            cancel_web_turns!(controller)
            result = response(200, "{\"revoked\":true}")
            HTTP.setheader(result, "Set-Cookie" => web_cookie(access; clear=true))
            result
        elseif request.method == "GET" && path == "/api/access"
            response(200, JSON.json(Dict("expiresAt" => access.expires_at, "remote" => !isempty(access.origin))))
        else
            if !access.browser_only && handler !== web_request
                HTTP.setheader(request, "Authorization" => "Bearer $(access.local_bearer)")
                Base.invokelatest(handler, controller.api, access.local_bearer, request)
            else
                browser_route(controller, request, path)
            end
        end
    elseif !access.browser_only && startswith(HTTP.header(request, "Authorization"), "Bearer ") &&
            web_equal(access.invitation, web_digest(HTTP.header(request, "Authorization")[8:end]))
        Base.invokelatest(handler, controller.api, access.local_bearer, request)
    else
        response(401, "{\"error\":\"Open your one-time invitation in this browser\"}")
    end
end

Base.show(io::IO, access::WebAccess) = print(io, "WebAccess(redeemed=", access.redeemed,
    ", revoked=", access.revoked, ", capability=<redacted>)")
Base.show(io::IO, ::MIME"text/plain", access::WebAccess) = show(io, access)
