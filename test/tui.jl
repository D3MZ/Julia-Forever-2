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
    @test Tachikoma.style_at(tb, user.x, user.y).bg == Tachikoma.ColorRGB(45, 59, 71)
    @test Tachikoma.style_at(tb, 1, user.y).bg == Tachikoma.ColorRGB(45, 59, 71)
    @test Tachikoma.style_at(tb, answer.x, answer.y).bg != Tachikoma.ColorRGB(45, 59, 71)
    output = find_text(tb, "Julia output")
    @test Tachikoma.style_at(tb, output.x, output.y).bg == Tachikoma.ColorRGB(36, 63, 48)
    @test isnothing(find_text(tb, "You")) && isnothing(find_text(tb, "Agent"))
    @test !isnothing(find_text(tb, pwd()))
    @test !isnothing(find_text(tb, "Demo"))
    app.session.usage.input_tokens = 120
    app.session.usage.output_tokens = 18
    app.session.usage.reported = true
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    usage = find_text(tb, "↑120 ↓18")
    provider = find_text(tb, "Demo")
    @test !isnothing(usage) && !isnothing(provider) && usage.y == provider.y && usage.x < provider.x
end

@testset "Terminal rendering" begin
    app = App(default_kernel())
    tb = TestBackend(80, 24)
    frame = Tachikoma.Frame(tb.buf, tb.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(app, frame)
    @test !isnothing(find_text(tb, "JULIA FOREVER"))
    update!(app, KeyEvent('/'))
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    @test !isnothing(find_text(tb, "/settings"))
    update!(app, KeyEvent(:enter))
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    @test !isnothing(find_text(tb, "Settings  /  Provider"))
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
    pos = find_text(tb, "/settings")
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test app.page == :settings
    Tachikoma.reset!(tb.buf)
    Tachikoma.view(app, frame)
    pos = find_text(tb, "OpenRouter")
    update!(app, MouseEvent(pos.x, pos.y, Tachikoma.mouse_left, Tachikoma.mouse_press, false, false, false))
    @test app.page == :chat
    @test JuliaForever2.component(app.session.kernel, :provider) isa JuliaForever2.OpenRouterProvider
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
            app = App(default_kernel())
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
            @test app.status == "OpenRouter connected."
        end
    end
end
