using Tachikoma
import Tachikoma: update!, view, should_quit, task_queue, cleanup!

mutable struct App <: Model
    session::Session
    input::TextInput
    page::Symbol
    menu::Bool
    selected::Int
    quit::Bool
    busy::Bool
    queue::TaskQueue
    status::String
    scroll::Int
    area::Rect
    auth_flow::Union{AuthFlow,Nothing}
    auth_url::String
    auth_provider::Symbol
end

App(kernel::Kernel=default_kernel()) = App(Session(kernel), TextInput(; label="❯ "), :chat, false, 1, false, false, TaskQueue(), "Demo provider · Julia executes with your permissions", 0, Rect(), nothing, "", :none)
const COMMANDS = [("settings", "Choose a provider"), ("components", "Inspect installed components"), ("julia", "Run a Julia expression"), ("clear", "Clear the conversation"), ("quit", "Exit")]
matching_commands(app::App) = filter(item -> startswith(item[1], replace(Tachikoma.text(app.input), r"^/" => "")), COMMANDS)
task_queue(app::App) = app.queue
should_quit(app::App) = app.quit

function command!(app::App, name::AbstractString)
    app.menu = false
    Tachikoma.clear!(app.input)
    if name == "settings"
        app.page = :settings
        app.selected = 1
    elseif name == "components"
        app.page = :components
    elseif name == "julia"
        Tachikoma.set_text!(app.input, "/julia ")
    elseif name == "clear"
        lock(app.session.lock) do
            empty!(app.session.messages)
        end
        app.scroll = 0
    elseif name == "quit"
        app.quit = true
    end
end

function submit!(app::App, prompt::String)
    isempty(strip(prompt)) && return
    app.busy && return
    Tachikoma.clear!(app.input)
    app.scroll = 0
    if startswith(prompt, "/julia ")
        code = prompt[8:end]
        push!(app.session.messages, Message(:user, prompt))
        result = evaluate!(app.session, code)
        push!(app.session.messages, Message(:code_result, result.text))
    elseif startswith(prompt, "/")
        command!(app, strip(prompt[2:end]))
    else
        app.busy = true
        app.status = "Thinking…"
        Tachikoma.spawn_task!(app.queue, :turn) do
            run_turn!(app.session, prompt)
        end
    end
end

function start_sign_in!(app::App, provider::Symbol; action=sign_in!, dir=config_dir())
    app.busy && return
    flow = AuthFlow()
    app.auth_flow = flow
    app.auth_url = ""
    app.auth_provider = provider
    app.busy = true
    app.page = :auth
    app.status = "Opening browser for sign-in…"
    Tachikoma.spawn_task!(app.queue, :auth_done) do
        announce = url -> put!(app.queue.channel, TaskEvent(:auth_url, (flow, url)))
        action(flow, provider, dir; announce)
    end
end

function update!(app::App, event::TaskEvent)
    if event.id == :auth_url
        flow, url = event.value
        if app.auth_flow === flow && active_auth(flow)
            app.auth_url = url
            app.status = "Complete sign-in in your browser."
        end
    elseif event.id == :auth_done
        app.busy = false
        flow = app.auth_flow
        app.auth_flow = nothing
        cancelled = isnothing(flow) || !active_auth(flow)
        if cancelled
            app.status = "Sign-in cancelled."
        elseif event.value isa Exception
            app.status = "Sign-in failed. Check your connection and try again."
        else
            result = event.value
            app.status = result.reason
            if result.ok
                provider = app.auth_provider == :chatgpt ? OpenAIProvider() : OpenRouterProvider()
                install!(app.session.kernel, ComponentSpec(:provider, provider))
            end
        end
        app.page == :auth && (app.page = :settings)
        app.auth_url = ""
    elseif event.id == :turn
        app.busy = false
        app.status = event.value isa Exception ? sprint(showerror, event.value) : (event.value.ok ? "Ready" : event.value.text)
    end
end

function default_input!(app::App, event::KeyEvent)
    if app.page == :auth
        flow = app.auth_flow
        if event.key == :escape && !isnothing(flow)
            cancel_auth!(flow)
            app.status = "Cancelling sign-in…"
            app.page = :settings
        end
        return
    elseif app.page == :settings
        if event.key == :escape
            app.page = :chat
        elseif event.key in (:up, :down)
            app.selected = mod1(app.selected + (event.key == :up ? -1 : 1), 4)
        elseif event.key == :char && event.char == 's' && app.selected in (2, 3)
            start_sign_in!(app, app.selected == 2 ? :chatgpt : :openrouter)
        elseif event.key == :enter
            provider = app.selected == 1 ? DemoProvider() : app.selected == 2 ? OpenAIProvider() : app.selected == 3 ? OpenRouterProvider() : CodexProvider()
            install!(app.session.kernel, ComponentSpec(:provider, provider))
            app.status = app.selected == 1 ? "Demo provider" : app.selected == 2 ? "ChatGPT selected — sign in from settings with s" : app.selected == 3 ? "OpenRouter selected — sign in from settings with s" : "Codex CLI provider"
            app.page = :chat
        end
        return
    elseif app.page != :chat
        event.key in (:escape, :enter) && (app.page = :chat)
        return
    end
    if app.menu
        matches = matching_commands(app)
        if event.key == :escape
            app.menu = false
            Tachikoma.clear!(app.input)
        elseif event.key == :up
            app.selected = mod1(app.selected - 1, length(matches))
        elseif event.key == :down
            app.selected = mod1(app.selected + 1, length(matches))
        elseif event.key == :enter
            command!(app, matches[app.selected][1])
        else
            Tachikoma.handle_key!(app.input, event)
            app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
            app.selected = 1
        end
    elseif event.key == :enter
        submit!(app, Tachikoma.text(app.input))
    elseif event.key == :ctrl_c
        app.quit = true
    elseif event.key == :pageup
        app.scroll += 10
    elseif event.key == :pagedown
        app.scroll = max(0, app.scroll - 10)
    else
        Tachikoma.handle_key!(app.input, event)
        app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
        app.menu && (app.selected = 1)
    end
end

function drawline!(buffer, x, y, width, text, style=:text)
    y < 1 && return
    Tachikoma.set_string!(buffer, x, y, text, tstyle(style); max_x=x + width - 1)
end

function provider_labels()::NTuple{4,String}
    chatgpt = load_credentials(config_dir(), :chatgpt)
    router = load_credentials(config_dir(), :openrouter)
    raw_email = isnothing(chatgpt) ? "" : get(chatgpt, "email", "")
    email = raw_email isa String ? raw_email : ""
    chat_status = isnothing(chatgpt) ? "not connected" : isempty(email) ? "connected" : email
    router_status = !isnothing(router) || !isempty(get(ENV, "OPENROUTER_API_KEY", "")) ? "connected" : "not connected"
    return ("Demo — offline, deterministic", "ChatGPT plan — " * chat_status, "OpenRouter — " * router_status, "Codex CLI — existing CLI sign-in")
end

function default_view!(app::App, frame::Frame)
    area = frame.area
    app.area = area
    buf = frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    w < 5 && return
    h < 5 && return
    drawline!(buf, x + 1, y, w - 2, "◆ JULIA FOREVER", :accent)
    if app.page == :auth
        drawline!(buf, x + 1, y + 2, w - 2, "Sign in to " * (app.auth_provider == :chatgpt ? "ChatGPT" : "OpenRouter"), :accent)
        drawline!(buf, x + 1, y + 4, w - 2, "Complete authorization in your browser.", :text)
        drawline!(buf, x + 1, y + 6, w - 2, "If it did not open, copy this URL:", :text_dim)
        chars = collect(app.auth_url)
        for (i, part) in enumerate(Iterators.partition(chars, max(1, w - 2)))
            i > h - 10 && break
            drawline!(buf, x + 1, y + 6 + i, w - 2, String(collect(part)), :text)
        end
        drawline!(buf, x + 1, y + h - 1, w - 2, "esc cancel", :text_dim)
        return
    elseif app.page == :settings
        drawline!(buf, x + 1, y + 2, w - 2, "Settings  /  Provider", :accent)
        for (i, name) in enumerate(provider_labels())
            drawline!(buf, x + 2, y + 3 + i, w - 3, (app.selected == i ? "› " : "  ") * name, app.selected == i ? :accent : :text)
        end
        drawline!(buf, x + 1, y + h - 1, w - 2, "↑↓ select   enter use   s sign in   esc back", :text_dim)
        return
    elseif app.page == :components
        drawline!(buf, x + 1, y + 2, w - 2, "Components", :accent)
        names = lock(app.session.kernel.lock) do
            sort!(collect(keys(app.session.kernel.entries)))
        end
        for (i, name) in enumerate(names[1:min(length(names), max(0, h - 5))])
            drawline!(buf, x + 2, y + 3 + i, w - 3, string(name), :text)
        end
        drawline!(buf, x + 1, y + h - 1, w - 2, "esc back", :text_dim)
        return
    end
    lines = Tuple{String,Symbol}[]
    messages = lock(app.session.lock) do
        copy(app.session.messages)
    end
    for message in messages
        role = message.role == :user ? "You" : message.role == :code_result ? "Julia" : "Agent"
        push!(lines, (role, :accent))
        for line in split(message.content, '\n')
            push!(lines, (String(line), :text))
        end
        push!(lines, ("", :text))
    end
    if isempty(lines)
        push!(lines, ("Ready. Type a message, or / for commands.", :text_dim))
    end
    wrapped = Tuple{String,Symbol}[]
    for (line, style) in lines
        chars = collect(line)
        if isempty(chars)
            push!(wrapped, ("", style))
        else
            for chunk in Iterators.partition(chars, max(1, w - 2))
                push!(wrapped, (String(collect(chunk)), style))
            end
        end
    end
    matches = app.menu ? matching_commands(app) : Tuple{String,String}[]
    maxlines = max(0, h - 6 - length(matches))
    lastline = max(0, length(wrapped) - app.scroll)
    firstline = max(1, lastline - maxlines + 1)
    for (i, (line, style)) in enumerate(wrapped[firstline:lastline])
        drawline!(buf, x + 1, y + i, w - 2, line, style)
    end
    if app.menu
        start = y + h - 4 - length(matches)
        for (i, (name, description)) in enumerate(matches)
            drawline!(buf, x + 1, start + i - 1, w - 2, (app.selected == i ? "› " : "  ") * "/" * rpad(name, 13) * description, app.selected == i ? :accent : :text_dim)
        end
    end
    drawline!(buf, x, y + h - 4, w, repeat("─", w), :text_dim)
    Tachikoma.render(app.input, Rect(x + 1, y + h - 3, w - 2, 1), buf)
    drawline!(buf, x, y + h - 2, w, repeat("─", w), :text_dim)
    drawline!(buf, x + 1, y + h - 1, w - 2, app.status * "   / commands", :text_dim)
end

function main()
    Tachikoma.app(App(); default_bindings=false)
    return 0
end

function default_input!(app::App, event::MouseEvent)
    event.button == Tachikoma.mouse_left && event.action == Tachikoma.mouse_press || return
    area = app.area
    if app.page == :settings
        selected = event.y - area.y - 3
        if 1 <= selected <= 4
            app.selected = selected
            update!(app, KeyEvent(:enter))
        end
    elseif app.page == :chat && app.menu
        matches = matching_commands(app)
        selected = event.y - (area.y + area.height - 4 - length(matches)) + 1
        if 1 <= selected <= length(matches)
            command!(app, matches[selected][1])
        end
    elseif app.page == :chat
        Tachikoma.handle_mouse!(app.input, event)
    end
end

function ui_component(app::App, name::Symbol, fallback, argument)
    lease = acquire!(app.session.kernel, name)
    isnothing(lease) && return Base.invokelatest(fallback, app, argument)
    try
        return Base.invokelatest(lease.value, app, argument)
    finally
        release!(lease)
    end
end

update!(app::App, event::Union{KeyEvent,MouseEvent}) = ui_component(app, :input, default_input!, event)
view(app::App, frame::Frame) = ui_component(app, :view, default_view!, frame)

function cleanup!(app::App)
    flow = app.auth_flow
    isnothing(flow) || cancel_auth!(flow)
    return nothing
end
