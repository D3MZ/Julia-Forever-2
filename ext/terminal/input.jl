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
"""Find the end of the next whitespace-delimited word."""
function next_word_cursor(input::TextInput)
    cursor, count = input.cursor, length(input.buffer)
    while cursor < count && isspace(input.buffer[cursor + 1])
        cursor += 1
    end
    while cursor < count && !isspace(input.buffer[cursor + 1])
        cursor += 1
    end
    return cursor
end

"""Translate a decoded modified navigation key into its editing operation."""
function modified_edit_binding(key::Symbol, modifier::Int)
    if modifier in (3, 5)
        if key == :left
            (:left, :previous_word)
        elseif key == :right
            (:right, :next_word)
        elseif key == :backspace
            (:backspace, :delete_previous_word)
        elseif key == :delete
            (:delete, :delete_next_word)
        else
            nothing
        end
    elseif modifier == 9
        if key == :left
            (:left, :line_start)
        elseif key == :right
            (:right, :line_end)
        elseif key == :backspace
            (:backspace, :delete_to_start)
        elseif key == :delete
            (:delete, :delete_to_end)
        else
            nothing
        end
    else
        nothing
    end
end

"""Map Kitty CSI-u keycodes for editing keys without assuming a keyboard layout."""
function kitty_edit_key(code::Int)
    if code in (8, 127, 57347)
        :backspace
    elseif code in (57349,)
        :delete
    elseif code == 57350
        :left
    elseif code == 57351
        :right
    else
        :unknown
    end
end

"""Recognize the modifier-bearing terminal escape sequences lost in KeyEvent."""
function csi_edit_binding(raw::AbstractVector{UInt8})
    parameters = split(String(raw[3:(end - 1)]), ';')
    final = raw[end]
    if final == UInt8('u') && length(parameters) >= 2
        code = tryparse(Int, first(split(parameters[1], ':')))
        modifier = tryparse(Int, first(split(parameters[2], ':')))
        if isnothing(code) || isnothing(modifier)
            nothing
        else
            modified_edit_binding(kitty_edit_key(code), modifier)
        end
    elseif final in (UInt8('C'), UInt8('D')) && length(parameters) == 2 && parameters[1] == "1"
        modifier = tryparse(Int, parameters[2])
        isnothing(modifier) ? nothing : modified_edit_binding(final == UInt8('D') ? :left : :right, modifier)
    elseif final == UInt8('~') && length(parameters) == 2 && parameters[1] == "3"
        modifier = tryparse(Int, parameters[2])
        isnothing(modifier) ? nothing : modified_edit_binding(:delete, modifier)
    else
        nothing
    end
end

"""Recognize legacy Meta sequences and CSI modifier sequences across terminals."""
function raw_edit_binding(raw::AbstractVector{UInt8})
    if length(raw) == 2 && raw[1] == 0x1b
        key = raw[2]
        if key == UInt8('b')
            (:unknown, :previous_word)
        elseif key == UInt8('f')
            (:unknown, :next_word)
        elseif key == UInt8('d')
            (:unknown, :delete_next_word)
        elseif key in (0x08, 0x7f)
            (:unknown, :delete_previous_word)
        else
            nothing
        end
    elseif length(raw) >= 5 && raw[1] == 0x1b && raw[2] == UInt8('[')
        csi_edit_binding(raw)
    else
        nothing
    end
end

"""Only apply raw shortcuts when the decoded event matches their expected key."""
function terminal_edit_action(event::KeyEvent, raw::AbstractVector{UInt8})
    binding = raw_edit_binding(raw)
    if !isnothing(binding) && event.key == binding[1]
        binding[2]
    else
        nothing
    end
end

"""Perform a normalized editing operation on Tachikoma's generic text input."""
function apply_prompt_edit!(input::TextInput, operation::Symbol)
    if operation == :previous_word
        input.cursor = previous_word_cursor(input)
        true
    elseif operation == :next_word
        input.cursor = next_word_cursor(input)
        true
    elseif operation == :delete_previous_word
        delete_prompt_range!(input, previous_word_cursor(input) + 1, input.cursor)
    elseif operation == :delete_next_word
        delete_prompt_range!(input, input.cursor + 1, next_word_cursor(input))
    elseif operation == :delete_to_start
        delete_prompt_range!(input, 1, input.cursor)
    elseif operation == :delete_to_end
        delete_prompt_range!(input, input.cursor + 1, length(input.buffer))
    elseif operation == :line_start
        Tachikoma.handle_key!(input, KeyEvent(:home))
    elseif operation == :line_end
        Tachikoma.handle_key!(input, KeyEvent(:end_key))
    else
        false
    end
end

"""Route decoded and optional raw terminal keys through the generic prompt editor."""
function edit_prompt_key!(input::TextInput, event::KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    if !input.focused || event.action == Tachikoma.key_release
        false
    else
        operation = terminal_edit_action(event, raw)
        if !isnothing(operation)
            apply_prompt_edit!(input, operation)
        elseif event.key == :ctrl
            edit_prompt_control!(input, event.char)
        else
            Tachikoma.handle_key!(input, event)
        end
    end
end

"""Refresh slash suggestions after editing, including control-key deletions."""
function refresh_command_menu!(app::App)
    app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
    app.selected = 1
    return nothing
end

function edit_chat_input!(app::App, event::KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    before = Tachikoma.text(app.input)
    edit_prompt_key!(app.input, event, raw)
    before == Tachikoma.text(app.input) || refresh_command_menu!(app)
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

"""Read captured terminal bytes for modifiers not retained by KeyEvent."""
function captured_key_bytes()
    return Tachikoma.raw_capture_enabled() ? Tachikoma.last_event_raw() : UInt8[]
end

function default_input!(app::App, event::KeyEvent)
    raw = captured_key_bytes()
    if event.action == Tachikoma.key_release
        nothing
    elseif event.key == :ctrl_c
        quit_command!(app, "")
    else
        page_input!(app, Val(app.page), event, raw)
    end
    Tachikoma.raw_capture_enabled() && empty!(raw)
    return nothing
end

page_input!(app::App, page::Val, event::KeyEvent) = page_input!(app, page, event, UInt8[])

function page_input!(app::App, page::Val, event::KeyEvent, raw::AbstractVector{UInt8})
    event.key in (:escape, :enter) && (app.page = :chat)
    return nothing
end

function page_input!(app::App, ::Val{:chat}, event::KeyEvent, raw::AbstractVector{UInt8})
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
            edit_chat_input!(app, event, raw)
        end
    elseif event.key == :enter
        submit!(app, Tachikoma.text(app.input))
    elseif event.key == :pageup
        app.scroll += 10
    elseif event.key == :pagedown
        app.scroll = max(0, app.scroll - 10)
    else
        edit_chat_input!(app, event, raw)
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
