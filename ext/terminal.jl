const TranscriptContent = Union{String,Vector{Tachikoma.Span}}
const TranscriptLine = Tuple{TranscriptContent,Symbol}

struct CommandSpec{F}
    name::String
    description::String
    action::F
end
CommandSpec(name::AbstractString, description::AbstractString, action) = CommandSpec(String(name), String(description), action)

mutable struct EventHandler{F}
    action::F
end

mutable struct App{S<:Session} <: Model
    session::S
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
    auth_task::Union{Task,Nothing}
    auth_url::String
    auth_provider::Symbol
    settings_dir::String
    directory::String
    commands::Vector{CommandSpec}
    event_handlers::Dict{Symbol,Vector{EventHandler}}
    providers::Vector{ProviderDescriptor}
    provider_labels::Vector{String}
    active_turn::Union{TaskHandle,Nothing}
    transcript_width::Int
    transcript_revision::UInt
    transcript_messages::Vector{Message}
    transcript_chunks::Vector{Vector{TranscriptLine}}
    transcript_offsets::Vector{Int}
    transcript_lines::Vector{TranscriptLine}
    closing::Threads.Atomic{Bool}
    event_lock::ReentrantLock
    watchers::Vector{Task}
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

App(kernel::Kernel=default_kernel(); kwargs...) = App(Session(kernel); kwargs...)

function App(session::Session; settings_dir::AbstractString=config_dir())
    kernel = session.kernel
    input = TextInput(; label="", style=pi_style(:text), cursor_style=Tachikoma.Style(; fg=Tachikoma.ColorRGB(36, 41, 49), bg=Tachikoma.ColorRGB(255, 255, 255)))
    app = App(session, input, :chat, false, 1, false, false, TaskQueue(; capacity=typemax(Int)), "Ready", 0, Rect(),
        nothing, nothing, "", :none, String(settings_dir), directory_label(), CommandSpec[], Dict{Symbol,Vector{EventHandler}}(),
        ProviderDescriptor[], String[], nothing, 0, typemax(UInt), Message[], Vector{TranscriptLine}[], Int[], TranscriptLine[], Threads.Atomic{Bool}(false), ReentrantLock(), Task[])
    isnothing(component(kernel, :input)) && install!(kernel, ComponentSpec(:input, default_input!))
    isnothing(component(kernel, :view)) && install!(kernel, ComponentSpec(:view, default_view!))
    register_command!(app, CommandSpec("settings", "Choose a provider", settings_command!))
    register_command!(app, CommandSpec("components", "Inspect installed components", components_command!))
    register_command!(app, CommandSpec("julia", "Run a Julia expression", julia_command!))
    register_command!(app, CommandSpec("clear", "Clear the conversation", clear_command!))
    register_command!(app, CommandSpec("quit", "Exit", quit_command!))
    register_command!(app, CommandSpec("cancel", "Cancel the active operation", cancel_command!))
    register_event_handler!(app, :turn, operation_finished!)
    register_event_handler!(app, :evaluation, operation_finished!)
    register_event_handler!(app, :auth_url, auth_url_received!)
    register_event_handler!(app, :auth_done, auth_finished!)
    refresh_settings!(app)
    return app
end

"""Register or replace a slash command without replacing the input handler."""
function register_command!(app::App, command::CommandSpec)
    index = findfirst(existing -> existing.name == command.name, app.commands)
    if isnothing(index)
        push!(app.commands, command)
    else
        app.commands[index] = command
    end
    return command
end

function remove_command!(app::App, name::AbstractString)
    filter!(command -> command.name != name, app.commands)
    return app
end

"""Subscribe to one background event ID; multiple handlers compose in registration order."""
function register_event_handler!(app::App, id::Symbol, action)
    handler = EventHandler(action)
    push!(get!(app.event_handlers, id, EventHandler[]), handler)
    return handler
end

function remove_event_handler!(app::App, id::Symbol, handler::EventHandler)
    handlers = get(app.event_handlers, id, nothing)
    isnothing(handlers) || filter!(existing -> existing !== handler, handlers)
    return app
end

matching_commands(app::App) = Tuple{String,String}[(command.name, command.description) for command in app.commands if startswith(command.name, replace(Tachikoma.text(app.input), r"^/" => ""))]
task_queue(app::App) = app.queue
should_quit(app::App) = app.quit

function refresh_settings!(app::App)
    app.providers = provider_descriptors()
    app.provider_labels = [descriptor.label * (isempty(status) ? "" : " — " * status) for descriptor in app.providers for status in (String(Base.invokelatest(descriptor.status, app.settings_dir)),)]
    app.selected = isempty(app.providers) ? 1 : clamp(app.selected, 1, length(app.providers))
    return app
end

function provider_selection(app::App)
    identity = with_component(app.session.kernel, :provider) do provider
        Base.invokelatest(provider_id, provider)
    end
    selected = findfirst(descriptor -> descriptor.id == identity, app.providers)
    return isnothing(selected) ? 1 : selected
end

function settings_command!(app::App, arguments)
    refresh_settings!(app)
    app.page = :settings
    app.selected = provider_selection(app)
    return nothing
end
components_command!(app::App, arguments) = (app.page = :components; nothing)

function clear_command!(app::App, arguments)
    app.busy && return nothing
    clear_history!(app.session)
    app.scroll = 0
    return nothing
end

function quit_command!(app::App, arguments)
    cleanup!(app)
    app.quit = true
    return nothing
end

function cancel_command!(app::App, arguments)
    active_turn, auth_flow = app.active_turn, app.auth_flow
    isnothing(active_turn) || cancel!(active_turn)
    isnothing(auth_flow) || cancel_auth!(auth_flow)
    app.busy && (app.status = "Cancelling…")
    return nothing
end

function command!(app::App, input::AbstractString)
    app.menu = false
    Tachikoma.clear!(app.input)
    parts = split(strip(input); limit=2)
    isempty(parts) && return nothing
    index = findfirst(command -> command.name == parts[1], app.commands)
    if isnothing(index)
        app.status = "Unknown command: " * String(parts[1])
        return nothing
    end
    arguments = length(parts) == 2 ? parts[2] : ""
    return Base.invokelatest(app.commands[index].action, app, arguments)
end

function enqueue_event!(app::App, event::TaskEvent)
    accepted = lock(app.event_lock) do
        app.closing[] && return false
        put!(app.queue.channel, event)
        return true
    end
    accepted || return false
    callback = app.queue.on_ready
    isnothing(callback) || callback()
    return true
end

function notify_completion!(app::App, id::Symbol, task::Task, value)
    for watcher in app.watchers
        istaskdone(watcher) && fetch(watcher)
    end
    filter!(watcher -> !istaskdone(watcher), app.watchers)
    watcher = Threads.@spawn begin
        wait(task; throw=false)
        enqueue_event!(app, TaskEvent(id, value))
    end
    push!(app.watchers, watcher)
    return watcher
end

function ui_context(app::App)
    return ExecutionContext(; event_sink=event -> enqueue_event!(app, TaskEvent(event.kind, event.data)))
end

function track_operation!(app::App, handle::TaskHandle, id::Symbol, status::AbstractString)
    app.active_turn = handle
    app.busy = true
    app.status = String(status)
    notify_completion!(app, id, handle.task, handle)
    return handle
end

function julia_command!(app::App, code::AbstractString)
    if isempty(strip(code))
        Tachikoma.set_text!(app.input, "/julia ")
        return nothing
    end
    app.busy && return nothing
    append_message!(app.session, Message(:user, "/julia " * code))
    handle = submit_evaluation!(app.session, code; context=ui_context(app))
    return track_operation!(app, handle, :evaluation, "Running Julia…")
end

function submit!(app::App, prompt::AbstractString)
    isempty(strip(prompt)) && return nothing
    app.scroll = 0
    if startswith(prompt, "/")
        return command!(app, SubString(prompt, nextind(prompt, firstindex(prompt))))
    end
    app.busy && return nothing
    Tachikoma.clear!(app.input)
    handle = submit_turn!(app.session, prompt; context=ui_context(app))
    return track_operation!(app, handle, :turn, "Thinking…")
end

function operation_finished!(app::App, handle::TaskHandle)
    app.active_turn === handle || return nothing
    result = fetch(handle)
    app.active_turn = nothing
    app.busy = false
    app.status = result.ok ? "Ready" : result.text
    return nothing
end

function start_sign_in!(app::App, provider::Symbol; action=nothing)
    dir = app.settings_dir
    app.busy && return nothing
    descriptor = provider_descriptor(provider)
    selected_action = isnothing(action) ? (isnothing(descriptor) ? nothing : descriptor.auth) : action
    isnothing(selected_action) && return nothing
    flow = AuthFlow()
    app.auth_flow = flow
    app.auth_url = ""
    app.auth_provider = provider
    app.busy = true
    app.page = :auth
    app.status = "Opening browser for sign-in…"
    task = Threads.@spawn begin
        announce = url -> enqueue_event!(app, TaskEvent(:auth_url, (flow, url)))
        Base.invokelatest(selected_action, flow, provider, dir; announce)
    end
    app.auth_task = task
    notify_completion!(app, :auth_done, task, (flow, task))
    return task
end

function auth_url_received!(app::App, value)
    flow, url = value
    if app.auth_flow === flow && active_auth(flow)
        app.auth_url = url
        app.status = "Complete sign-in in your browser."
    end
    return nothing
end

function auth_finished!(app::App, value)
    flow, task = value
    app.auth_flow === flow || return nothing
    result = fetch(task)
    app.busy = false
    app.auth_flow = nothing
    app.auth_task = nothing
    if !active_auth(flow)
        app.status = "Sign-in cancelled."
    else
        app.status = result.reason
        if result.ok
            provider = provider_from_name(app.auth_provider; dir=app.settings_dir)
            isnothing(provider) || install!(app.session.kernel, ComponentSpec(:provider, provider))
            remember_provider!(app, app.auth_provider)
        end
    end
    refresh_settings!(app)
    app.page == :auth && (app.page = :settings)
    app.auth_url = ""
    return nothing
end

function update!(app::App, event::TaskEvent)
    handlers = get(app.event_handlers, event.id, nothing)
    isnothing(handlers) && return nothing
    for handler in copy(handlers)
        Base.invokelatest(handler.action, app, event.value)
    end
    return nothing
end

function select_provider!(app::App)
    isempty(app.providers) && return nothing
    descriptor = app.providers[app.selected]
    provider = provider_from_name(descriptor.id; dir=app.settings_dir)
    isnothing(provider) && return nothing
    install!(app.session.kernel, ComponentSpec(:provider, provider))
    remember_provider!(app, descriptor.id)
    app.status = descriptor.label * (isnothing(descriptor.auth) ? " selected" : " selected — sign in from settings with s")
    app.page = :chat
    return nothing
end

function default_input!(app::App, event::KeyEvent)
    if event.key == :ctrl_c
        quit_command!(app, "")
        return nothing
    elseif app.page == :auth
        flow = app.auth_flow
        if event.key == :escape && !isnothing(flow)
            cancel_auth!(flow)
            app.status = "Cancelling sign-in…"
            app.page = :settings
        end
        return nothing
    elseif app.page == :settings
        if event.key == :escape
            app.page = :chat
        elseif event.key in (:up, :down) && !isempty(app.providers)
            app.selected = mod1(app.selected + (event.key == :up ? -1 : 1), length(app.providers))
        elseif event.key == :char && event.char == 's' && !isempty(app.providers)
            descriptor = app.providers[app.selected]
            isnothing(descriptor.auth) || start_sign_in!(app, descriptor.id; action=descriptor.auth)
        elseif event.key == :enter
            select_provider!(app)
        end
        return nothing
    elseif app.page != :chat
        event.key in (:escape, :enter) && (app.page = :chat)
        return nothing
    end
    if app.menu
        matches = matching_commands(app)
        if event.key == :escape
            app.menu = false
            Tachikoma.clear!(app.input)
        elseif event.key == :up && !isempty(matches)
            app.selected = mod1(app.selected - 1, length(matches))
        elseif event.key == :down && !isempty(matches)
            app.selected = mod1(app.selected + 1, length(matches))
        elseif event.key == :enter && !isempty(matches)
            command!(app, matches[clamp(app.selected, 1, length(matches))][1])
        else
            Tachikoma.handle_key!(app.input, event)
            app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
            app.selected = 1
        end
    elseif event.key == :enter
        submit!(app, Tachikoma.text(app.input))
    elseif event.key == :pageup
        app.scroll += 10
    elseif event.key == :pagedown
        app.scroll = max(0, app.scroll - 10)
    else
        Tachikoma.handle_key!(app.input, event)
        app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
        app.menu && (app.selected = 1)
    end
    return nothing
end

remember_provider!(app::App, provider::Symbol) = save_provider!(app.settings_dir, provider)

function draw_footer!(buffer, x, y, width, app::App)
    detail = with_component(app.session.kernel, :provider) do provider
        String(Base.invokelatest(provider_detail, provider))
    end
    right = isnothing(detail) ? "No provider" : detail
    left = usage_label(app.session)
    app.status == "Ready" || (left = isempty(left) ? app.status : left * " · " * app.status)
    drawline!(buffer, x, y, width, left, :text_dim)
    available = max(0, width - textwidth(left) - (isempty(left) ? 0 : 1))
    clipped = Tachikoma.truncate_to_width(right, available)
    drawline!(buffer, x + width - textwidth(clipped), y, textwidth(clipped), clipped, :text_dim)
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

function message_layout_key(messages, index)
    message = messages[index]
    code = message.role == :assistant && message.kind == :code
    paired = code && index < length(messages) && messages[index + 1].role == :code_result
    continuation = message.role == :code_result && index > 1 && messages[index - 1].kind == :code
    return message, paired, continuation
end

function message_lines(messages, index, width)
    message, paired, continuation = message_layout_key(messages, index)
    code = message.role == :assistant && message.kind == :code
    style = message.role == :user ? :user_message : (message.role == :code_result || code) ? :code_result : :text
    lines = TranscriptLine[]
    style in (:user_message, :code_result) && !continuation && push!(lines, ("", style))
    if message.role == :assistant && !code
        append!(lines, ((line, :markdown) for line in markdown_lines(message.content, max(1, width - 2))))
    else
        for line in split(message.content, '\n'; keepempty=true)
            append!(lines, ((chunk, style) for chunk in wrap_conversation_line(line, max(1, width - 2))))
        end
    end
    style in (:user_message, :code_result) && push!(lines, ("", style))
    paired || push!(lines, ("", :text))
    return lines
end

function conversation_lines(messages, width)
    lines = TranscriptLine[]
    for index in eachindex(messages)
        append!(lines, message_lines(messages, index, width))
    end
    return lines
end

function transcript_lines!(app::App, width::Int)
    snapshot = history_snapshot(app.session, app.transcript_revision)
    width_changed = app.transcript_width != width
    isnothing(snapshot) && !width_changed && return app.transcript_lines
    previous_messages = app.transcript_messages
    messages = isnothing(snapshot) ? previous_messages : snapshot.messages
    first_changed = width_changed ? 1 : max(1, min(snapshot.changed_from, length(messages) + 1) - 1)
    first_changed = min(first_changed, length(app.transcript_chunks) + 1)
    prefix = first_changed - 1
    resize!(app.transcript_lines, prefix == 0 ? 0 : app.transcript_offsets[prefix])
    previous_count = length(app.transcript_chunks)
    for index in first_changed:length(messages)
        reusable = !width_changed && index <= length(previous_messages) && index <= previous_count && message_layout_key(previous_messages, index) == message_layout_key(messages, index)
        lines = reusable ? app.transcript_chunks[index] : message_lines(messages, index, width)
        append!(app.transcript_lines, lines)
        if index <= previous_count
            app.transcript_chunks[index] = lines
            app.transcript_offsets[index] = length(app.transcript_lines)
        else
            push!(app.transcript_chunks, lines)
            push!(app.transcript_offsets, length(app.transcript_lines))
        end
    end
    resize!(app.transcript_chunks, length(messages))
    resize!(app.transcript_offsets, length(messages))
    app.transcript_width = width
    app.transcript_messages = messages
    isnothing(snapshot) || (app.transcript_revision = snapshot.revision)
    return app.transcript_lines
end

function command_menu(app::App, height::Int)
    matches = app.menu ? matching_commands(app) : Tuple{String,String}[]
    count = min(5, length(matches), max(0, height - 5))
    first = max(1, min(app.selected - count + 1, length(matches) - count + 1))
    return matches, first, count
end

settings_top(area::Rect) = max(area.y, area.y + area.height - 11)

function settings_window(app::App, area::Rect)
    top = settings_top(area)
    bottom = area.y + area.height - 3
    count = min(length(app.providers), max(0, bottom - top - 4))
    first = max(1, min(app.selected - count + 1, length(app.providers) - count + 1))
    return top, bottom, first, count
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
        descriptor = provider_descriptor(app.auth_provider)
        name = isnothing(descriptor) ? string(app.auth_provider) : descriptor.label
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
        labels = app.provider_labels
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
    lines = transcript_lines!(app, w)
    matches, first, count = command_menu(app, h)
    border = y + h - 5 - count
    maxlines = max(0, border - y)
    lastline = max(0, length(lines) - app.scroll)
    firstline = max(1, lastline - maxlines + 1)
    for (i, (line, style)) in enumerate(@view lines[firstline:lastline])
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
    return with_component(app.session.kernel, name; fallback) do callable
        Base.invokelatest(callable, app, argument)
    end
end

update!(app::App, event::Union{KeyEvent,MouseEvent}) = ui_component(app, :input, default_input!, event)
view(app::App, frame::Frame) = ui_component(app, :view, default_view!, frame)

function cleanup!(app::App)
    lock(app.event_lock) do
        app.closing[] = true
        empty!(app.queue.channel)
    end
    active_turn, auth_flow = app.active_turn, app.auth_flow
    isnothing(active_turn) || cancel!(active_turn)
    isnothing(auth_flow) || cancel_auth!(auth_flow)
    return nothing
end

function finish_shutdown!(app::App)
    cleanup!(app)
    close(app.session)
    auth_task = app.auth_task
    isnothing(auth_task) || wait(auth_task)
    foreach(wait, app.watchers)
    empty!(app.watchers)
    return nothing
end

function terminal_app(; settings_dir::AbstractString=config_dir())
    provider = configured_provider(settings_dir)
    kernel = isnothing(provider) ? Kernel() : default_kernel(provider)
    app = App(kernel; settings_dir)
    if isnothing(provider)
        app.page = :settings
        app.status = "Configured provider is unavailable. Choose a provider."
    end
    return app
end

function JuliaForever2.main(; settings_dir::AbstractString=config_dir())
    app = terminal_app(; settings_dir)
    Tachikoma.app(app; default_bindings=false)
    finish_shutdown!(app)
    close(app.session.kernel)
    return 0
end
