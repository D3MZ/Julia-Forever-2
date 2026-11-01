"""Delete a prompt span and preserve the cursor and optional widget validation."""
function delete_prompt_range!(input::TextInput, first::Int, last::Int)
    if first <= last
        deleteat!(input.buffer, first:last)
        input.cursor = first - 1
        if !isnothing(input.validator)
            result = input.validator(Tachikoma.text(input))
            input.error_msg = isnothing(result) ? "" : String(result)
        end
    end
    return true
end

"""Find the beginning of the preceding whitespace-delimited word."""
function previous_word_cursor(input::TextInput)
    cursor = input.cursor
    while cursor > 0 && isspace(input.buffer[cursor])
        cursor -= 1
    end
    while cursor > 0 && !isspace(input.buffer[cursor])
        cursor -= 1
    end
    return cursor
end

"""Handle portable Readline-style control keys for any TUI prompt."""
function edit_prompt_control!(input::TextInput, key::Char)
    if key == 'u'
        delete_prompt_range!(input, 1, input.cursor)
    elseif key == 'k'
        delete_prompt_range!(input, input.cursor + 1, length(input.buffer))
    elseif key == 'w'
        delete_prompt_range!(input, previous_word_cursor(input) + 1, input.cursor)
    elseif key == 'a'
        Tachikoma.handle_key!(input, KeyEvent(:home))
    elseif key == 'e'
        Tachikoma.handle_key!(input, KeyEvent(:end_key))
    elseif key == 'b'
        Tachikoma.handle_key!(input, KeyEvent(:left))
    elseif key == 'f'
        Tachikoma.handle_key!(input, KeyEvent(:right))
    elseif key == 'd'
        Tachikoma.handle_key!(input, KeyEvent(:delete))
    elseif key == 'h'
        Tachikoma.handle_key!(input, KeyEvent(:backspace))
    else
        false
    end
end

"""Route decoded terminal keys through the reusable prompt editor."""
function edit_prompt_key!(input::TextInput, event::KeyEvent)
    if event.action == Tachikoma.key_release
        false
    elseif event.key == :ctrl
        edit_prompt_control!(input, event.char)
    else
        Tachikoma.handle_key!(input, event)
    end
end

"""Refresh slash suggestions after editing, including control-key deletions."""
function refresh_command_menu!(app::App)
    app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
    app.selected = 1
    return nothing
end

function edit_chat_input!(app::App, event::KeyEvent)
    edit_prompt_key!(app.input, event)
    refresh_command_menu!(app)
    return nothing
end

"""Complete the selected slash command without executing it."""
function complete_command!(app::App, matches::Vector{Tuple{String,String}})
    if !isempty(matches)
        name = matches[clamp(app.selected, 1, length(matches))][1]
        Tachikoma.set_text!(app.input, "/" * name * " ")
        app.menu = false
        app.selected = 1
    end
    return nothing
end

function default_input!(app::App, event::KeyEvent)
    if event.action == Tachikoma.key_release
        nothing
    elseif event.key == :ctrl_c
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
    if app.menu
        matches = matching_commands(app)
        if event.key == :escape
            app.menu = false
            Tachikoma.clear!(app.input)
        elseif event.key == :up && !isempty(matches)
            app.selected = mod1(app.selected - 1, length(matches))
        elseif event.key == :down && !isempty(matches)
            app.selected = mod1(app.selected + 1, length(matches))
        elseif event.key == :backtab && !isempty(matches)
            app.selected = mod1(app.selected - 1, length(matches))
        elseif event.key == :tab && !isempty(matches)
            complete_command!(app, matches)
        elseif event.key == :enter && !isempty(matches)
            command!(app, matches[clamp(app.selected, 1, length(matches))][1])
        else
            edit_chat_input!(app, event)
        end
    elseif event.key == :enter
        submit!(app, Tachikoma.text(app.input))
    elseif event.key == :pageup
        app.scroll += 10
    elseif event.key == :pagedown
        app.scroll = max(0, app.scroll - 10)
    else
        edit_chat_input!(app, event)
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
