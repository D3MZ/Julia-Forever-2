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

"""Compact earlier session context without blocking terminal input or losing archival history."""
function compact_command!(app::App, instructions::AbstractString)
    if app.busy || app.operations.closing[]
        app.status = "Finish or cancel the active operation first."
    else
        handle = submit_compaction!(app.session;
            instructions=String(instructions), context=ui_context(app))
        track_operation!(app, handle, :compaction_done, "Compacting…")
    end
    nothing
end

function clear_command!(app::App, arguments)
    if !app.busy && require_user_shell_idle!(app)
        clear_history!(app.session)
        clear_command_documents!(app)
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
    cancel_user_shell!(app)
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
    parsed = prompt_command_parts("/"*input)
    isnothing(parsed) ? nothing : command!(app, [parsed.name, parsed.arguments])
end

function command!(app::App, parts::AbstractVector{<:AbstractString})
    available = discover_commands(app)
    command = command_dispatch_index(available, parts[1])
    if isnothing(command)
        # Legacy programmatic commands are still callable, but hidden from Pi's slash menu.
        command = command_dispatch_index(app.commands, parts[1])
        available = app.commands
    end
    if isnothing(command)
        app.status = string("Unknown command: ", parts[1])
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
    count = min(terminal_integer(app, "autocomplete-max-visible", 5, 3, 20), length(matches), max(0, height - 5))
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
    ("quit", "Quit Julia Forever"),
]

function pi_command!(app::App, name::AbstractString, arguments)
    if name == "settings"
        settings_command!(app, arguments)
    elseif name == "model"
        model_command!(app, arguments)
    elseif name == "thinking"
        thinking_command!(app, arguments)
    elseif name in ("tree", "scoped-models", "fork", "trust", "share")
        open_menu!(app, name)
    elseif name == "login"
        login_command!(app, arguments)
    elseif name == "logout"
        open_menu!(app, "logout")
    elseif name == "resume"
        session_action!(app, :list)
    elseif name == "new"
        session_action!(app, :new)
    elseif name == "name"
        session_action!(app, :name, String(arguments))
    elseif name == "session"
        session_info_command!(app)
    elseif name == "export"
        session_action!(app, :export, String(arguments))
    elseif name == "copy"
        copy_last_assistant!(app)
    elseif name == "import"
        isempty(strip(arguments)) ? (app.status = "Use /import <JSONL path>") : session_action!(app, :import, String(arguments))
    elseif name == "bug"
        bug_report_command!(app,String(arguments))
    elseif name == "changelog"
        changelog_command!(app,String(arguments))
    elseif name == "hotkeys"
        hotkeys_command!(app;bindings=command_installed_bindings(app))
    elseif name == "clone"
        session_action!(app, :clone)
    elseif name == "compact"
        compact_command!(app, arguments)
    elseif name == "reload"
        refresh_settings!(app)
        discover_disk_resources!(app)
        app.status = "Commands, skills and provider settings refreshed"
    elseif name == "quit"
        quit_command!(app, arguments)
    end
    return nothing
end

export_session!(app::App, arguments::AbstractString) = session_action!(app, :export, String(arguments))

function register_default_commands!(app::App)
    for (name, description) in PI_TERMINAL_COMMANDS
        register_command!(app, CommandSpec(name, description,
            (app, args) -> pi_command!(app, name, args); origin=:builtin))
    end
    # Retain Julia-native commands as a visible superset of the reference.
    register_command!(app, CommandSpec("providers", "Choose a configured provider", providers_command!))
    register_command!(app, CommandSpec("components", "Inspect installed components",
        components_command!))
    register_command!(app, CommandSpec("julia", "Run a Julia expression",
        julia_command!))
    register_command!(app, CommandSpec("clear", "Clear conversation",
        clear_command!))
    register_command!(app, CommandSpec("cancel", "Cancel active operation",
        cancel_command!))
    return app
end

"""Copy only an actual retained assistant reply, never a status or synthetic success message."""
function copy_last_assistant!(app::App)
    messages = history_snapshot(app.session).messages
    index = findlast(message -> message.role == :assistant, messages)
    if isnothing(index)
        app.status = "No assistant message to copy"
    else
        copy_terminal_text!(app, messages[index].content)
    end
    nothing
end
