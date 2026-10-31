using JuliaForever2: OpenRouterProvider
using JSON
using Sockets

@testset "OpenRouter protocol" begin
    requests = []
    transport = (url, body, headers) -> begin
        push!(requests, (url, JSON.parse(body), headers))
        (status=200, body=JSON.json(Dict("choices" => [Dict("message" => Dict("content" => JSON.json(Dict("kind" => "answer", "content" => "Hello"))))])))
    end
    provider = OpenRouterProvider("secret", "example/model", transport)
    reply = provider([Message(:user, "Hi")], Session(Kernel()))
    @test reply == Reply(:answer, "Hello")
    @test requests[1][2]["model"] == "example/model"
    @test occursin("Hi", requests[1][2]["messages"][2]["content"])
    @test occursin("install!(kernel, ComponentSpec", requests[1][2]["messages"][1]["content"])
    @test ("Authorization" => "Bearer secret") in requests[1][3]
    failed = OpenRouterProvider("secret", "example/model", (args...) -> (status=401, body="bad"))
    failure = failed([Message(:user, "Hi")], Session(Kernel()))
    @test failure.kind == :error
    @test occursin("401", failure.content)
    @test occursin("key", lowercase(failure.content))
    malformed = OpenRouterProvider("secret", "example/model", (args...) -> (status=200, body=JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "{}"))]))))
    @test malformed([Message(:user, "Hi")], Session(Kernel())).kind == :error
end

@testset "Reported usage appears in session" begin
    body = JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "{\"kind\":\"answer\",\"content\":\"ok\"}"))], "usage" => Dict("prompt_tokens" => 120, "completion_tokens" => 18, "cost" => 0.002)))
    provider = OpenRouterProvider("secret", "example/model", (args...) -> (status=200, body=body))
    session = Session(Kernel())
    provider([Message(:user, "Hi")], session)
    provider([Message(:user, "Hi again")], session)
    @test session.usage.input_tokens == 240
    @test session.usage.output_tokens == 36
    @test session.usage.cost ≈ 0.004
    JuliaForever2.record_usage!(session, nothing)
    @test startswith(JuliaForever2.usage_label(session), "~↑240 ↓36")
    @test !occursin("\$", JuliaForever2.usage_label(session))
end

@testset "Codex subscription model and reasoning" begin
    mktempdir() do dir
        executable = joinpath(dir, "codex")
        arguments = joinpath(dir, "arguments")
        script = """
        #!/bin/sh
        cat > /dev/null
        printf '%s\\n' "\$@" > "\$JF2_CODEX_ARGS"
        while [ "\$#" -gt 0 ]; do
            if [ "\$1" = "-o" ]; then shift; outfile=\$1; fi
            shift
        done
        printf '%s' '{"kind":"answer","content":"ok"}' > "\$outfile"
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":120,"output_tokens":18}}'
        """
        write(executable, script)
        chmod(executable, 0o755)
        withenv("JF2_CODEX_ARGS" => arguments) do
            provider = JuliaForever2.CodexProvider(executable)
            session = Session(Kernel())
            reply = provider([Message(:user, "hello")], session)
            @test reply == Reply(:answer, "ok")
            @test JuliaForever2.usage_label(session) == "↑120 ↓18"
            args = readlines(arguments)
            @test "gpt-6.1-terra" in args
            @test "model_reasoning_effort=\"max\"" in args
            @test "--json" in args
            @test JuliaForever2.provider_detail(provider) == "(openai-codex) gpt-6.1-terra • max"
        end
    end
end

@testset "OpenRouter key sources" begin
    mktempdir() do dir
        env = Dict("OPENROUTER_API_KEY" => "env-key")
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "pi-key", environment=env) == "pi-key"
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "", environment=env) == "env-key"
        JuliaForever2.save_credentials!(dir, :openrouter, Dict("key" => "saved-key"))
        @test JuliaForever2.openrouter_key(dir; pi_key=() -> "pi-key", environment=env) == "saved-key"
    end
end

@testset "Browser credentials take precedence" begin
    mktempdir() do dir
        JuliaForever2.save_credentials!(dir, :openrouter, Dict("key" => "browser-key"))
        withenv("JULIAFOREVER_CONFIG_DIR" => dir, "OPENROUTER_API_KEY" => "environment-key") do
            @test OpenRouterProvider().api_key == "browser-key"
        end
    end
end

@testset "Credentials are not shown when displaying a provider" begin
    provider = OpenRouterProvider("synthetic-secret", "example/model")
    @test !occursin("synthetic-secret", repr(provider))
    @test occursin("example/model", repr(provider))
end

@testset "Transport failures are values" begin
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    close(listener)
    url = "http://127.0.0.1:$port"
    headers = Pair{String,String}[]
    withenv("NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1") do
        responses = (
            JuliaForever2.router_request(url, "{}", headers),
            JuliaForever2.openai_request(url, "POST", "{}", headers),
            JuliaForever2.auth_request(url, "{}", headers),
        )
        @test all(response -> response.status == 0, responses)
        @test all(response -> !isempty(response.reason), responses)
    end
end

@testset "Configuration belongs to each provider" begin
    mktempdir() do directory
        explicit = joinpath(directory, "explicit")
        global_directory = joinpath(directory, "global")
        JuliaForever2.save_provider!(explicit, :chatgpt)
        withenv("JULIAFOREVER_CONFIG_DIR" => global_directory, "CHATGPT_MODEL" => "first-model") do
            provider = JuliaForever2.configured_provider(explicit)
            @test provider.dir == explicit
            withenv("CHATGPT_MODEL" => "other-model") do
                @test provider.model == "first-model"
                @test occursin("first-model", JuliaForever2.provider_detail(provider))
            end
        end
    end
end

@testset "Provider policy and structured conversation compose" begin
    requests = []
    transport = (url, body, headers) -> begin
        push!(requests, JSON.parse(body))
        (status=200, body=JSON.json(Dict("choices" => [Dict("message" => Dict("content" => "{\"kind\":\"answer\",\"content\":\"done\"}"))])))
    end
    policy = JuliaForever2.CodeModePolicy("Custom instructions")
    provider = OpenRouterProvider("synthetic", "test-model", transport; policy)
    messages = [Message(:user, "hello"), Message(:assistant, "1 + 1", :code), Message(:code_result, "2")]
    @test provider(messages, Session(Kernel())) == Reply(:answer, "done")
    conversation = only(requests)["messages"]
    @test [message["role"] for message in conversation] == ["system", "user", "assistant", "user"]
    @test conversation[1]["content"] == "Custom instructions"
    @test JSON.parse(conversation[3]["content"])["kind"] == "code"
    @test JSON.parse(conversation[4]["content"])["kind"] == "code_result"
end

@testset "ChatGPT streams events, reports usage, and caches models" begin
    mktempdir() do directory
        JuliaForever2.save_credentials!(directory, :chatgpt, Dict("access_token" => "synthetic", "expires_at" => time() + 3600))
        catalogs = Ref(0)
        events = []
        streamed_before_return = Ref(false)
        answer = JSON.json(Dict("kind" => "answer", "content" => "streamed"))
        delta = "data: " * JSON.json(Dict("type" => "response.output_text.delta", "delta" => answer)) * "\n\n"
        completion = "data: " * JSON.json(Dict("type" => "response.completed", "response" => Dict("usage" => Dict("input_tokens" => 23, "output_tokens" => 7)))) * "\n\n"
        transport = function (url, method, body, headers, context, sink)
            if method == "GET"
                catalogs[] += 1
                return (status=200, body=JSON.json(Dict("models" => [Dict("visibility" => "list", "slug" => "test-model")])))
            end
            write(sink, delta)
            streamed_before_return[] = !isempty(events)
            write(sink, completion)
            return (status=200, body="")
        end
        provider = JuliaForever2.OpenAIProvider(directory, transport; model="test-model")
        session = Session(Kernel())
        context = JuliaForever2.ExecutionContext(; event_sink=event -> push!(events, event))
        response = JuliaForever2.respond(provider, [Message(:user, "hello")], session, context)
        @test response.reply == Reply(:answer, "streamed")
        @test streamed_before_return[]
        @test response.usage.input_tokens == 23
        @test response.usage.output_tokens == 7
        @test !session.usage.reported
        JuliaForever2.record_usage!(session, response.usage)
        @test session.usage.input_tokens == 23
        @test !session.usage.cost_known
        provider([Message(:user, "again")], session)
        @test session.usage.input_tokens == 46
        @test session.usage.output_tokens == 14
        @test catalogs[] == 1
    end
end

struct RegisteredTestProvider end
JuliaForever2.provider_id(::RegisteredTestProvider) = :registered_test

@testset "Provider registration does not require built-in changes" begin
    directories = String[]
    descriptor = JuliaForever2.ProviderDescriptor(:registered_test, "Registered provider", directory -> (push!(directories, directory); RegisteredTestProvider()); status=Returns("ready"))
    JuliaForever2.register_provider!(descriptor)
    mktempdir() do directory
        JuliaForever2.save_provider!(directory, descriptor.id)
        @test JuliaForever2.configured_provider(directory) isa RegisteredTestProvider
        @test only(directories) == directory
        @test JuliaForever2.provider_descriptor(:registered_test) === descriptor
        @test last(JuliaForever2.provider_descriptors()).id == :registered_test
        @test isnothing(descriptor.auth)
        @test descriptor.status(directory) == "ready"
    end
    JuliaForever2.unregister_provider!(:registered_test)
    @test isnothing(JuliaForever2.provider_descriptor(:registered_test))
    @test isnothing(JuliaForever2.provider_from_name(:unknown_provider))
end

@testset "Cancelled providers do not start transport" begin
    context = JuliaForever2.ExecutionContext()
    JuliaForever2.cancel!(context)
    calls = Ref(0)
    provider = OpenRouterProvider("synthetic", "test-model", (args...) -> (calls[] += 1; (status=200, body="{}")))
    response = JuliaForever2.respond(provider, [Message(:user, "hello")], Session(Kernel()), context)
    @test response.reply.kind == :error
    @test calls[] == 0
end

@testset "Codex cancellation stops its owned subprocess" begin
    mktempdir() do directory
        executable = joinpath(directory, "fake-codex")
        started = joinpath(directory, "started")
        write(executable, "#!/bin/sh\ncat >/dev/null\nprintf '%s' \"\$\$\" > \"\$JF2_TEST_STARTED\"\nexec sleep 20\n")
        chmod(executable, 0o755)
        provider = JuliaForever2.CodexProvider(executable)
        context = JuliaForever2.ExecutionContext()
        session = Session(Kernel())
        withenv("JF2_TEST_STARTED" => started) do
            task = @async JuliaForever2.respond(provider, [Message(:user, "hello")], session, context)
            @test timedwait(() -> isfile(started), 5.0) == :ok
            process_id = strip(read(started, String))
            JuliaForever2.cancel!(context)
            @test timedwait(() -> istaskdone(task), 5.0) == :ok
            @test fetch(task).reply.kind == :error
            probe = run(pipeline(ignorestatus(`kill -0 $process_id`); stdout=devnull, stderr=devnull))
            @test !success(probe)
        end
    end
end

@testset "Downloads delivers stream events before request completion" begin
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    finish = Base.Event()
    server = @async begin
        client = accept(listener)
        while !isempty(strip(readline(client))) end
        write(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        first_chunk = "data: first\n\n"
        write(client, string(ncodeunits(first_chunk); base=16), "\r\n", first_chunk, "\r\n")
        flush(client)
        wait(finish)
        write(client, "0\r\n\r\n")
        close(client)
    end
    events = []
    decoder = JuliaForever2.SSEDecoder(event -> push!(events, event))
    context = JuliaForever2.ExecutionContext(; timeout=5.0)
    withenv("NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1") do
        request = @async JuliaForever2.openai_request("http://127.0.0.1:$port", "GET", "", Pair{String,String}[], context, decoder)
        @test timedwait(() -> !isempty(events), 3.0) == :ok
        @test !istaskdone(request)
        notify(finish)
        @test fetch(request).status == 200
        @test only(events).data == "first"
    end
    wait(server)
    close(listener)
    close(context)
end

@testset "Downloads cancellation interrupts an active request" begin
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    connected = Base.Event()
    finish = Base.Event()
    server = @async begin
        client = accept(listener)
        while !isempty(strip(readline(client))) end
        notify(connected)
        wait(finish)
        close(client)
    end
    context = JuliaForever2.ExecutionContext()
    withenv("NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1") do
        request = @async JuliaForever2.openai_request("http://127.0.0.1:$port", "GET", "", Pair{String,String}[], context)
        wait(connected)
        JuliaForever2.cancel!(context)
        @test timedwait(() -> istaskdone(request), 3.0) == :ok
        notify(finish)
        @test fetch(request).status == 0
    end
    wait(server)
    close(listener)
end

@testset "Success does not cancel later requests sharing a context" begin
    listener = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(listener)[2])
    server = @async for _ in 1:2
        client = accept(listener)
        while !isempty(strip(readline(client))) end
        sleep(0.05)
        write(client, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        close(client)
    end
    context = JuliaForever2.ExecutionContext(; timeout=5.0)
    withenv("NO_PROXY" => "127.0.0.1", "no_proxy" => "127.0.0.1") do
        for _ in 1:2
            response = JuliaForever2.openai_request("http://127.0.0.1:$port", "GET", "", Pair{String,String}[], context)
            @test response.status == 200
            @test response.body == "ok"
            @test !JuliaForever2.cancelled(context)
        end
    end
    wait(server)
    close(listener)
    close(context)
end
