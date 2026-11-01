"""Apply Pi-style Tab completion to a command, retaining a trailing argument space."""
function complete_input!(app::App)
    text = Tachikoma.text(app.input)
    if startswith(text, "/") && !occursin(' ', text)
        matches = matching_commands(app)
        if !isempty(matches)
            selected = matches[clamp(app.selected, 1, length(matches))][1]
            Tachikoma.set_text!(app.input, "/" * selected * " ")
            app.menu = false
        end
    end
    return nothing
end

function default_input!(app::App, event::KeyEvent)
    if event.key == :ctrl_c
        quit_command!(app, "")
    else
        page_input!(app, Val(app.page), event)
    end
    return nothing
end

function page_input!(app::App, page::Val, event::KeyEvent)
    event.key in (:escape, :enter) && (app.page = :chat)
    return nothing
end

function page_input!(app::App, ::Val{:chat}, event::KeyEvent)
    if event.key == :tab
        complete_input!(app)
    elseif app.menu
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


function default_input!(app::App, event::MouseEvent)
    if event.button == Tachikoma.mouse_left && event.action == Tachikoma.mouse_press
        page_mouse!(app, Val(app.page), event)
    end
    return nothing
end

page_mouse!(app::App, page::Val, event::MouseEvent) = nothing

function page_mouse!(app::App, ::Val{:chat}, event::MouseEvent)
    area = app.area
    if app.menu
        matches, first, count = command_menu(app, area.height)
        start = area.y + area.height - 2 - count
        offset = event.y - start
        if 0 <= offset < count
            command!(app, matches[first + offset][1])
        end
    else
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
