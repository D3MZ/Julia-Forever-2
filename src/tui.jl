using Tachikoma
using CommonMark
import Tachikoma: update!, view, should_quit, task_queue, cleanup!

const TranscriptContent = Union{String,Vector{Tachikoma.Span}}
const TranscriptLine = Tuple{TranscriptContent,Symbol}

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
    settings_dir::Union{Nothing,String}
    directory::String
    transcript_width::Int
    transcript_messages::Vector{Message}
    transcript_lines::Vector{TranscriptLine}
end

function directory_label(dir::AbstractString=pwd())
    home = homedir()
    label = dir == home ? "~" : startswith(dir, joinpath(home, "")) ? replace(dir, home => "~"; count=1) : String(dir)
    git = Sys.which("git")
    if !isnothing(git)
        branch = readchomp(pipeline(ignorestatus(`$git -C $dir symbolic-ref --quiet --short HEAD`); stderr=devnull))
        isempty(branch) || (label *= " ($branch)")
    end
    return label
end

App(kernel::Kernel=default_kernel(); settings_dir=nothing) = App(Session(kernel), TextInput(; label="", style=pi_style(:text), cursor_style=Tachikoma.Style(; fg=Tachikoma.ColorRGB(36, 41, 49), bg=Tachikoma.ColorRGB(255, 255, 255))), :chat, false, 1, false, false, TaskQueue(), "Ready", 0, Rect(), nothing, "", :none, settings_dir, directory_label(), 0, Message[], TranscriptLine[])
const COMMANDS = [("settings", "Choose a provider"), ("components", "Inspect installed components"), ("julia", "Run a Julia expression"), ("clear", "Clear the conversation"), ("quit", "Exit")]
matching_commands(app::App) = filter(item -> startswith(item[1], replace(Tachikoma.text(app.input), r"^/" => "")), COMMANDS)
task_queue(app::App) = app.queue
should_quit(app::App) = app.quit

function command!(app::App, name::AbstractString)
    app.menu = false
    Tachikoma.clear!(app.input)
    if name == "settings"
        app.page = :settings
        app.selected = provider_selection(component(app.session.kernel, :provider))
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
                provider = provider_from_name(string(app.auth_provider))
                install!(app.session.kernel, ComponentSpec(:provider, provider))
                remember_provider!(app, app.auth_provider)
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
        elseif event.key == :char && event.char == 's' && app.selected in (2, 3, 4)
            provider = (:chatgpt, :openrouter, :codex)[app.selected - 1]
            action = provider == :codex ? codex_sign_in! : sign_in!
            start_sign_in!(app, provider; action)
        elseif event.key == :enter
            name = (:demo, :chatgpt, :openrouter, :codex)[app.selected]
            provider = provider_from_name(string(name))
            install!(app.session.kernel, ComponentSpec(:provider, provider))
            remember_provider!(app, name)
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

function remember_provider!(app::App, provider::Symbol)
    dir = app.settings_dir
    isnothing(dir) || save_provider!(dir, provider)
    return nothing
end

function pi_style(style::Symbol)
    color = style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
        style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
        style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
    return Tachikoma.Style(; fg=color)
end

function drawline!(buffer, x, y, width, text, style=:text)
    y < 1 && return
    Tachikoma.set_string!(buffer, x, y, text, pi_style(style); max_x=x + width - 1)
end

provider_selection(::DemoProvider) = 1
provider_selection(::OpenAIProvider) = 2
provider_selection(::OpenRouterProvider) = 3
provider_selection(::CodexProvider) = 4
provider_selection(::Any) = 1

provider_name(::DemoProvider) = "Demo"
provider_name(::OpenRouterProvider{F}) where {F} = "OpenRouter"
provider_name(::OpenAIProvider) = "ChatGPT"
provider_name(::CodexProvider) = "Codex"
provider_name(::Any) = "Custom provider"
provider_detail(::DemoProvider) = "(demo) offline · /settings to connect"
provider_detail(provider::OpenRouterProvider) = "(openrouter) " * provider.model
provider_detail(provider::CodexProvider) = "(openai-codex) " * provider.model * " • " * provider.reasoning
provider_detail(provider::OpenAIProvider) = "(chatgpt) " * get(ENV, "CHATGPT_MODEL", "auto")
provider_detail(provider) = provider_name(provider)

function usage_label(session::Session)
    lock(session.lock) do
        usage = session.usage
        if usage.reported
            label = (usage.partial ? "~" : "") * "↑$(usage.input_tokens) ↓$(usage.output_tokens)"
            return usage.cost_known ? label * " \$$(round(usage.cost; digits=4))" : label
        end
        return ""
    end
end

function draw_footer!(buffer, x, y, width, app::App)
    provider = component(app.session.kernel, :provider)
    right = Base.invokelatest(provider_detail, provider)::String
    left = usage_label(app.session)
    app.status == "Ready" || (left = isempty(left) ? app.status : left * " · " * app.status)
    drawline!(buffer, x, y, width, left, :text_dim)
    available = max(0, width - textwidth(left) - (isempty(left) ? 0 : 1))
    clipped = Tachikoma.truncate_to_width(right, available)
    drawline!(buffer, x + width - textwidth(clipped), y, textwidth(clipped), clipped, :text_dim)
end

function wrap_conversation_line(line::AbstractString, width::Int)
    graphemes = collect(Base.Unicode.graphemes(line))
    isempty(graphemes) && return [""]
    lines = String[]
    first = 1
    while first <= length(graphemes)
        last = first - 1
        last_space = 0
        columns = 0
        for index in first:length(graphemes)
            columns + textwidth(graphemes[index]) > width && break
            columns += textwidth(graphemes[index])
            last = index
            all(isspace, graphemes[index]) && (last_space = index)
        end
        last = max(first, last)
        if last < length(graphemes) && first <= last_space < last
            last = last_space
        end
        push!(lines, join(graphemes[first:last]))
        first = last + 1
    end
    return lines
end

function wrap_markdown_spans(spans::Vector{Tachikoma.Span}, width::Int)
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
    return lines
end

function markdown_lines(content::AbstractString, width::Int)
    heading = Tachikoma.Style(; fg=Tachikoma.ColorRGB(205, 154, 34), bold=true)
    bold = Tachikoma.Style(; fg=pi_style(:text).fg, bold=true)
    emph = Tachikoma.Style(; fg=pi_style(:text).fg, italic=true)
    code = Tachikoma.Style(; fg=Tachikoma.ColorRGB(104, 183, 141))
    link = Tachikoma.Style(; fg=Tachikoma.ColorRGB(105, 173, 208), underline=true)
    spans = Tachikoma.markdown_to_spans(content, width; h1_style=heading, h2_style=heading, h3_style=heading,
        bold_style=bold, emph_style=emph, code_style=code, link_style=link,
        quote_style=pi_style(:text_dim), text_style=pi_style(:text), hr_style=pi_style(:text_dim))
    return [wrapped for line in spans for wrapped in wrap_markdown_spans(line, width)]
end

function conversation_lines(messages, width)
    lines = TranscriptLine[]
    for (index, message) in enumerate(messages)
        code = message.role == :assistant && message.kind == :code
        paired = code && index < length(messages) && messages[index + 1].role == :code_result
        continuation = message.role == :code_result && index > 1 && messages[index - 1].kind == :code
        style = message.role == :user ? :user_message : (message.role == :code_result || code) ? :code_result : :text
        style in (:user_message, :code_result) && !continuation && push!(lines, ("", style))
        if message.role == :assistant && !code
            for line in markdown_lines(message.content, max(1, width - 2))
                push!(lines, (line, :markdown))
            end
        else
            for line in split(message.content, '\n'; keepempty=true)
                for chunk in wrap_conversation_line(line, max(1, width - 2))
                    push!(lines, (chunk, style))
                end
            end
        end
        style in (:user_message, :code_result) && push!(lines, ("", style))
        paired || push!(lines, ("", :text))
    end
    return lines
end

function transcript_lines!(app::App, messages::Vector{Message}, width::Int)
    if app.transcript_width != width || app.transcript_messages != messages
        app.transcript_width = width
        app.transcript_messages = messages
        app.transcript_lines = conversation_lines(messages, width)
    end
    return app.transcript_lines
end

function command_menu(app::App, height::Int)
    matches = app.menu ? matching_commands(app) : Tuple{String,String}[]
    count = min(5, length(matches), max(0, height - 5))
    first = max(1, min(app.selected - count + 1, length(matches) - count + 1))
    return matches, first, count
end

function draw_conversation_line!(buffer, x, y, width, line::AbstractString, style)
    if style in (:user_message, :code_result)
        color = style == :user_message ? Tachikoma.ColorRGB(33, 59, 73) : Tachikoma.ColorRGB(37, 65, 49)
        bg = Tachikoma.Style(; fg=pi_style(:text).fg, bg=color)
        Tachikoma.set_string!(buffer, x, y, repeat(" ", width), bg; max_x=x + width - 1)
        Tachikoma.set_string!(buffer, x + 1, y, line, bg; max_x=x + width - 2)
    else
        drawline!(buffer, x + 1, y, width - 2, line, style)
    end
end

function draw_conversation_line!(buffer, x, y, width, spans::Vector{Tachikoma.Span}, style)
    column = x + 1
    for span in spans
        column = Tachikoma.set_string!(buffer, column, y, span.content, span.style; max_x=x + width - 2)
    end
end

settings_top(area::Rect) = max(area.y, area.y + area.height - 11)

function settings_window(app::App, area::Rect)
    top = settings_top(area)
    bottom = area.y + area.height - 3
    count = min(4, max(0, bottom - top - 4))
    first = max(1, min(app.selected - count + 1, 5 - count))
    return top, bottom, first, count
end

function provider_labels()::NTuple{4,String}
    chatgpt = load_credentials(config_dir(), :chatgpt)
    router = load_credentials(config_dir(), :openrouter)
    raw_email = isnothing(chatgpt) ? "" : get(chatgpt, "email", "")
    email = raw_email isa String ? raw_email : ""
    chat_status = isnothing(chatgpt) ? "not connected" : isempty(email) ? "connected" : email
    router_status = !isnothing(router) || !isempty(get(ENV, "OPENROUTER_API_KEY", "")) ? "key configured" : "sign in or use Pi credentials"
    return ("Demo — offline, deterministic", "ChatGPT direct OAuth — " * chat_status, "OpenRouter — " * router_status, "ChatGPT / Codex — CLI sign-in")
end

function default_view!(app::App, frame::Frame)
    area = frame.area
    app.area = area
    buf = frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    w < 5 && return
    h < 5 && return
    if app.page in (:auth, :components)
        drawline!(buf, x + 1, y, w - 2, "◆ JULIA FOREVER", :accent)
    end
    if app.page == :auth
        name = app.auth_provider == :codex ? "ChatGPT / Codex" : app.auth_provider == :chatgpt ? "ChatGPT" : "OpenRouter"
        drawline!(buf, x + 1, y + 2, w - 2, "Sign in to " * name, :accent)
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
        top, bottom, first, count = settings_window(app, area)
        drawline!(buf, x, top, w, repeat("─", w), :border)
        top + 1 < bottom && drawline!(buf, x, top + 1, w, "> Provider", :text)
        labels = provider_labels()
        for offset in 0:(count - 1)
            index = first + offset
            selected = app.selected == index
            drawline!(buf, x, top + 3 + offset, w, (selected ? "→ " : "  ") * labels[index], selected ? :accent : :text)
        end
        bottom - 1 > top + 1 && drawline!(buf, x, bottom - 1, w, "  ↑↓ select · Enter use · s sign in · Esc back", :text_dim)
        drawline!(buf, x, bottom, w, repeat("─", w), :border)
        drawline!(buf, x, y + h - 2, w, app.directory, :text_dim)
        draw_footer!(buf, x, y + h - 1, w, app)
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
    messages = lock(app.session.lock) do
        copy(app.session.messages)
    end
    lines = transcript_lines!(app, messages, w)
    matches, first, count = command_menu(app, h)
    border = y + h - 5 - count
    maxlines = max(0, border - y)
    lastline = max(0, length(lines) - app.scroll)
    firstline = max(1, lastline - maxlines + 1)
    for (i, (line, style)) in enumerate(lines[firstline:lastline])
        draw_conversation_line!(buf, x, y + i - 1, w, line, style)
    end
    drawline!(buf, x, border, w, repeat("─", w), :border)
    Tachikoma.render(app.input, Rect(x, border + 1, w, 1), buf)
    drawline!(buf, x, border + 2, w, repeat("─", w), :border)
    for offset in 0:(count - 1)
        index = first + offset
        name, description = matches[index]
        selected = app.selected == index
        label = (selected ? "→ " : "  ") * rpad(name, 15) * description
        drawline!(buf, x, border + 3 + offset, w, label, selected ? :accent : :text_dim)
    end
    drawline!(buf, x, y + h - 2, w, app.directory, :text_dim)
    draw_footer!(buf, x, y + h - 1, w, app)
end

function main()
    Tachikoma.app(App(default_kernel(configured_provider()); settings_dir=config_dir()); default_bindings=false)
    return 0
end

function default_input!(app::App, event::MouseEvent)
    event.button == Tachikoma.mouse_left && event.action == Tachikoma.mouse_press || return
    area = app.area
    if app.page == :settings
        top, _, first, count = settings_window(app, area)
        offset = event.y - top - 3
        if 0 <= offset < count
            app.selected = first + offset
            update!(app, KeyEvent(:enter))
        end
    elseif app.page == :chat && app.menu
        matches, first, count = command_menu(app, area.height)
        start = area.y + area.height - 2 - count
        offset = event.y - start
        if 0 <= offset < count
            command!(app, matches[first + offset][1])
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
