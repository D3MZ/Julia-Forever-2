using JuliaForever2: default_kernel, append_message!, clear_history!, replace_message!,
    ProviderDescriptor, register_provider!, unregister_provider!, ExecutionResult
using Tachikoma
using CommonMark
import Tachikoma: update!

const Terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const App = Terminal.App

struct RegisteredTerminalProvider
    directory::String
end
JuliaForever2.provider_id(::RegisteredTerminalProvider) = :terminal_test

function finish_ui_operation!(app; timeout=5)
    timedwait(timeout; pollint=0.01) do
        while isready(app.queue.channel)
            update!(app, take!(app.queue.channel))
        end
        !app.busy
    end
end

mktempdir() do terminal_configuration
withenv("JULIAFOREVER_CONFIG_DIR" => terminal_configuration, "OPENROUTER_API_KEY" => "") do

@testset "Terminal navigation" begin
    app = App(default_kernel())
    update!(app, KeyEvent('/'))
    @test app.menu == true
    update!(app, KeyEvent(:enter))
    @test app.page == :settings
    update!(app, KeyEvent(:escape))
    @test app.page == :chat
    update!(app, KeyEvent('/'))
    update!(app, KeyEvent(:down))
    update!(app, KeyEvent(:enter))
    @test app.page == :components
    update!(app, KeyEvent(:escape))
    @test app.page == :chat
end

@testset "Conversation presentation" begin
    app = App(default_kernel())
    app.directory = "test-project (main)"
    append_message!(app.session, Message(:user, "My favorite fruit is mango."))
    append_message!(app.session, Message(:assistant, "Mango is a great choice."))
    append_message!(app.session, Message(:code_result, "Julia output"))
    tb = TestBackend(80, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    user = find_text(tb, "My favorite fruit is mango.")
    answer = find_text(tb, "Mango is a great choice.")
    @test !isnothing(user) && !isnothing(answer)
    @test Tachikoma.style_at(tb, user.x, user.y).bg == Tachikoma.ColorRGB(33, 59, 73)
    @test Tachikoma.style_at(tb, 1, user.y).bg == Tachikoma.ColorRGB(33, 59, 73)
    @test Tachikoma.style_at(tb, answer.x, answer.y).bg != Tachikoma.ColorRGB(33, 59, 73)
    output = find_text(tb, "Julia output")
    @test Tachikoma.style_at(tb, output.x, output.y).bg == Tachikoma.ColorRGB(37, 65, 49)
    @test isnothing(find_text(tb, "You")) && isnothing(find_text(tb, "Agent"))
    @test answer.y - user.y == 3
    @test !isnothing(find_text(tb, app.directory))
    @test !isnothing(find_text(tb, "(demo) offline"))
    app.session.usage.input_tokens = 120
    app.session.usage.output_tokens = 18
    app.session.usage.reported = true
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    usage = find_text(tb, "↑120 ↓18")
    provider = find_text(tb, "(demo) offline")
    @test !isnothing(usage) && !isnothing(provider) && usage.y == provider.y && usage.x < provider.x
end

@testset "Code-mode presentation" begin
    app = App(default_kernel())
    append_message!(app.session, Message(:assistant, "println(42)", :code))
    append_message!(app.session, Message(:code_result, "RESULT_42"))
    tb = TestBackend(80, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    code = find_text(tb, "println(42)")
    result = find_text(tb, "RESULT_42")
    @test !isnothing(code) && !isnothing(result)
    @test Tachikoma.style_at(tb, code.x, code.y).bg == Tachikoma.ColorRGB(37, 65, 49)
    @test Tachikoma.style_at(tb, 1, code.y + 1).bg == Tachikoma.ColorRGB(37, 65, 49)
    @test Tachikoma.style_at(tb, result.x, result.y).bg == Tachikoma.ColorRGB(37, 65, 49)
end

@testset "Assistant Markdown presentation" begin
    app = App(default_kernel())
    append_message!(app.session, Message(:assistant, "# Heading\n\nPlain **bold** and `code`.\n\n```julia\n" * repeat("x", 40) * "\n```"))
    tb = TestBackend(24, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    heading = find_text(tb, "Heading")
    bold = find_text(tb, "bold")
    @test !isnothing(heading) && !isnothing(bold)
    @test Tachikoma.style_at(tb, heading.x, heading.y).fg == Tachikoma.ColorRGB(205, 154, 34)
    @test Tachikoma.style_at(tb, bold.x, bold.y).bold
    @test isnothing(find_text(tb, "**")) && isnothing(find_text(tb, "```"))
    code = filter(line -> line[2] == :markdown, app.transcript_lines)
    @test all(sum((textwidth(span.content) for span in line[1]); init=0) <= 22 for line in code)
    cached = app.transcript_lines
    cached_chunks = copy(app.transcript_chunks)
    Tachikoma.view(app, frame)
    @test app.transcript_lines === cached
    append_message!(app.session, Message(:assistant, "Additional response"))
    Tachikoma.view(app, frame)
    @test app.transcript_lines === cached
    @test app.transcript_chunks[1] === cached_chunks[1]
    @test !isnothing(find_text(tb, "Additional response"))
end

@testset "Terminal rendering" begin
    app = App(default_kernel())
    tb = TestBackend(80, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    @test isnothing(find_text(tb, "JULIA FOREVER"))
    @test Tachikoma.char_at(tb, 1, 20) == '─'
    @test Tachikoma.char_at(tb, 1, 22) == '─'
    @test Tachikoma.style_at(tb, 1, 20).fg == Tachikoma.ColorRGB(151, 118, 229)
    update!(app, KeyEvent('/'))
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    menu = find_text(tb, "→ settings")
    input = find_text(tb, "/")
    @test !isnothing(menu) && !isnothing(input) && menu.y > input.y
    update!(app, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    @test !isnothing(find_text(tb, "> Provider"))
    @test !isnothing(find_text(tb, "OpenRouter"))
end

@testset "Command filtering and history" begin
    app = App(default_kernel())
    for c in "/set"
        update!(app, KeyEvent(c))
    end
    @test app.menu
    @test first(Terminal.matching_commands(app))[1] == "settings"
    update!(app, KeyEvent(:enter))
    @test app.page == :settings
    update!(app, KeyEvent(:escape))
    for i in 1:30
        append_message!(app.session, Message(:assistant, "line $i"))
    end
    update!(app, KeyEvent(:pageup))
    @test app.scroll > 0
end

@testset "Mouse selection" begin
    app = App(default_kernel())
    tb = TestBackend(80, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    update!(app, KeyEvent('/'))
    Tachikoma.view(app, frame)
    pos = find_text(tb, "→ settings")
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test app.page == :settings
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    pos = find_text(tb, "OpenRouter")
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test app.page == :chat
    @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.OpenRouterProvider
end

@testset "Wrapping and compact terminal layout" begin
    text = "Hello 你好 cafe\u0301 and a verylongword"
    lines = Terminal.wrap_conversation_line(text, 8)
    @test join(lines) == text
    @test all(textwidth(line) <= 8 for line in lines)
    @test any(occursin("cafe\u0301", line) for line in lines)
    @test Terminal.wrap_conversation_line("", 8) == [""]

    app = App(default_kernel())
    update!(app, KeyEvent('/'))
    for _ in 1:4
        update!(app, KeyEvent(:down))
    end
    tb = TestBackend(40, 8)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    pos = find_text(tb, "→ quit")
    @test !isnothing(pos)
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test app.quit

    for (width, height) in ((5, 5), (12, 6), (20, 10), (100, 30))
        backend = TestBackend(width, height)
        compact = Tachikoma.Frame(backend.buf, backend.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(App(default_kernel()), compact)
    end

    app = App(default_kernel())
    app.page = :settings
    app.selected = 4
    small = TestBackend(40, 8)
    frame = Tachikoma.Frame(small.buf, small.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    pos = find_text(small, "→ ChatGPT / Codex")
    @test !isnothing(pos)
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.CodexProvider
end

@testset "Provider selection persists" begin
    mktempdir() do dir
        app = App(default_kernel(); settings_dir=dir)
        @test JuliaForever2.configured_provider(dir) isa JuliaForever2.DemoProvider
        app.page = :settings
        app.selected = 4
        update!(app, KeyEvent(:enter))
        @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.CodexProvider
        @test JuliaForever2.configured_provider(dir) isa JuliaForever2.CodexProvider
        Terminal.command!(app, "settings")
        @test app.selected == 4
        @test stat(joinpath(dir, "provider")).mode & 0o777 == 0o600
        write(joinpath(dir, "provider"), "unknown")
        @test isnothing(JuliaForever2.configured_provider(dir))
        unavailable = Terminal.terminal_app(; settings_dir=dir)
        @test unavailable.page == :settings
        @test isnothing(component(unavailable.session.kernel, :provider))
        @test occursin("unavailable", unavailable.status)
    end
end

@testset "Replaceable terminal input" begin
    app = App(default_kernel())
    install!(app.session.kernel, ComponentSpec(:input, (app, event) -> (app.status = "custom input")))
    update!(app, KeyEvent('x'))
    @test app.status == "custom input"
end

@testset "Provider sign-in controls" begin
    app = App(default_kernel())
    update!(app, KeyEvent('/'))
    update!(app, KeyEvent(:enter))
    update!(app, KeyEvent(:down))
    @test app.selected == 2
    update!(app, KeyEvent(:enter))
    @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.OpenAIProvider
    @test occursin("sign in", lowercase(app.status))
end

@testset "Account status is visible without credentials" begin
    mktempdir() do dir
        JuliaForever2.save_credentials!(dir, :chatgpt, Dict("email" => "example@example.com", "access_token" => "never-display-this"))
        withenv("JULIAFOREVER_CONFIG_DIR" => dir) do
            app = App(default_kernel())
            app.page = :settings
            tb = TestBackend(100, 24)
            frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
            Tachikoma.view(app, frame)
            @test !isnothing(find_text(tb, "example@example.com"))
            @test isnothing(find_text(tb, "never-display-this"))
        end
    end
end

@testset "Sign-in updates the terminal" begin
    mktempdir() do dir
        withenv("JULIAFOREVER_CONFIG_DIR" => dir) do
            app = App(default_kernel(); settings_dir=dir)
            app.page = :settings
            action = (flow, provider, storage; announce) -> begin
                announce("https://example.invalid/authorize")
                JuliaForever2.save_credentials!(storage, :openrouter, Dict("key" => "synthetic-key"))
                (ok=true, reason="OpenRouter connected.")
            end
            Terminal.start_sign_in!(app, :openrouter; action)
            @test timedwait(() -> isready(app.queue.channel), 5) == :ok
            update!(app, take!(app.queue.channel))
            @test app.auth_url == "https://example.invalid/authorize"
            @test timedwait(() -> isready(app.queue.channel), 5) == :ok
            update!(app, take!(app.queue.channel))
            @test app.page == :settings
            @test !app.busy
            @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.OpenRouterProvider
            @test JuliaForever2.configured_provider(dir) isa JuliaForever2.OpenRouterProvider
            @test app.status == "OpenRouter connected."
            codex_action = (flow, provider, storage; announce) -> (ok=true, reason="ChatGPT / Codex connected.")
            Terminal.start_sign_in!(app, :codex; action=codex_action)
            @test timedwait(() -> isready(app.queue.channel), 5) == :ok
            update!(app, take!(app.queue.channel))
            @test !app.busy && app.page == :settings
            @test component(app.session.kernel, :provider) isa JuliaForever2.CodexProvider
            @test JuliaForever2.configured_provider(dir) isa JuliaForever2.CodexProvider
        end
    end
end

@testset "Commands and background event subscriptions compose" begin
    app = App(default_kernel())
    Terminal.register_command!(app, Terminal.CommandSpec("echo", "Echo arguments", (app, arguments) -> (app.status = String(arguments))))
    Terminal.submit!(app, "/echo custom payload")
    @test app.status == "custom payload"
    @test any(command.name == "echo" for command in app.commands)
    Terminal.register_command!(app, Terminal.CommandSpec("echo", "Updated command", (app, arguments) -> (app.status = "updated")))
    @test count(command -> command.name == "echo", app.commands) == 1
    Terminal.submit!(app, "/echo")
    @test app.status == "updated"
    Terminal.remove_command!(app, "echo")
    @test !any(command.name == "echo" for command in app.commands)

    received = Tuple{Symbol,Int}[]
    first_handler = Terminal.register_event_handler!(app, :custom_event, (app, value) -> push!(received, (:first, value)))
    Terminal.register_event_handler!(app, :custom_event, (app, value) -> push!(received, (:second, value)))
    update!(app, TaskEvent(:custom_event, 7))
    @test received == [(:first, 7), (:second, 7)]
    Terminal.remove_event_handler!(app, :custom_event, first_handler)
    update!(app, TaskEvent(:custom_event, 8))
    @test received[end] == (:second, 8)
    @test length(received) == 3
    repeated = (app, value) -> push!(received, (:repeated, value))
    repeated_first = Terminal.register_event_handler!(app, :repeated_event, repeated)
    Terminal.register_event_handler!(app, :repeated_event, repeated)
    Terminal.remove_event_handler!(app, :repeated_event, repeated_first)
    update!(app, TaskEvent(:repeated_event, 9))
    @test count(==((:repeated, 9)), received) == 1
end

@testset "Julia commands submit managed background work" begin
    app = App(default_kernel())
    started = Channel{Nothing}(1)
    finish = Channel{Nothing}(1)
    executor = (session, code) -> begin
        put!(started, nothing)
        take!(finish)
        ExecutionResult(true, "42", 42)
    end
    install!(app.session.kernel, ComponentSpec(:executor, executor))
    completions = Int[]
    Terminal.register_event_handler!(app, :completed, (app, result) -> push!(completions, result.value))
    handle = Terminal.submit!(app, "/julia 6 * 7")
    @test app.busy
    @test app.active_turn === handle
    @test timedwait(() -> isready(started), 5) == :ok
    take!(started)
    @test !istaskdone(handle)
    @test app.session.messages[1].content == "/julia 6 * 7"
    put!(finish, nothing)
    @test finish_ui_operation!(app) == :ok
    @test completions == [42]
    @test !app.busy
    @test isnothing(app.active_turn)
    @test app.session.messages[end].role == :code_result
    @test app.session.messages[end].content == "42"

    next_handle = Terminal.submit!(app, "/julia 42")
    @test timedwait(() -> isready(started), 5) == :ok
    take!(started)
    Terminal.cleanup!(app)
    @test JuliaForever2.cancelled(next_handle.context)
    put!(finish, nothing)
    @test timedwait(() -> istaskdone(next_handle), 5) == :ok
end

@testset "Shutdown closes event publication without blocking producers" begin
    app = App(default_kernel())
    ready = Base.Event()
    producers = [Threads.@spawn begin
        wait(ready)
        for index in 1:300
            Terminal.enqueue_event!(app, TaskEvent(:progress, index))
        end
    end for _ in 1:8]
    notify(ready)
    Terminal.cleanup!(app)
    @test timedwait(() -> all(istaskdone, producers), 5) == :ok
    foreach(fetch, producers)
    @test app.closing[]
    @test !isready(app.queue.channel)
    @test !Terminal.enqueue_event!(app, TaskEvent(:progress, 301))
    Terminal.finish_shutdown!(app)
    @test !isopen(app.session)
end

@testset "Transcript cache reuses unaffected messages" begin
    app = App(default_kernel())
    append_message!(app.session, Message(:user, "First prompt"))
    append_message!(app.session, Message(:assistant, "println(42)", :code))
    Terminal.transcript_lines!(app, 80)
    code_chunk = app.transcript_chunks[2]
    first_chunk = app.transcript_chunks[1]
    append_message!(app.session, Message(:code_result, "42"))
    Terminal.transcript_lines!(app, 80)
    @test app.transcript_chunks[1] === first_chunk
    @test app.transcript_chunks[2] !== code_chunk
    @test app.transcript_lines == Terminal.conversation_lines(app.transcript_messages, 80)

    append_message!(app.session, Message(:assistant, "A **formatted** answer with enough text to wrap at a narrow width."))
    Terminal.transcript_lines!(app, 80)
    chunks = copy(app.transcript_chunks)
    snapshot = app.transcript_messages
    lines = app.transcript_lines
    Terminal.transcript_lines!(app, 80)
    @test app.transcript_messages === snapshot
    @test app.transcript_lines === lines
    @test app.transcript_chunks[1] === chunks[1]

    replace_message!(app.session, 2, Message(:assistant, "println(43)", :code))
    Terminal.transcript_lines!(app, 80)
    @test app.transcript_chunks[1] === chunks[1]
    @test app.transcript_chunks[2] !== chunks[2]
    @test app.transcript_chunks[3] === chunks[3]
    @test app.transcript_chunks[4] === chunks[4]
    @test app.transcript_lines == Terminal.conversation_lines(app.transcript_messages, 80)

    previous = app.transcript_chunks[4]
    Terminal.transcript_lines!(app, 20)
    @test app.transcript_chunks[4] !== previous
    @test app.transcript_lines == Terminal.conversation_lines(app.transcript_messages, 20)
    clear_history!(app.session)
    Terminal.transcript_lines!(app, 20)
    @test isempty(app.transcript_lines)
    @test isempty(app.transcript_chunks)
    append_message!(app.session, Message(:user, "A fresh conversation"))
    Terminal.transcript_lines!(app, 20)
    @test length(app.transcript_messages) == 1
    @test app.transcript_lines == Terminal.conversation_lines(app.transcript_messages, 20)
end

@testset "Provider registrations share one configuration directory" begin
    mktempdir() do directory
        status_reads = Ref(0)
        observed_directory = Ref("")
        status = dir -> begin
            status_reads[] += 1
            observed_directory[] = dir
            "test account"
        end
        descriptor = ProviderDescriptor(:terminal_test, "Custom test provider", RegisteredTerminalProvider; status)
        register_provider!(descriptor)
        app = App(default_kernel(); settings_dir=directory)
        Terminal.command!(app, "settings")
        @test observed_directory[] == directory
        @test any(occursin("Custom test provider", label) for label in app.provider_labels)
        @test length(app.providers) == 5
        before_render = status_reads[]
        backend = TestBackend(80, 24)
        frame = Tachikoma.Frame(backend.buf, backend.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        Tachikoma.view(app, frame)
        Tachikoma.view(app, frame)
        @test status_reads[] == before_render
        app.selected = findfirst(item -> item.id == :terminal_test, app.providers)
        update!(app, KeyEvent(:enter))
        provider = component(app.session.kernel, :provider)
        @test provider isa RegisteredTerminalProvider
        @test provider.directory == directory
        @test strip(read(joinpath(directory, "provider"), String)) == "terminal_test"
        @test JuliaForever2.configured_provider(directory).directory == directory

        authorization_directory = Ref("")
        action = (flow, provider, dir; announce) -> begin
            authorization_directory[] = dir
            (ok=true, reason="Test provider connected.")
        end
        Terminal.start_sign_in!(app, :terminal_test; action)
        @test timedwait(() -> isready(app.queue.channel), 5) == :ok
        update!(app, take!(app.queue.channel))
        @test authorization_directory[] == directory
        @test component(app.session.kernel, :provider).directory == directory
        unregister_provider!(:terminal_test)
    end
end

end
end
