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
    elseif code == 57349
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
    if event.key in (:unknown, :backspace, :delete, :left, :right)
        binding = raw_edit_binding(raw)
        !isnothing(binding) && event.key == binding[1] ? binding[2] : nothing
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

"""Retain legacy word-edit bindings while native input owns grapheme navigation."""
function edit_menu_search!(input::MenuSearchInput, event::KeyEvent, raw::AbstractVector{UInt8})
    operation = terminal_edit_action(event, raw)
    if !isnothing(operation) || (event.key == :ctrl && event.char == 'w')
        legacy = TextInput(; label="")
        Tachikoma.set_text!(legacy, input.value)
        legacy.cursor = length(menu_search_prefix(input))
        edit_prompt_key!(legacy, event, raw)
        input.value = Tachikoma.text(legacy)
        input.cursor = length(menu_search_graphemes(String(legacy.buffer[1:legacy.cursor])))
        :handled
    else
        menu_search_input!(input, event, raw)
    end
end

"""Recognize bracketed-paste packets before menu/global shortcut handling."""
menu_search_pasting(input::MenuSearchInput, raw::AbstractVector{UInt8}) =
    input.pasting || occursin("\e[200~", String(copy(raw)))

"""Refresh slash suggestions after editing, including control-key deletions."""
function refresh_command_menu!(app::App)
    app.menu = startswith(Tachikoma.text(app.input), "/") && !isempty(matching_commands(app))
    app.selected = 1
    return nothing
end

function edit_chat_input!(app::App, event::KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    chat_host_packet!(app,menu_packet(event,raw))
    nothing
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
    elseif app.page == :pi_menu && app.menus.path in (["settings"], ["settings", "warnings"]) && menu_search_pasting(app.menus.search, raw)
        menu_search_input!(app.menus.search, event, raw)
        app.menus.cursor = 1
    elseif app.page==:chat && chat_host_pasting(app,menu_packet(event,raw))
        page_input!(app,Val(:chat),event,raw)
    elseif terminal_viewport_key!(app,event,raw)
        nothing
    elseif app.page==:auth
        page_input!(app,Val(:auth),event,raw)
    elseif event.key == :ctrl_c && app.page==:bug_report
        bug_report_input!(app,"\x03")
    elseif event.key == :ctrl_c
        if app.page == :pi_menu
            selected_event = app.menus.path in (["model"], ["scoped-models"], ["thinking"]) ? event : KeyEvent(:escape)
            page_input!(app, Val(:pi_menu), selected_event, raw)
        elseif app.page==:chat
            chat_host_interrupt!(app)
        else
            quit_command!(app, "")
        end
    else
        page_input!(app, Val(app.page), event, raw)
    end
    Tachikoma.raw_capture_enabled() && empty!(raw)
    return nothing
end

"""Preserve existing page-specific input handlers when raw bytes are unused."""
page_input!(app::App, page::Val, event::KeyEvent, raw::AbstractVector{UInt8}) = page_input!(app, page, event)

function page_input!(app::App, page::Val, event::KeyEvent)
    event.key in (:escape, :enter) && (app.page = :chat)
    return nothing
end

function page_input!(app::App, ::Val{:chat}, event::KeyEvent, raw::AbstractVector{UInt8})
    packet = menu_packet(event, raw)
    if chat_host_pasting(app,packet)
        chat_host_packet!(app,packet)
    elseif pending_follow_up_key(packet)
        chat_host_follow_up!(app)
    elseif pending_dequeue_key(packet)
        restore_pending_input!(app)
    elseif event.key == :escape && app.busy && !chat_host_completion_open(app)
        restore_pending_input!(app; abort=true)
    elseif event.key == :escape && !isnothing(app.operations.shell.active) && !chat_host_completion_open(app)
        cancel_user_shell!(app)
    elseif menu_packet(event, raw) == "\x18"
        terminal_viewport_copy!(app) || copy_last_assistant!(app)
    elseif menu_packet(event, raw) == "\x0f"
        state = app.transcript.display
        session_display_transition!(state, state.expand_all ? :collapse_all : :expand_all)
        user_shell_expand!(app,state.expand_all)
        controls=app.menus.startup
        isnothing(controls) || startup_set_expanded!(controls.document,state.expand_all;on_notice=message->frontend_notice!(app,message))
    elseif menu_packet(event, raw) == "\x14"
        toggle_thinking_visibility!(app)
    elseif menu_packet(event, raw) in ("\x10", "\e[112;6u", "\e[80;6u", "\ep")
        packet = menu_packet(event, raw)
        cycle_terminal_model!(app, packet == "\x10" ? 1 : -1)
    elseif event.key == :backtab || menu_packet(event, raw) == "\e[Z"
        cycle_terminal_thinking!(app)
    elseif menu_packet(event, raw) == "\x0c"
        open_menu!(app, "model")
    elseif event.key in (:enter,:pageup,:pagedown)
        chat_host_packet!(app,packet)
    else
        edit_chat_input!(app, event, raw)
    end
    return nothing
end


function default_input!(app::App, event::MouseEvent)
    terminal_viewport_mouse!(app,event)
    nothing
end

page_mouse!(app::App, page::Val, event::MouseEvent) = nothing

function page_mouse!(app::App,::Val{:chat},event::MouseEvent;click::Bool=event.action==Tachikoma.mouse_release)
    geometry=startup_editor_geometry(app)
    row=startup_editor_row(app,event,geometry)
    state=chat_completion_state!(app)
    wheel=event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
    type=wheel ? :wheel : event.action==Tachikoma.mouse_press ? :press : event.action==Tachikoma.mouse_release ? (click ? :click : :release) : :move
    button=event.button==Tachikoma.mouse_left ? :left : :none
    delta=terminal_viewport_wheel(app,event)
    result=row<0 ? (handled=false,) : chat_completion_mouse!(state,type,button,event.x-app.area.x,row,app.area.width;
        height=app.area.height,padding=terminal_integer(app,"editor-padding",0,0,3),wheel_delta=delta)
    chat_completion_ready!(app,nothing)
    result.handled
end


function ui_component(app::App, name::Symbol, fallback, argument)
    return with_component(app.session.kernel, name; fallback) do callable
        Base.invokelatest(callable, app, argument)
    end
end

update!(app::App, event::Union{KeyEvent,MouseEvent}) = ui_component(app, :input, default_input!, event)
function view(app::App, frame::Frame)
    app.area = frame.area
    ui_component(app, :view, default_view!, frame)
end

"""Complete the current slash command through the shared prompt editor."""
complete_input!(app::App) = complete_command!(app, matching_commands(app))
