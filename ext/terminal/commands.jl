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

function settings_command!(app::App, arguments)
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
    index = findfirst(command -> command.name == parts[1], app.commands)
    if isnothing(index)
        app.status = "Unknown command: " * String(parts[1])
        nothing
    else
        arguments = length(parts) == 2 ? parts[2] : ""
        Base.invokelatest(app.commands[index].action, app, arguments)
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
