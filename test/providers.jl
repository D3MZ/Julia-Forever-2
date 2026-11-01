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

@testset "Slow model discovery does not serialize independent callers" begin
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    requests = Threads.Atomic{Int}(0)
    model_body = slug -> JSON.json(Dict("models" => [Dict("slug" => slug, "visibility" => "list")]))
    transport = function (url, method, body, headers, context, sink)
        request = Threads.atomic_add!(requests, 1) + 1
        if request == 1
            put!(entered, nothing)
            take!(release)
        end
        return (status=200, body=model_body(request == 1 ? "slow" : "fast"))
    end
    provider = JuliaForever2.OpenAIProvider("unused", transport)
    context = ExecutionContext()
    first = Threads.@spawn JuliaForever2.available_models!(provider, [], context)
    take!(entered)
    @test !islocked(provider.catalog.lock)
    second = Threads.@spawn JuliaForever2.available_models!(provider, [], context)
    completed = timedwait(() -> istaskdone(second), 5.0; pollint=0.01) == :ok
    put!(release, nothing)
    @test completed
    @test fetch(second).models == ["fast"]
    @test fetch(first).models == ["fast"]
    @test JuliaForever2.available_models!(provider, [], context).models == ["fast"]
    @test requests[] == 2
    close(context)
end

@testset "Invalid model discovery payloads do not crash or poison the cache" begin
    payloads = [
        JSON.json(Dict("models" => nothing)),
        JSON.json(Dict("models" => Any[nothing, 42,
            Dict("visibility" => "list", "slug" => "usable-model"),
            Dict("visibility" => "hidden", "slug" => "private-model")])),
    ]
    requests = Ref(0)
    transport = function (url, method, body, headers, context, sink)
        requests[] += 1
        return (status=200, body=payloads[requests[]])
    end
    provider = JuliaForever2.OpenAIProvider("unused", transport)
    context = ExecutionContext()

    invalid = JuliaForever2.available_models!(provider, [], context)
    @test isempty(invalid.models)
    @test invalid.reason == "ChatGPT model discovery returned invalid JSON."

    recovered = JuliaForever2.available_models!(provider, [], context)
    @test recovered.models == ["usable-model"]
    @test recovered.reason == ""
    @test JuliaForever2.available_models!(provider, [], context).models == ["usable-model"]
    @test requests[] == 2
    close(context)
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
                (status=200, body=JSON.json(Dict("models" => [Dict("visibility" => "list", "slug" => "test-model")])))
            else
                write(sink, delta)
                streamed_before_return[] = !isempty(events)
                write(sink, completion)
                (status=200, body="")
            end
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

@testset "Context-aware method transports without a streaming argument" begin
    context = JuliaForever2.ExecutionContext()
    calls = []
    transport = (url, method, body, headers, request_context) -> begin
        push!(calls, (method=method, body=body, context=request_context))
        return (status=200, body="mock response")
    end
    headers = Pair{String,String}[]

    buffered = JuliaForever2.transport_request(transport, "https://example.invalid", "GET", "", headers, context)
    @test buffered.status == 200
    @test buffered.body == "mock response"

    sink = IOBuffer()
    streamed = JuliaForever2.transport_request(transport, "https://example.invalid", "POST", "request", headers, context, sink)
    @test streamed.status == 200
    @test String(take!(sink)) == "mock response"
    @test [call.method for call in calls] == ["GET", "POST"]
    @test [call.body for call in calls] == ["", "request"]
    @test all(call -> call.context === context, calls)
    close(context)
end

@testset "OpenAI streamed text and thinking chunks preserve completed content" begin
    deltas = [isodd(index) ? repeat("Julia answer λ 🚀 ", 10) :
        repeat("model tool output: ", 11) for index in 1:120]
    thinking = [isodd(index) ? "reasoning λ " : "reasoning 🚀 " for index in 1:120]
    frames = ["data: " * JSON.json(Dict("choices" => [
        Dict("delta" => Dict("content" => deltas[index],
            "reasoning_content" => thinking[index]), "finish_reason" => nothing)])) * "\n\n"
        for index in eachindex(deltas)]
    push!(frames, "data: " * JSON.json(Dict("choices" =>
        [Dict("delta" => Dict{String,Any}(), "finish_reason" => "stop")])) * "\n\n")
    transport = (url, method, body, headers, context, decoder) -> begin
        for frame in frames
            write(decoder, frame)
        end
        (status=200, reason="OK")
    end
    events = HarnessEvent[]
    context = ExecutionContext(; event_sink=event -> push!(events, event))
    backend = JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),
        "https://offline.invalid"; transport)
    request = JuliaForever2.ModelRequest([Message(:user, "Generate a long answer")],
        "", nothing, nothing, nothing)
    completion = JuliaForever2.respond_model(backend,
        JuliaForever2.ModelSpec(:synthetic, "test-model"), request, context)
    content = completion.message["content"]
    @test completion.reply == Reply(:answer, join(deltas))
    @test length(content) == 2
    @test content[1]["thinking"] == join(thinking)
    @test content[2]["text"] == join(deltas)
    @test all(block -> block["type"] in ("thinking", "text"), content)
    @test completion.message["stopReason"] == "stop"
    emitted = [event.data for event in events if event.kind == :model_stream]
    @test count(event -> event["type"] == "text_delta", emitted) == length(deltas)
    @test count(event -> event["type"] == "thinking_delta", emitted) == length(thinking)
    @test only(filter(event -> event["type"] == "text_end", emitted))["content"] == join(deltas)
    @test only(filter(event -> event["type"] == "thinking_end", emitted))["content"] == join(thinking)
    @test last(emitted)["type"] == "done"
    close(context)
end

@testset "Buffered model text survives failed and cancelled streams" begin
    frame = "data: " * JSON.json(Dict("choices" => [Dict("delta" => Dict(
        "content" => "partial answer λ", "reasoning_content" => "partial thought 🚀"),
        "finish_reason" => nothing)])) * "\n\n"
    for (status, cancel_request, stop_reason) in ((502, false, "error"),
            (200, true, "aborted"), (0, true, "aborted"))
        events = HarnessEvent[]
        context = ExecutionContext(; event_sink=event -> push!(events, event))
        transport = (url, method, body, headers, request_context, decoder) -> begin
            write(decoder, frame)
            cancel_request && JuliaForever2.cancel!(request_context)
            return (status=status, reason="simulated failure")
        end
        backend = JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),
            "https://offline.invalid"; transport)
        request = JuliaForever2.ModelRequest([Message(:user, "hello")],
            "", nothing, nothing, nothing)
        completion = JuliaForever2.respond_model(backend,
            JuliaForever2.ModelSpec(:synthetic, "test-model"), request, context)
        blocks = Dict(block["type"] => block[block["type"]] for block in completion.message["content"])
        @test blocks == Dict("thinking" => "partial thought 🚀", "text" => "partial answer λ")
        @test completion.message["stopReason"] == stop_reason
        @test completion.reply.kind == :error
        emitted = [event.data["type"] for event in events if event.kind == :model_stream]
        @test last(emitted) == "error"
        @test ("text_end" in emitted) == (status == 200)
        close(context)
    end
end

@testset "OpenAI buffered block finalization is idempotent for short and Unicode deltas" begin
    cases = (
        String[],
        [""],
        ["Hi"],
        ["a", "b", "c"],
        ["λ", "🚀", "中文", "e\u0301"],
        [repeat("x", 255), "λ"],
        [repeat("x", 257)],
    )
    for fragments in cases
        events = HarnessEvent[]
        context = ExecutionContext(; event_sink=event -> push!(events, event))
        state = JuliaForever2.ModelStreamState(
            JuliaForever2.ModelSpec(:test, "buffer-probe"), context)
        JuliaForever2.start_model_stream!(state)
        for fragment in fragments
            JuliaForever2.text_model_block!(state, "text", fragment)
        end

        expected = join(fragments)
        if isempty(expected)
            @test isempty(state.message["content"])
            @test isempty(state.text_buffers)
        else
            @test length(state.message["content"]) == 1
            @test state.message["content"][1]["text"] == ""
            @test haskey(state.text_buffers, 1)
            JuliaForever2.finish_model_block!(state, 1)
            @test state.message["content"][1]["text"] == expected
            @test isempty(state.text_buffers)
            JuliaForever2.finish_model_block!(state, 1)
        end
        state.message["stopReason"] = "stop"
        JuliaForever2.finish_model_stream!(state)
        JuliaForever2.finish_model_stream!(state)
        @test isempty(state.text_buffers)

        emitted = [event.data for event in events if event.kind == :model_stream]
        expected_types = ["start"]
        if !isempty(expected)
            push!(expected_types, "text_start")
            append!(expected_types, fill("text_delta",
                length([fragment for fragment in fragments if !isempty(fragment)])))
            push!(expected_types, "text_end")
            @test only([event["content"] for event in emitted
                if event["type"] == "text_end"]) == expected
        end
        push!(expected_types, "done")
        @test [event["type"] for event in emitted] == expected_types
        @test [event["delta"] for event in emitted
            if event["type"] == "text_delta"] ==
            [fragment for fragment in fragments if !isempty(fragment)]
        close(context)
    end
end

@testset "OpenAI Unicode SSE fragmentation preserves event order and missing-stop errors" begin
    changes = [
        ("reasoning_content", "λ"),
        ("content", "漢字"),
        ("reasoning_content", "🚀"),
        ("content", "e\u0301"),
        ("content", repeat("x", 300)),
        ("reasoning_content", "raison d'être"),
    ]
    frames = ["data: " * JSON.json(Dict("choices" => [
        Dict("delta" => Dict(field => fragment), "finish_reason" => nothing)])) * "\n\n"
        for (field, fragment) in changes]
    finish_frame = "data: " * JSON.json(Dict("choices" => [
        Dict("delta" => Dict{String,Any}(), "finish_reason" => "stop")])) * "\n\n"
    expected_thinking = join(fragment for (field, fragment) in changes
        if field == "reasoning_content")
    expected_answer = join(fragment for (field, fragment) in changes
        if field == "content")

    for has_stop in (true, false)
        wire = join(frames) * (has_stop ? finish_frame : "")
        events = HarnessEvent[]
        context = ExecutionContext(; event_sink=event -> push!(events, event))
        transport = (url, method, body, headers, request_context, decoder) -> begin
            # Fragment inside UTF-8 code points, not just between SSE messages.
            for byte in codeunits(wire)
                write(decoder, byte)
            end
            return (status=200, reason="OK")
        end
        backend = JuliaForever2.HTTPModelBackend(JuliaForever2.OpenAIChatProtocol(),
            "https://offline.invalid"; transport)
        request = JuliaForever2.ModelRequest([Message(:user, "hello")],
            "", nothing, nothing, nothing)
        completion = JuliaForever2.respond_model(backend,
            JuliaForever2.ModelSpec(:test, "buffer-probe"), request, context)
        @test [(block["type"], block[block["type"]])
            for block in completion.message["content"]] ==
            [("thinking", expected_thinking), ("text", expected_answer)]
        @test completion.message["stopReason"] == (has_stop ? "stop" : "error")
        if has_stop
            @test completion.reply == Reply(:answer, expected_answer)
            @test !haskey(completion.message, "errorMessage")
        else
            @test completion.reply.kind == :error
            @test occursin("without finish_reason", completion.message["errorMessage"])
        end

        emitted = [event.data for event in events if event.kind == :model_stream]
        @test [event["type"] for event in emitted] == [
            "start", "thinking_start", "thinking_delta", "text_start", "text_delta",
            "thinking_delta", "text_delta", "text_delta", "thinking_delta",
            "thinking_end", "text_end", has_stop ? "done" : "error"]
        deltas = [event for event in emitted if endswith(event["type"], "_delta")]
        @test [event["delta"] for event in deltas] == last.(changes)
        @test [event["contentIndex"] for event in deltas] == [0, 1, 0, 1, 1, 0]
        @test [event["content"] for event in emitted
            if endswith(event["type"], "_end")] == [expected_thinking, expected_answer]
        close(context)
    end
end

@testset "Streaming tool arguments avoid reparsing incomplete JSON" begin
    @test !JuliaForever2.possible_tool_object("")
    @test !JuliaForever2.possible_tool_object(" \t")
    @test !JuliaForever2.possible_tool_object(raw"""{"text":"unfinished } brace""")
    @test JuliaForever2.possible_tool_object("{\"ok\":true}  \t")
    @test JuliaForever2.possible_tool_object("{\"ok\":true}\u2003")

    fragments = [raw"""{"text":"inside } quoted text","nested":{"ok":""", "true", "}} \t"]
    expected = JSON.parse(join(fragments))
    for protocol in (:openai, :anthropic)
        context = ExecutionContext()
        state = JuliaForever2.ModelStreamState(
            JuliaForever2.ModelSpec(:test, "synthetic-tool-model"), context)
        if protocol == :anthropic
            JuliaForever2.anthropic_block_start!(state,
                Dict("index" => 0, "content_block" => Dict(
                    "type" => "tool_use", "id" => "tool-1", "name" => "perform",
                    "input" => Dict{String,Any}())))
        end
        for (position, fragment) in enumerate(fragments)
            if protocol == :openai
                JuliaForever2.openai_tool_delta!(state, Dict(
                    "index" => 0, "id" => "tool-1",
                    "function" => Dict("name" => "perform", "arguments" => fragment)))
            else
                JuliaForever2.anthropic_block_delta!(state, Dict(
                    "index" => 0, "delta" => Dict(
                        "type" => "input_json_delta", "partial_json" => fragment)))
            end
            @test JuliaForever2.model_tool_argument_text(state.arguments[1]) == join(fragments[1:position])
            arguments = state.message["content"][1]["arguments"]
            if position < length(fragments)
                @test isempty(arguments)
            else
                @test arguments == expected
            end
        end
        JuliaForever2.finish_model_block!(state, 1)
        @test state.message["content"][1]["arguments"] == expected
        close(context)
    end
end

@testset "Large fragmented tool arguments preserve complete values" begin
    text = JSON.json(Dict("payload" => repeat("opaque-1234567890", 900), "nested" => Dict("ok" => true)))
    fragments = [String(text[start:min(start + 96, lastindex(text))]) for start in 1:97:lastindex(text)]
    for protocol in (:openai, :anthropic)
        context = ExecutionContext()
        state = JuliaForever2.ModelStreamState(JuliaForever2.ModelSpec(:test, "large-tool"), context)
        if protocol == :anthropic
            JuliaForever2.anthropic_block_start!(state, Dict("index" => 0,
                "content_block" => Dict("type" => "tool_use", "id" => "id", "name" => "call", "input" => Dict{String,Any}())))
        end
        for fragment in fragments
            if protocol == :openai
                JuliaForever2.openai_tool_delta!(state, Dict("index" => 0, "id" => "id",
                    "function" => Dict("name" => "call", "arguments" => fragment)))
            else
                JuliaForever2.anthropic_block_delta!(state, Dict("index" => 0,
                    "delta" => Dict("type" => "input_json_delta", "partial_json" => fragment)))
            end
        end
        @test JuliaForever2.model_tool_argument_text(state.arguments[1]) == text
        JuliaForever2.finish_model_block!(state, 1)
        @test state.message["content"][1]["arguments"] == JSON.parse(text)
        close(context)
    end
end
