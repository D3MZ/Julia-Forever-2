"""Register or replace a slash command without replacing the input handler."""
function register_command!(app::App, command::CommandSpec)
    index = findfirst(existing -> existing.name == command.name, app.commands)
    if isnothing(index)
        push!(app.commands, command)
    elseif app.commands[index].origin != :builtin || command.origin == :builtin
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

matching_commands(app::App) = Tuple{String,String}[(command.name, command.description)
    for command in discover_commands(app)
    if startswith(command.name, replace(Tachikoma.text(app.input), r"^/" => ""))]
task_queue(app::App) = app.queue
should_quit(app::App) = app.quit

function settings_command!(app::App, arguments)
    open_menu!(app, "settings")
    return nothing
end

function providers_command!(app::App, arguments)
    refresh_settings!(app)
    app.page = :settings
    app.selected = provider_selection(app)
    return nothing
end
components_command!(app::App, arguments) = (app.page = :components; nothing)

function clear_command!(app::App, arguments)
    if !app.busy
        clear_history!(app.session)
        clear_preview!(app)
        app.scroll = 0
    end
    nothing
end
function quit_command!(app::App, arguments)
    cleanup!(app)
    app.quit = true
    return nothing
end

function cancel_command!(app::App, arguments)
    active_turn, auth_flow = app.operations.active, app.settings.auth_flow
    isnothing(active_turn) || cancel!(active_turn)
    isnothing(auth_flow) || cancel_auth!(auth_flow)
    clear_preview!(app)
    app.busy && (app.status = "Cancelling…")
    return nothing
end

function command!(app::App, input::AbstractString)
    app.menu = false
    Tachikoma.clear!(app.input)
    parts = split(strip(input); limit=2)
    isempty(parts) ? nothing : command!(app, parts)
end

function command!(app::App, parts::AbstractVector)
    command = findfirst(item -> item.name == parts[1], discover_commands(app))
    available = discover_commands(app)
    if isnothing(command)
        # Legacy programmatic commands are still callable, but hidden from Pi's slash menu.
        command = findfirst(item -> item.name == parts[1], app.commands)
        available = app.commands
    end
    if isnothing(command)
        app.status = "Unknown command: " * String(parts[1])
        nothing
    else
        arguments = length(parts) == 2 ? parts[2] : ""
        Base.invokelatest(available[command].action, app, arguments)
    end
end
function update!(app::App, event::TaskEvent)
    handlers = get(app.event_handlers, event.id, nothing)
    if !isnothing(handlers)
        for handler in copy(handlers)
            Base.invokelatest(handler.action, app, event.value)
        end
    end
    nothing
end
function command_menu(app::App, height::Int)
    matches = app.menu ? matching_commands(app) : Tuple{String,String}[]
    count = min(5, length(matches), max(0, height - 5))
    first = max(1, min(app.selected - count + 1, length(matches) - count + 1))
    return matches, first, count
end


function page_view!(app::App, ::Val{:components}, frame::Frame)
    area, buf = frame.area, frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    drawline!(buf, x + 1, y, w - 2, "◆ JULIA FOREVER", :accent)
    drawline!(buf, x + 1, y + 2, w - 2, "Components", :accent)
    components = component_snapshot(app.session.kernel)
    for (i, entry) in enumerate(components[1:min(length(components), max(0, h - 5))])
        drawline!(buf, x + 2, y + 3 + i, w - 3, string(entry.name), :text)
    end
    drawline!(buf, x + 1, y + h - 1, w - 2, "esc back", :text_dim)
    return
end

const PI_TERMINAL_COMMANDS = [
    ("settings", "Open settings menu"),
    ("model", "Select model (opens selector UI)"),
    ("tree", "Navigate session tree (switch branches)"),
    ("thinking", "Set thinking level"),
    ("scoped-models", "Enable/disable models for Ctrl+P cycling"),
    ("export", "Export session (HTML default, or specify path: .html/.jsonl)"),
    ("import", "Import a JSONL session, preserving its ID and working directory"),
    ("share", "Share session via a Radius artifact or a GitHub gist"),
    ("bug", "Report a bug to the Pi developers"),
    ("copy", "Copy last agent message to clipboard"),
    ("name", "Set session display name"),
    ("session", "Show session info and stats"),
    ("changelog", "Show changelog entries"),
    ("hotkeys", "Show all keyboard shortcuts"),
    ("fork", "Create a new fork from a previous user message"),
    ("clone", "Duplicate the current session at the current position"),
    ("trust", "Save project trust decision for future sessions"),
    ("login", "Configure provider authentication"),
    ("logout", "Remove provider authentication"),
    ("new", "Start a new session"),
    ("compact", "Manually compact the session context"),
    ("resume", "Resume another session"),
    ("reload", "Reload keybindings, extensions, skills, prompts, themes, and context files"),
    ("quit", "Quit Pi"),
]

function pi_command!(app::App, name::AbstractString, arguments)
    if name == "settings"
        settings_command!(app, arguments)
    elseif name in ("model", "tree", "thinking", "scoped-models", "fork", "trust", "resume", "share")
        open_menu!(app, name)
    elseif name == "login"
        open_menu!(app, "login")
    elseif name == "logout"
        open_menu!(app, "logout")
    elseif name == "new"
        if !app.busy
            clear_history!(app.session)
            clear_preview!(app)
            app.scroll = 0
            app.status = "✓ New session started"
            app.page = :chat
        end
    elseif name == "name"
        app.menus.preferences["session-name"] = String(strip(arguments))
        app.status = isempty(strip(arguments)) ? "Use /name <title>" : "Session named: " * String(strip(arguments))
    elseif name == "session"
        app.status = string("Session: ", length(history_snapshot(app.session).messages), " messages · ", usage_label(app.session))
    elseif name == "export"
        export_session!(app, arguments)
    elseif name == "copy"
        app.status = "Clipboard integration is not configured"
    elseif name == "import"
        app.status = "Session import requires a JSONL file path"
    elseif name == "bug"
        app.status = "Bug reporting is not configured"
    elseif name == "changelog"
        app.status = "Changelog is not bundled"
    elseif name == "hotkeys"
        app.status = "Enter send · Tab complete · ↑↓ navigate · Esc back · Ctrl+C quit"
    elseif name == "clone"
        app.status = "Session duplication requires persistent session storage"
    elseif name == "compact"
        app.status = "Context compaction is not configured"
    elseif name == "reload"
        refresh_settings!(app)
        discover_disk_resources!(app)
        app.status = "Commands, skills and provider settings refreshed"
    elseif name == "quit"
        quit_command!(app, arguments)
    end
    return nothing
end

function export_session!(app::App, arguments)
    path = strip(arguments)
    path = isempty(path) ? joinpath(pwd(), "session.html") : String(path)
    if endswith(path, ".jsonl")
        lines = [JSON.json(Dict("role" => String(message.role), "content" => message.content))
            for message in history_snapshot(app.session).messages]
        write(path, join(lines, "\n") * "\n")
    elseif endswith(path, ".html")
        html_escape(value) = replace(value, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
        content = join(["<p><strong>" * html_escape(String(message.role)) *
            "</strong></p><pre>" * html_escape(message.content) * "</pre>"
            for message in history_snapshot(app.session).messages], "\n")
        write(path, "<!doctype html><meta charset=\"utf-8\"><title>Session</title>\n" * content)
    else
        app.status = "Export path must end in .html or .jsonl"
        return nothing
    end
    app.status = "Exported session: " * path
    return nothing
end

function register_default_commands!(app::App)
    for (name, description) in PI_TERMINAL_COMMANDS
        register_command!(app, CommandSpec(name, description,
            (app, args) -> pi_command!(app, name, args); origin=:builtin))
    end
    # Retain legacy commands for integrations without exposing them in the TUI.
    register_command!(app, CommandSpec("components", "Inspect installed components",
        components_command!; visible=false))
    register_command!(app, CommandSpec("julia", "Run a Julia expression",
        julia_command!; visible=false))
    register_command!(app, CommandSpec("clear", "Clear conversation",
        clear_command!; visible=false))
    register_command!(app, CommandSpec("cancel", "Cancel active operation",
        cancel_command!; visible=false))
    return app
end
