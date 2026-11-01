using JuliaForever2: default_kernel, append_message!, clear_history!, replace_message!,
    ProviderDescriptor, register_provider!, unregister_provider!, ExecutionResult
using Tachikoma
using CommonMark
using JSON
import Tachikoma: update!

const Terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const App = Terminal.App

struct RegisteredTerminalProvider
    directory::String
end
JuliaForever2.provider_id(::RegisteredTerminalProvider) = :terminal_test

struct ScopedTerminalProvider
    id::Symbol
end
JuliaForever2.provider_id(provider::ScopedTerminalProvider) = provider.id

struct StreamedTerminalProvider
    replies::Vector{Reply}
    next::Threads.Atomic{Int}
    started::Channel{UInt64}
    proceed::Channel{Nothing}
end
StreamedTerminalProvider(replies) = StreamedTerminalProvider(replies, Threads.Atomic{Int}(0), Channel{UInt64}(1), Channel{Nothing}(1))

function JuliaForever2.respond(provider::StreamedTerminalProvider, request::JuliaForever2.ModelRequest, context::ExecutionContext)
    index = Threads.atomic_add!(provider.next, 1) + 1
    reply = provider.replies[index]
    wire = JSON.json((kind=String(reply.kind), content=reply.content))
    JuliaForever2.emit_protocol_progress!(JuliaForever2.CodeModePolicy(), wire, context)
    put!(provider.started, JuliaForever2.operation_id(context))
    take!(provider.proceed)
    return ProviderResult(reply, nothing)
end

function drain_ui_events!(app)
    while isready(app.queue.channel)
        update!(app, take!(app.queue.channel))
    end
    return nothing
end

function finish_ui_operation!(app; timeout=5)
    timedwait(timeout; pollint=0.01) do
        while isready(app.queue.channel)
            update!(app, take!(app.queue.channel))
        end
        !app.busy
    end
end

@testset "Terminal state field defaults and independent buffers" begin
    registry = JuliaForever2.ProviderRegistry()
    settings = Terminal.SettingsState("configuration", registry)
    @test settings.registry === registry
    @test isempty(settings.providers)
    @test isempty(settings.labels)
    @test settings.auth_provider == :none
    @test Terminal.SettingsState(; directory="configuration", registry, auth_provider=:test).auth_provider == :test

    first_transcript, second_transcript = Terminal.TranscriptState(), Terminal.TranscriptState()
    @test first_transcript.revision == typemax(UInt)
    @test first_transcript.messages !== second_transcript.messages
    @test first_transcript.preview === nothing
    @test Terminal.TranscriptState(width=80).width == 80

    first_operations, second_operations = Terminal.OperationState(), Terminal.OperationState()
    @test !first_operations.closing[]
    @test first_operations.watchers !== second_operations.watchers
    @test Terminal.OperationState(active=nothing).active === nothing
end

mktempdir() do terminal_configuration
withenv("JULIAFOREVER_CONFIG_DIR" => terminal_configuration, "OPENROUTER_API_KEY" => "") do

@testset "Cross-terminal prompt editing shortcuts" begin
    app = App(default_kernel())
    Tachikoma.set_text!(app.input, "alpha beta gamma")
    app.input.cursor = 10
    update!(app, KeyEvent(:ctrl, 'u'))  # Ctrl+U; also Ghostty's Command+Backspace
    @test Tachikoma.text(app.input) == " gamma"
    @test app.input.cursor == 0
    update!(app, KeyEvent(:ctrl, 'k'))
    @test Tachikoma.text(app.input) == ""
    @test app.input.cursor == 0

    Tachikoma.set_text!(app.input, "one  two   ")
    update!(app, KeyEvent(:ctrl, 'w'))
    @test Tachikoma.text(app.input) == "one  "
    @test app.input.cursor == 5
    Tachikoma.set_text!(app.input, "αβ γδ")
    update!(app, KeyEvent(:ctrl, 'w'))
    @test Tachikoma.text(app.input) == "αβ "

    Tachikoma.set_text!(app.input, "abcdef")
    update!(app, KeyEvent(:ctrl, 'a'))
    @test app.input.cursor == 0
    update!(app, KeyEvent(:ctrl, 'f'))
    @test app.input.cursor == 1
    update!(app, KeyEvent(:ctrl, 'e'))
    @test app.input.cursor == 6
    update!(app, KeyEvent(:ctrl, 'b'))
    @test app.input.cursor == 5
    update!(app, KeyEvent(:ctrl, 'd'))
    @test Tachikoma.text(app.input) == "abcde"
    update!(app, KeyEvent(:ctrl, 'h'))
    @test Tachikoma.text(app.input) == "abcd"
    @test app.input.cursor == 4
    update!(app, KeyEvent(:ctrl, 'u', Tachikoma.key_release))
    @test Tachikoma.text(app.input) == "abcd"
    update!(app, KeyEvent('!'))
    @test Tachikoma.text(app.input) == "abcd!"
end

@testset "Slash completion and menu editing" begin
    app = App(default_kernel())
    for character in "/se"
        update!(app, KeyEvent(character))
    end
    @test app.menu
    update!(app, KeyEvent(:tab))
    @test Tachikoma.text(app.input) == "/settings "
    @test !app.menu
    @test app.page == :chat
    update!(app, KeyEvent(:enter))
    @test app.page == :settings

    selected = App(default_kernel())
    update!(selected, KeyEvent('/'))
    update!(selected, KeyEvent(:down))
    update!(selected, KeyEvent(:tab))
    @test Tachikoma.text(selected.input) == "/components "
    @test selected.page == :chat
    @test !selected.menu

    output = String[]
    custom = App(default_kernel())
    Terminal.register_command!(custom, Terminal.CommandSpec("echo", "Echo", (app, arguments) -> push!(output, String(arguments))))
    for character in "/ec"
        update!(custom, KeyEvent(character))
    end
    update!(custom, KeyEvent(:tab))
    @test Tachikoma.text(custom.input) == "/echo "
    @test isempty(output)
    for character in "hello world"
        update!(custom, KeyEvent(character))
    end
    update!(custom, KeyEvent(:enter))
    @test output == ["hello world"]
    @test Tachikoma.text(custom.input) == ""

    update!(custom, KeyEvent('/'))
    update!(custom, KeyEvent(:backtab))
    @test custom.selected == length(Terminal.matching_commands(custom))
    update!(custom, KeyEvent(:ctrl, 'u'))
    @test !custom.menu
    @test Tachikoma.text(custom.input) == ""
    Tachikoma.set_text!(custom.input, "plain text")
    update!(custom, KeyEvent(:tab))
    @test Tachikoma.text(custom.input) == "plain text"
end

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

    for (content, width, expected) in (
            ("one two three", 7, ["one ", "two ", "three"]),
            ("a  b", 3, ["a  ", "b"]),
            (" a b", 3, [" a ", "b"]),
            ("abc def", 7, ["abc def"]),
            ("你好a", 1, ["你", "好", "a"]),
            ("e\u0301x", 1, ["e\u0301", "x"]),
            ("🇨🇦🇺🇸", 2, ["🇨🇦", "🇺🇸"]),
            ("👩\u200d💻!", 1, ["👩\u200d💻", "!"]),
            ("a\tb", 1, ["a\t", "b"]),
            (" a", 0, [" ", "a"]),
            ("abc", -1, ["a", "b", "c"]))
        wrapped = Terminal.wrap_conversation_line(content, width)
        @test wrapped == expected
        @test join(wrapped) == content
        @test eltype(wrapped) === String
    end
    surrounding = "prefix: Hello 你好 cafe\u0301 and a verylongword :suffix"
    content = SubString(surrounding, nextind(surrounding, 0, 9), prevind(surrounding, lastindex(surrounding), 8))
    @test Terminal.wrap_conversation_line(content, 8) == lines

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

@testset "Live response previews stay outside history and ignore stale operations" begin
    provider = StreamedTerminalProvider([Reply(:answer, "Live response"), Reply(:answer, "Cancelled response"), Reply(:answer, "Fresh response")])
    app = App(default_kernel(provider))
    handle = Terminal.submit!(app, "First request")
    @test timedwait(() -> isready(provider.started), 5) == :ok
    identity = take!(provider.started)
    drain_ui_events!(app)
    @test app.transcript.preview.text == "Live response"
    @test length(app.session.messages) == 1

    backend = TestBackend(80, 24)
    frame = Tachikoma.Frame(backend.buf, backend.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    @test !isnothing(find_text(backend, "Live response"))
    @test isnothing(find_text(backend, "{\"kind\""))
    @test isempty(filter(message -> message.role == :assistant, app.session.messages))
    stale = TaskEvent(:response_progress, (operation_id=identity + UInt64(1), progress=JuliaForever2.ResponseProgress(:answer, "Stale response")))
    update!(app, stale)
    @test app.transcript.preview.text == "Live response"
    put!(provider.proceed, nothing)
    @test finish_ui_operation!(app) == :ok
    @test isnothing(app.transcript.preview)
    @test count(message -> message.role == :assistant && message.content == "Live response", app.session.messages) == 1
    @test isempty(Terminal.preview_lines!(app, 80))

    delayed = TaskEvent(:response_progress, (operation_id=identity, progress=JuliaForever2.ResponseProgress(:answer, "Old response")))
    update!(app, delayed)
    @test isnothing(app.transcript.preview)
    next_handle = Terminal.submit!(app, "Cancelled request")
    @test timedwait(() -> isready(provider.started), 5) == :ok
    next_identity = take!(provider.started)
    drain_ui_events!(app)
    @test app.transcript.preview.text == "Cancelled response"
    update!(app, delayed)
    update!(app, TaskEvent(:turn, handle))
    @test app.active_turn === next_handle
    @test app.transcript.preview.text == "Cancelled response"
    Terminal.cancel_command!(app, "")
    @test isnothing(app.transcript.preview)
    update!(app, TaskEvent(:response_progress, (operation_id=next_identity, progress=JuliaForever2.ResponseProgress(:answer, "Too late"))))
    @test isnothing(app.transcript.preview)
    put!(provider.proceed, nothing)
    @test finish_ui_operation!(app) == :ok
    @test !any(message -> message.role == :assistant && message.content == "Cancelled response", app.session.messages)

    Terminal.submit!(app, "Reusable session")
    @test timedwait(() -> isready(provider.started), 5) == :ok
    take!(provider.started)
    drain_ui_events!(app)
    @test app.transcript.preview.text == "Fresh response"
    put!(provider.proceed, nothing)
    @test finish_ui_operation!(app) == :ok
    @test count(message -> message.role == :assistant, app.session.messages) == 2
    @test isnothing(app.transcript.preview)
    Terminal.finish_shutdown!(app)
end

@testset "Each code-mode response replaces its preview before execution" begin
    provider = StreamedTerminalProvider([Reply(:code, "21 * 2"), Reply(:answer, "The result is 42.")])
    app = App(default_kernel(provider))
    executing = Channel{Nothing}(1)
    execution_complete = Channel{Nothing}(1)
    executor = (session, code) -> begin
        put!(executing, nothing)
        take!(execution_complete)
        ExecutionResult(true, "42", 42)
    end
    install!(app.session.kernel, ComponentSpec(:executor, executor))
    Terminal.submit!(app, "Calculate")
    @test timedwait(() -> isready(provider.started), 5) == :ok
    identity = take!(provider.started)
    drain_ui_events!(app)
    @test app.transcript.preview.kind == :code
    @test !any(message -> message.role == :assistant, app.session.messages)
    put!(provider.proceed, nothing)
    @test timedwait(() -> isready(executing), 5) == :ok
    take!(executing)
    drain_ui_events!(app)
    @test isnothing(app.transcript.preview)
    @test count(message -> message.role == :assistant && message.kind == :code, app.session.messages) == 1
    put!(execution_complete, nothing)
    @test timedwait(() -> isready(provider.started), 5) == :ok
    @test take!(provider.started) == identity
    drain_ui_events!(app)
    @test app.transcript.preview.kind == :answer
    @test app.transcript.preview.text == "The result is 42."
    @test count(message -> message.role == :code_result, app.session.messages) == 1
    put!(provider.proceed, nothing)
    @test finish_ui_operation!(app) == :ok
    @test isnothing(app.transcript.preview)
    @test count(message -> message.role == :assistant && message.content == "The result is 42.", app.session.messages) == 1
    Terminal.finish_shutdown!(app)
end

@testset "Terminal applications isolate provider catalogs" begin
    first_registry = JuliaForever2.ProviderRegistry()
    second_registry = JuliaForever2.ProviderRegistry()
    register_provider!(first_registry, ProviderDescriptor(:first_only, "First catalog", directory -> ScopedTerminalProvider(:first_only)))
    register_provider!(second_registry, ProviderDescriptor(:second_only, "Second catalog", directory -> ScopedTerminalProvider(:second_only)))
    mktempdir() do directory
        first_directory = joinpath(directory, "first")
        second_directory = joinpath(directory, "second")
        first_app = App(Kernel(); settings_dir=first_directory, registry=first_registry)
        second_app = App(Kernel(); settings_dir=second_directory, registry=second_registry)
        @test [descriptor.id for descriptor in first_app.providers] == [:first_only]
        @test [descriptor.id for descriptor in second_app.providers] == [:second_only]
        Terminal.select_provider!(first_app)
        Terminal.select_provider!(second_app)
        @test component(first_app.session.kernel, :provider).id == :first_only
        @test component(second_app.session.kernel, :provider).id == :second_only
        restored = Terminal.terminal_app(; settings_dir=first_directory, registry=first_registry)
        @test component(restored.session.kernel, :provider).id == :first_only
        unregister_provider!(first_registry, :first_only)
        Terminal.refresh_settings!(first_app)
        Terminal.refresh_settings!(second_app)
        @test isempty(first_app.providers)
        @test [descriptor.id for descriptor in second_app.providers] == [:second_only]
        foreach(Terminal.finish_shutdown!, (first_app, second_app, restored))
    end
end

@testset "Failed background work releases frontend ownership before propagating" begin
    app = App(default_kernel())
    install!(app.session.kernel, ComponentSpec(:executor, (session, code) -> error("terminal execution fixture")))
    failed = Terminal.submit!(app, "/julia failure")
    @test timedwait(() -> istaskdone(failed), 5) == :ok
    @test_throws TaskFailedException finish_ui_operation!(app)
    @test isnothing(app.active_turn)
    @test !app.busy
    @test isnothing(app.transcript.preview)
    install!(app.session.kernel, ComponentSpec(:executor, (session, code) -> ExecutionResult(true, "reused")))
    Terminal.submit!(app, "/julia reuse")
    @test finish_ui_operation!(app) == :ok
    @test app.session.messages[end].content == "reused"
    Terminal.finish_shutdown!(app)

    auth_app = App(default_kernel())
    releases = Threads.Atomic{Int}(0)
    action = (flow, provider, directory; announce) -> begin
        JuliaForever2.own_resource!(flow.context, nothing; cleanup=value -> Threads.atomic_add!(releases, 1))
        error("terminal authorization fixture")
    end
    Terminal.start_sign_in!(auth_app, :openrouter; action)
    @test timedwait(() -> isready(auth_app.queue.channel), 5) == :ok
    @test releases[] == 1
    @test_throws TaskFailedException update!(auth_app, take!(auth_app.queue.channel))
    @test !auth_app.busy
    @test isnothing(auth_app.auth_flow)
    @test isnothing(auth_app.auth_task)
    Terminal.finish_shutdown!(auth_app)
    @test releases[] == 1
end

end
end

@testset "Printable ASCII transcript wrapping fast path" begin
    for (content, width, expected) in (
            ("abcdefghi", 4, ["abcd", "efgh", "i"]),
            ("ab cd ef", 4, ["ab ", "cd ", "ef"]),
            ("   abc", 2, ["  ", " ", "ab", "c"]),
            (repeat("x", 25), 3, [repeat("x", 3) for _ in 1:8] |> x -> vcat(x, ["x"])),
            (" ", 0, [" "]),
            ("x", -3, ["x"]),
            ("", 2, [""]))
        @test Terminal.wrap_conversation_line(content, width) == expected
        @test Terminal.wrap_conversation_line(SubString("##" * content * "@@", 3, 2 + ncodeunits(content)), width) == expected
    end
    for content in ("a\\tb", "Julia λ", "e\u0301x", "👩\u200d💻", "ab\r\ncd")
        wrapped = Terminal.wrap_conversation_line(content, 5)
        @test join(wrapped) == content
    end
end


@testset "ASCII markdown span wrapping matches grapheme reference" begin
    function reference_markdown_wrap(spans, width)
        lines = Vector{Tachikoma.Span}[]
        line = Tachikoma.Span[]
        columns = 0
        for span in spans
            text = IOBuffer()
            for grapheme in Base.Unicode.graphemes(span.content)
                size = textwidth(grapheme)
                if columns + size > width && columns > 0
                    position(text) > 0 && push!(line, Tachikoma.Span(String(take!(text)), span.style))
                    push!(lines, line)
                    line = Tachikoma.Span[]
                    columns = 0
                end
                print(text, grapheme)
                columns += size
            end
            position(text) > 0 && push!(line, Tachikoma.Span(String(take!(text)), span.style))
        end
        push!(lines, line)
        return [[(span.content, span.style) for span in row] for row in lines]
    end

    plain = Tachikoma.Style(; fg=Tachikoma.ColorRGB(222, 224, 225))
    highlighted = Tachikoma.Style(; fg=Tachikoma.ColorRGB(104, 183, 141), bold=true)
    cases = (
        Tachikoma.Span[],
        [Tachikoma.Span("", plain)],
        [Tachikoma.Span("abcdefghijk", plain)],
        [Tachikoma.Span("ab", plain), Tachikoma.Span("cdefghijklmnop", highlighted)],
        [Tachikoma.Span("a", plain), Tachikoma.Span("bcdefg", highlighted), Tachikoma.Span("hi", plain)],
        [Tachikoma.Span("text with spaces  and punctuation !?@#", plain)],
        [Tachikoma.Span("first", plain), Tachikoma.Span("λ你好🚀", highlighted), Tachikoma.Span("last", plain)],
        [Tachikoma.Span("cafe\u0301\tcontrol", plain), Tachikoma.Span("ASCII", highlighted)],
        [Tachikoma.Span("🇨🇦👩\u200d💻", highlighted), Tachikoma.Span("abc", plain)],
        [Tachikoma.Span(repeat("x", 2000), plain), Tachikoma.Span("!", highlighted)],
    )
    for spans in cases, width in (-2, 0, 1, 2, 5, 10, 40, 78, 200)
        actual = [[(span.content, span.style) for span in row]
            for row in Terminal.wrap_markdown_spans(spans, width)]
        @test actual == reference_markdown_wrap(spans, width)
    end
end


@testset "Manual compaction slash command uses supervised session operations" begin
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider,
        (messages, session) -> Reply(:answer, "Condensed terminal context")))
    session = Session(kernel; compaction=JuliaForever2.CompactionSettings(;
        keep_recent_tokens=0), messages=Message[
            Message(:user, "Older task"), Message(:assistant, "Previous result"),
            Message(:user, "Current task")])
    app = Terminal.App(session)
    @test any(command -> command.name == "compact", app.commands)
    Terminal.compact_command!(app, "Keep the current goal")
    handle = app.operations.active
    @test handle isa TaskHandle
    @test fetch(handle).ok
    Terminal.operation_finished!(app, handle)
    @test [message.content for message in JuliaForever2.context_messages(session)] ==
        ["Condensed terminal context", "Current task"]
    @test length(JuliaForever2.history_snapshot(session).messages) == 3
    @test !app.busy
    Terminal.finish_shutdown!(app)
end
