using JuliaForever2: App, default_kernel
using Tachikoma
import Tachikoma: update!

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
    push!(app.session.messages, Message(:user, "My favorite fruit is mango."))
    push!(app.session.messages, Message(:assistant, "Mango is a great choice."))
    push!(app.session.messages, Message(:code_result, "Julia output"))
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
    push!(app.session.messages, Message(:assistant, "println(42)", :code))
    push!(app.session.messages, Message(:code_result, "RESULT_42"))
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
    push!(app.session.messages, Message(:assistant, "# Heading\n\nPlain **bold** and `code`.\n\n```julia\n" * repeat("x", 40) * "\n```"))
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
    Tachikoma.view(app, frame)
    @test app.transcript_lines === cached
    push!(app.session.messages, Message(:assistant, "Additional response"))
    Tachikoma.view(app, frame)
    @test app.transcript_lines !== cached
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
    @test first(JuliaForever2.matching_commands(app))[1] == "settings"
    update!(app, KeyEvent(:enter))
    @test app.page == :settings
    update!(app, KeyEvent(:escape))
    for i in 1:30
        push!(app.session.messages, Message(:assistant, "line $i"))
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
    lines = JuliaForever2.wrap_conversation_line(text, 8)
    @test join(lines) == text
    @test all(textwidth(line) <= 8 for line in lines)
    @test any(occursin("cafe\u0301", line) for line in lines)
    @test JuliaForever2.wrap_conversation_line("", 8) == [""]

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
        JuliaForever2.command!(app, "settings")
        @test app.selected == 4
        @test stat(joinpath(dir, "provider")).mode & 0o777 == 0o600
        write(joinpath(dir, "provider"), "unknown")
        @test JuliaForever2.configured_provider(dir) isa JuliaForever2.DemoProvider
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
            JuliaForever2.start_sign_in!(app, :openrouter; action, dir)
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
            JuliaForever2.start_sign_in!(app, :codex; action=codex_action, dir)
            @test timedwait(() -> isready(app.queue.channel), 5) == :ok
            update!(app, take!(app.queue.channel))
            @test !app.busy && app.page == :settings
            @test component(app.session.kernel, :provider) isa JuliaForever2.CodexProvider
            @test JuliaForever2.configured_provider(dir) isa JuliaForever2.CodexProvider
        end
    end
end
