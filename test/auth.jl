using Sockets
using JSON
using JWTs
using JuliaForever2: oauth_attempt, authorization_url, callback_params, finish_callback, save_credentials!, load_credentials, chatgpt_reply, OpenAIProvider

@testset "Codex CLI sign-in" begin
    mktempdir() do dir
        executable = joinpath(dir, "codex")
        write(executable, "#!/bin/sh\necho 'Visit https://example.invalid/login' >&2\n")
        chmod(executable, 0o755)
        urls = String[]
        result = JuliaForever2.codex_sign_in!(JuliaForever2.AuthFlow(), :codex, dir; executable, announce=url -> push!(urls, url))
        @test result.ok
        @test urls == ["https://example.invalid/login"]
        write(executable, "#!/bin/sh\nexec sleep 20\n")
        flow = JuliaForever2.AuthFlow()
        task = @async JuliaForever2.codex_sign_in!(flow, :codex, dir; executable)
        sleep(0.2)
        JuliaForever2.cancel_auth!(flow)
        @test timedwait(() -> istaskdone(task), 5) == :ok
        @test !fetch(task).ok
    end
end

@testset "OAuth state and PKCE" begin
    attempt = oauth_attempt(:chatgpt, "http://127.0.0.1:54321/auth/callback"; host_id="urn:uuid:123")
    url = authorization_url(attempt)
    @test occursin("client_id=dynamic_agent_client", url)
    @test occursin("code_challenge_method=S256", url)
    @test !occursin(attempt.verifier, url)
    @test occursin("ext_agent_host_id=urn%3Auuid%3A123", url)
    good = callback_params("/auth/callback?code=abc&state=$(attempt.state)&client_id=oaiapp_123")
    @test finish_callback(attempt, good).ok
    @test !finish_callback(attempt, callback_params("/auth/callback?code=abc&state=wrong&client_id=oaiapp_123")).ok
    @test !finish_callback(attempt, callback_params("/wrong?code=abc&state=$(attempt.state)&client_id=oaiapp_123")).ok
    @test !finish_callback(attempt, callback_params("/auth/callback?error=access_denied&state=$(attempt.state)")).ok
    @test !finish_callback(attempt, callback_params("/auth/callback?code=abc&state=$(attempt.state)")).ok
    router = oauth_attempt(:openrouter, "http://127.0.0.1:54321/auth/callback")
    @test occursin("code_challenge_method=S256", authorization_url(router))
    @test finish_callback(router, callback_params("/auth/callback?state=$(router.state)&code=abc")).ok
end

@testset "Protected credentials" begin
    mktempdir() do dir
        credentials = Dict("access_token" => "fake-access", "refresh_token" => "fake-refresh")
        save_credentials!(dir, :chatgpt, credentials)
        @test load_credentials(dir, :chatgpt) == credentials
        @test filemode(joinpath(dir, "chatgpt.json")) & 0o077 == 0
        @test load_credentials(dir, :openrouter) === nothing
    end
end

@testset "Credential storage stays within its configured directory" begin
    mktempdir() do root
        directory = joinpath(root, "credentials")
        mkpath(directory)
        outside = joinpath(root, "outside.json")
        write(outside, JSON.json(Dict("access_token" => "outside")))
        @test isnothing(load_credentials(directory, Symbol("../outside")))
        @test_throws ErrorException save_credentials!(directory, Symbol("../outside"),
            Dict("access_token" => "overwritten"))
        @test JSON.parsefile(outside)["access_token"] == "outside"
        @test isnothing(load_credentials(directory, Symbol("nested\\escape")))
        @test_throws ErrorException save_credentials!(directory, Symbol("nested\\escape"),
            Dict("access_token" => "nested"))
        if !Sys.iswindows()
            symlink(outside, joinpath(directory, "linked.json"))
            @test isnothing(load_credentials(directory, :linked))
        end
        save_credentials!(directory, :ordinary, Dict("access_token" => "inside"))
        @test load_credentials(directory, :ordinary)["access_token"] == "inside"
    end
end

@testset "OpenAI stream completion" begin
    events = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
    @test chatgpt_reply(events) == (ok=true, text="hello")
    @test !chatgpt_reply("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n").ok
    @test !chatgpt_reply("data: {\"type\":\"response.failed\"}\n\n").ok
end

@testset "Authorization exchanges" begin
    attempt = oauth_attempt(:chatgpt, "http://127.0.0.1:12345/auth/callback"; host_id="host")
    callback = finish_callback(attempt, callback_params("/auth/callback?state=$(attempt.state)&code=authcode&client_id=oaiapp_123"))
    calls = []
    transport = (url, body, headers) -> begin
        push!(calls, (url, body, headers))
        (status=200, body=JSON.json(Dict("access_token" => "access", "refresh_token" => "refresh", "id_token" => "signed", "expires_in" => 3600, "token_type" => "Bearer", "scope" => "openid chatgpt.tokens.use.direct")))
    end
    identity = (token, client, nonce) -> Dict("sub" => "subject", "email" => "test@example.com")
    mktempdir() do dir
        result = JuliaForever2.complete_authorization!(dir, attempt, callback; transport, identity)
        @test result.ok
        stored = load_credentials(dir, :chatgpt)
        @test stored["client_id"] == "oaiapp_123"
        @test stored["subject"] == "subject"
        @test occursin("code_verifier=$(attempt.verifier)", calls[1][2])
        @test !occursin("dynamic_agent_client", calls[1][2])
    end
    denied = (url, body, headers) -> (status=401, body="bad")
    mktempdir() do dir
        @test !JuliaForever2.complete_authorization!(dir, attempt, callback; transport=denied, identity).ok
        @test isnothing(load_credentials(dir, :chatgpt))
    end
    router = oauth_attempt(:openrouter, "http://127.0.0.1:12345/auth/callback")
    cb = finish_callback(router, callback_params("/auth/callback?state=$(router.state)&code=code"))
    mktempdir() do dir
        request = Ref("")
        exchange = (url, body, headers) -> begin
            request[] = body
            (status=200, body=JSON.json(Dict("key" => "router-secret")))
        end
        @test JuliaForever2.complete_authorization!(dir, router, cb; transport=exchange).ok
        @test load_credentials(dir, :openrouter)["key"] == "router-secret"
        @test JSON.parse(request[])["code_verifier"] == router.verifier
    end
end

@testset "Refresh and ChatGPT provider" begin
    mktempdir() do dir
        save_credentials!(dir, :chatgpt, Dict("client_id" => "oaiapp", "subject" => "subject", "access_token" => "old", "refresh_token" => "old-refresh", "scope" => "chatgpt.tokens.use.direct", "expires_at" => 0))
        calls = []
        auth = (url, body, headers) -> begin
            push!(calls, body)
            (status=200, body=JSON.json(Dict("access_token" => "new", "refresh_token" => "new-refresh", "expires_in" => 3600, "token_type" => "Bearer")))
        end
        response = JuliaForever2.refresh_chatgpt!(dir; transport=auth)
        @test response.ok
        @test response.credentials["access_token"] == "new"
        @test load_credentials(dir, :chatgpt)["refresh_token"] == "new-refresh"
        @test occursin("client_id=oaiapp", calls[1])
        requests = []
        transport = (url, method, body, headers) -> begin
            push!(requests, (url, method, body, headers))
            if method == "GET"
                return (status=200, body=JSON.json(Dict("models" => [Dict("visibility" => "list", "slug" => "test-model")])))
            end
            answer = JSON.json(Dict("kind" => "answer", "content" => "Hello"))
            stream = "data: " * JSON.json(Dict("type" => "response.output_text.delta", "delta" => answer)) * "\n\ndata: {\"type\":\"response.completed\"}\n\n"
            return (status=200, body=stream)
        end
        provider = OpenAIProvider(dir, transport, auth)
        result = provider([Message(:user, "Hi")], Session(Kernel()))
        @test result == Reply(:answer, "Hello")
        @test requests[1][2] == "GET"
        body = JSON.parse(requests[2][3])
        @test body["model"] == "test-model"
        @test body["stream"] && !body["store"]
        @test ("Authorization" => "Bearer new") in requests[2][4]
    end
end

@testset "Loopback authorization" begin
    mktempdir() do dir
        flow = JuliaForever2.AuthFlow()
        sent = Ref(false)
        opener = url -> begin
            params = callback_params("/auth?" * split(url, '?'; limit=2)[2]).values
            callback = params["callback_url"]
            port = parse(Int, match(r"127\.0\.0\.1:(\d+)", callback).captures[1])
            @async begin
                for state in ("incorrect", params["state"])
                    socket = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
                    write(socket, "GET /auth/callback?state=$state&code=synthetic HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                    read(socket, String)
                    close(socket)
                end
                sent[] = true
            end
            true
        end
        transport = (url, body, headers) -> (status=200, body=JSON.json(Dict("key" => "synthetic-key")))
        result = JuliaForever2.sign_in!(flow, :openrouter, dir; opener, transport, timeout=5.0)
        @test result.ok
        @test load_credentials(dir, :openrouter)["key"] == "synthetic-key"
        @test flow.listener === nothing
    end
    mktempdir() do dir
        flow = JuliaForever2.AuthFlow()
        opener = url -> JuliaForever2.cancel_auth!(flow)
        result = JuliaForever2.sign_in!(flow, :openrouter, dir; opener, timeout=1.0)
        @test !result.ok
        @test isnothing(load_credentials(dir, :openrouter))
    end
end

@testset "ChatGPT identity validation" begin
    executable = Sys.which("openssl")
    if isnothing(executable)
        @test_skip false
    else
        mktempdir() do dir
            keyfile = joinpath(dir, "synthetic.pem")
            run(pipeline(`$executable genrsa -out $keyfile 2048`, stdout=devnull, stderr=devnull))
            signing_key = JWTs.JWKRSA("RS256", JWTs.parse_keyfile(keyfile))
            keys = JWTs.JWKSet(Any[])
            keys.keys["synthetic"] = signing_key
            claims = Dict("iss" => "https://auth.openai.com", "sub" => "subject", "aud" => "client", "exp" => Int(floor(time())) + 300, "nonce" => "nonce")
            jwt = JWTs.JWT(; payload=claims)
            JWTs.sign!(jwt, signing_key, "synthetic")
            token = string(jwt)
            @test JuliaForever2.verify_chatgpt_identity(token, "client", "nonce"; keyset=keys)["sub"] == "subject"
            @test_throws Exception JuliaForever2.verify_chatgpt_identity(token, "wrong", "nonce"; keyset=keys)
            @test_throws Exception JuliaForever2.verify_chatgpt_identity(token, "client", "wrong"; keyset=keys)
            parts = split(token, '.')
            parts[3] = (parts[3][1] == 'A' ? "B" : "A") * parts[3][2:end]
            @test_throws Exception JuliaForever2.verify_chatgpt_identity(join(parts, '.'), "client", "nonce"; keyset=keys)
        end
    end
end

@testset "Authorization does not replace valid credentials on failure" begin
    mktempdir() do dir
        original = Dict("client_id" => "oaiapp_old", "subject" => "old-subject", "access_token" => "old", "refresh_token" => "old-refresh", "scope" => "chatgpt.tokens.use.direct", "expires_at" => 0)
        save_credentials!(dir, :chatgpt, original)
        attempt = oauth_attempt(:chatgpt, "http://127.0.0.1:12345/auth/callback"; host_id="host", client_id="oaiapp_old")
        @test !finish_callback(attempt, callback_params("/auth/callback?state=$(attempt.state)&code=x&client_id=oaiapp_other")).ok
        @test !finish_callback(attempt, callback_params("/auth/callback?state=$(attempt.state)&state=other&code=x")).ok
        callback = finish_callback(attempt, callback_params("/auth/callback?state=$(attempt.state)&code=x"))
        response = JSON.json(Dict("access_token" => "new", "refresh_token" => "new-refresh", "id_token" => "signed", "expires_in" => 3600, "token_type" => "Bearer", "scope" => "openid chatgpt.tokens.use.direct"))
        transport = (url, body, headers) -> (status=200, body=response)
        different_identity = (token, client, nonce) -> Dict("sub" => "different")
        @test !JuliaForever2.complete_authorization!(dir, attempt, callback; transport, identity=different_identity).ok
        @test load_credentials(dir, :chatgpt) == original
        @test !JuliaForever2.refresh_chatgpt!(dir; transport, identity=different_identity).ok
        @test load_credentials(dir, :chatgpt) == original
        @test JuliaForever2.host_id!(dir) == JuliaForever2.host_id!(dir)
    end
end

@testset "Invalid token responses are rejected" begin
    attempt = oauth_attempt(:chatgpt, "http://127.0.0.1:12345/auth/callback"; host_id="host")
    callback = finish_callback(attempt, callback_params("/auth/callback?state=$(attempt.state)&code=x&client_id=oaiapp"))
    identity = (token, client, nonce) -> Dict("sub" => "subject")
    mktempdir() do dir
        for change in (Dict("token_type" => "Basic"), Dict("expires_in" => -1), Dict("access_token" => ""))
            data = merge(Dict("access_token" => "access", "refresh_token" => "refresh", "id_token" => "signed", "expires_in" => 3600, "token_type" => "Bearer", "scope" => "openid chatgpt.tokens.use.direct"), change)
            transport = (url, body, headers) -> (status=200, body=JSON.json(data))
            @test !JuliaForever2.complete_authorization!(dir, attempt, callback; transport, identity).ok
            @test isnothing(load_credentials(dir, :chatgpt))
        end
    end
end

@testset "ChatGPT registration survives an exchange failure" begin
    mktempdir() do dir
        seen_clients = String[]
        opener = url -> begin
            params = callback_params("/auth?" * split(url, '?'; limit=2)[2]).values
            push!(seen_clients, params["client_id"])
            port = parse(Int, match(r"127\.0\.0\.1:(\d+)", params["redirect_uri"]).captures[1])
            client_param = params["client_id"] == "dynamic_agent_client" ? "&client_id=oaiapp_retry" : ""
            @async begin
                socket = Sockets.connect(Sockets.IPv4("127.0.0.1"), port)
                write(socket, "GET /auth/callback?state=$(params["state"])&code=synthetic$client_param HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                read(socket, String)
                close(socket)
            end
            true
        end
        failed = (url, body, headers) -> (status=400, body="invalid_grant")
        identity = (token, client, nonce) -> Dict("sub" => "subject")
        @test !JuliaForever2.sign_in!(JuliaForever2.AuthFlow(), :chatgpt, dir; opener, transport=failed, identity, timeout=5.0).ok
        @test load_credentials(dir, :chatgpt_pending)["client_id"] == "oaiapp_retry"
        @test isnothing(load_credentials(dir, :chatgpt))
        body = JSON.json(Dict("access_token" => "access", "refresh_token" => "refresh", "id_token" => "signed", "expires_in" => 3600, "token_type" => "Bearer", "scope" => "openid chatgpt.tokens.use.direct"))
        success = (url, request, headers) -> (status=200, body=body)
        @test JuliaForever2.sign_in!(JuliaForever2.AuthFlow(), :chatgpt, dir; opener, transport=success, identity, timeout=5.0).ok
        @test seen_clients == ["dynamic_agent_client", "oaiapp_retry"]
        @test isnothing(load_credentials(dir, :chatgpt_pending))
        @test load_credentials(dir, :chatgpt)["client_id"] == "oaiapp_retry"
    end
end

@testset "Authorization secrets are not displayed" begin
    attempt = oauth_attempt(:chatgpt, "http://127.0.0.1:12345/auth/callback"; host_id="host")
    @test !occursin(attempt.verifier, repr(attempt))
    @test !occursin(attempt.nonce, repr(attempt))
    @test !occursin(attempt.state, repr(attempt))
end

@testset "SSE framing survives chunks, Unicode, and multiline data" begin
    events = []
    decoder = JuliaForever2.SSEDecoder(event -> push!(events, event))
    bytes = codeunits("\ufeff: comment\r\nevent: example\r\nid: 7\r\ndata: α\r\ndata: β\r\n\r\n")
    for byte in bytes
        write(decoder, byte)
    end
    @test length(events) == 1
    @test events[1].event == "example"
    @test events[1].id == "7"
    @test events[1].data == "α\nβ"
    write(decoder, "data: incomplete")
    @test length(events) == 1
    partial = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\ndata: {\"type\":\"response.completed\"}"
    @test !chatgpt_reply(partial).ok
    multiline = "data: {\"type\":\"response.output_text.delta\",\n" *
        "data: \"delta\":\"hello\"}\n\ndata: {\"type\":\"response.completed\"}\n\n"
    @test chatgpt_reply(multiline) == (ok=true, text="hello")
end

@testset "SSE bulk writes preserve every byte boundary and field rule" begin
    wire = "\ufeff: comment\r\nevent: custom\r\nid: 7\r\ndata: α:β\r\ndata:  second\r\n\r\n" *
        "event: ignored\n\nunknown: discarded\ndata\n\n" *
        "id: bad\0id\rdata:  spaced\r\rid:\ndata:reset\n\ndata: incomplete"
    bytes = collect(codeunits(wire))
    expected = [("custom", "α:β\n second", "7"), ("message", "", "7"),
        ("message", " spaced", "7"), ("message", "reset", "")]
    for boundary in 0:length(bytes)
        events = JuliaForever2.SSEEvent[]
        decoder = JuliaForever2.SSEDecoder(event -> push!(events, event))
        @test write(decoder, String(bytes[1:boundary])) == boundary
        @test write(decoder, "") == 0
        @test write(decoder, String(bytes[(boundary + 1):end])) == length(bytes) - boundary
        @test [(event.event, event.data, event.id) for event in events] == expected
        write(decoder, "\n\n")
        @test last(events).data == "incomplete"
        @test [(event.event, event.data, event.id) for event in events[1:4]] == expected
    end

    for chunk_size in (1, 2, 3, 7, 64, 1024)
        events = JuliaForever2.SSEEvent[]
        decoder = JuliaForever2.SSEDecoder(event -> push!(events, event))
        for start in 1:chunk_size:length(bytes)
            write(decoder, String(bytes[start:min(start + chunk_size - 1, end)]))
        end
        @test [(event.event, event.data, event.id) for event in events] == expected
        @test isopen(decoder) && iswritable(decoder)
        @test isnothing(flush(decoder))
    end
end

@testset "Refresh keeps the token when rotation is omitted" begin
    mktempdir() do directory
        save_credentials!(directory, :chatgpt, Dict("client_id" => "client", "subject" => "subject", "access_token" => "old", "refresh_token" => "keep-refresh", "scope" => "chatgpt.tokens.use.direct", "expires_at" => 0))
        transport = (url, body, headers) -> (status=200, body=JSON.json(Dict("access_token" => "new", "expires_in" => 3600, "token_type" => "Bearer")))
        result = JuliaForever2.refresh_chatgpt!(directory; transport)
        @test result.ok
        @test result.credentials["refresh_token"] == "keep-refresh"
        @test load_credentials(directory, :chatgpt)["access_token"] == "new"
        @test JuliaForever2.auth_lock(directory, :chatgpt) === JuliaForever2.auth_lock(directory, :chatgpt)
        @test JuliaForever2.auth_lock(directory, :chatgpt) !== JuliaForever2.auth_lock(directory, :openrouter)
        @test JuliaForever2.auth_lock(directory, :chatgpt) !== JuliaForever2.auth_lock(joinpath(directory, "other"), :chatgpt)
    end
end
