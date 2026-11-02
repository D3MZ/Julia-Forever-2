# UI labels and interaction contract are interoperable with earendil-works/pi 1.4.0 (MIT).
# Rendering and state ownership below are Julia-native; Pi is a test-only oracle.
struct SettingSpec
    id::String
    label::String
    description::String
    default::String
    values::Vector{String}
end

const TERMINAL_SETTINGS = SettingSpec[
    SettingSpec("autocompact", "Auto-compact", "Automatically compact context when it gets too large", "true", String["true", "false"]),
    SettingSpec("show-images", "Show images", "Render images inline in terminal", "true", String["true", "false"]),
    SettingSpec("image-width-cells", "Image width", "Preferred inline image width in terminal cells", "60", String["60", "80", "120"]),
    SettingSpec("auto-resize-images", "Auto-resize images", "Resize large images to 2000x2000 max for better model compatibility", "true", String["true", "false"]),
    SettingSpec("block-images", "Block images", "Prevent images from being sent to LLM providers", "false", String["true", "false"]),
    SettingSpec("skill-commands", "Skill commands", "Register skills as /skill:name commands", "true", String["true", "false"]),
    SettingSpec("show-hardware-cursor", "Show hardware cursor", "Use the terminal cursor instead of Pi's drawn cursor", "false", String["true", "false"]),
    SettingSpec("editor-padding", "Editor padding", "Horizontal padding for input editor (0-3)", "0", String["0", "1", "2", "3"]),
    SettingSpec("output-padding", "Output padding", "Horizontal padding for messages, tool output, and command output", "1", String["0", "1"]),
    SettingSpec("autocomplete-max-visible", "Autocomplete max items", "Max visible items in autocomplete dropdown (3-20)", "5", String["3", "5", "7", "10", "15", "20"]),
    SettingSpec("clear-on-shrink", "Clear on shrink", "Clear empty rows when content shrinks (may cause flicker)", "false", String["true", "false"]),
    SettingSpec("terminal-progress", "Terminal progress", "Show OSC 9;4 progress indicators in the terminal tab bar", "false", String["true", "false"]),
    SettingSpec("steering-mode", "Steering mode", "Enter while streaming queues steering messages. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.", "one-at-a-time", String["one-at-a-time", "all"]),
    SettingSpec("follow-up-mode", "Follow-up mode", "Alt+Enter queues follow-up messages until agent stops. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.", "one-at-a-time", String["one-at-a-time", "all"]),
    SettingSpec("transport", "Transport", "Preferred transport for providers that support multiple transports", "auto", String["sse", "websocket", "websocket-cached", "auto"]),
    SettingSpec("share-destination", "Session share destination", "Where to upload sessions with /share (auto prefers Radius when authenticated, otherwise GitHub Gist)", "auto", String["auto", "gist", "radius"]),
    SettingSpec("http-idle-timeout", "HTTP idle timeout", "Maximum idle gap while waiting for HTTP headers or body chunks. Disable for local models that pause longer than five minutes.", "5 min", String["30 sec", "1 min", "2 min", "5 min", "disabled"]),
    SettingSpec("cache-warming-mode", "Cache warming", "off; streaming while the agent runs; idle also between runs while continuation stays profitable", "streaming", String["off", "streaming", "idle"]),
    SettingSpec("hide-thinking", "Hide thinking", "Hide thinking blocks in assistant responses", "false", String["true", "false"]),
    SettingSpec("mermaid-rendering", "Mermaid diagrams", "Render Mermaid code blocks as Unicode diagrams", "streaming", String["off", "final", "streaming"]),
    SettingSpec("cache-miss-notices", "Cache miss notices", "Show transcript notices for cache costs and provider recovery diagnostics", "false", String["true", "false"]),
    SettingSpec("collapse-changelog", "Collapse changelog", "Show condensed changelog after updates", "false", String["true", "false"]),
    SettingSpec("quiet-startup", "Quiet startup", "Disable verbose printing at startup (header: keep only the startup header)", "false", String["true", "header", "false"]),
    SettingSpec("install-telemetry", "Install telemetry", "Unavailable: Julia Forever 2 has no approved telemetry destination or privacy contract. No installation or update ping is sent.", "false", String["true", "false"]),
    SettingSpec("default-project-trust", "Default project trust", "Fallback behavior when no extension or saved trust decision decides project trust", "Ask", String["Ask", "Always trust", "Never trust"]),
    SettingSpec("double-escape-action", "Double-escape action", "Action when pressing Escape twice with empty editor", "tree", String["tree", "fork", "none"]),
    SettingSpec("tree-filter-mode", "Tree filter mode", "Default filter when opening /tree", "default", String["default", "no-tools", "user-only", "labeled-only", "all"]),
    SettingSpec("warnings", "Warnings", "Enable or disable individual warnings", "configure", String[]),
    SettingSpec("model-thinking", "Default thinking level per model", "Override the default thinking level for specific models. Shift+Tab cycles in-session.", "none", String[]),
    SettingSpec("tui-mode", "TUI mode", "Interface layout; regular mode uses the terminal's normal scrollback", "fullscreen", String["regular", "fullscreen"]),
    SettingSpec("fullscreen-exit-output", "Fullscreen exit output", "Print the transcript or only a session resume hint when exiting fullscreen mode", "transcript", String["transcript", "resume-hint"]),
    SettingSpec("fullscreen-scrollbar", "Fullscreen scrollbar", "Scrollbar behavior in fullscreen mode; has no effect in regular mode", "auto", String["auto", "always", "hidden"]),
    SettingSpec("fullscreen-copy-on-select", "Fullscreen copy on select", "Automatically copy selected text in fullscreen mode; disable to copy selections with Ctrl+X", "true", String["true", "false"]),
    SettingSpec("fullscreen-wheel-scroll-lines", "Fullscreen wheel scrolling", "Lines per mouse-wheel event in fullscreen mode; 'auto' speeds up fast wheel spins where the terminal does not", "auto", String["auto", "1", "2", "3", "5", "10"]),
    SettingSpec("theme", "Theme", "Color theme for the interface", "dark", String[]),
 ]

"""Read only settings supported by the terminal's actual image capability."""
settings_definitions(images::Bool) = filter(item -> images || !(item.id in ("show-images", "image-width-cells")), TERMINAL_SETTINGS)

"""Describe unavailable native consumers without hiding the original menu entries."""
setting_unavailable_reason(::Val) = ""
setting_unavailable_reason(::Val{Symbol("install-telemetry")}) = "Install telemetry is unavailable: no approved Julia Forever 2 destination or privacy contract. No ping is sent."
"""Show availability first; supported settings retain their persisted or declared value."""
function setting_value(app::App, item::SettingSpec)
    if !isempty(setting_unavailable_reason(Val(Symbol(item.id))))
        "unavailable"
    elseif item.id == "model-thinking"
        thinking_defaults_summary(get(app.menus.model_preferences, "thinkingDefaults", Dict{String,Any}()))
    else
        menu_preference(app, item.id, item.default)
    end
end

"""Score ordered characters using proximity and word boundaries, with exact matches first."""
function menu_alignment_score(text::Vector{Char}, positions::Vector{Int})
    score = 0.0
    prior = 0
    run = 0
    for index in positions
        if index == prior + 1
            run += 1
            score -= run * 5
        else
            run = 0
            prior == 0 || (score += (index - prior - 1) * 2)
        end
        if index == 1 || isspace(text[index - 1]) || text[index - 1] in ('-', '_', '.', '/', ':')
            score -= 10
        end
        score += (index - 1) / 10
        prior = index
    end
    score
end

"""Find the best greedy or contiguous alignment for one search token."""
function menu_token_score(label::AbstractString, query::AbstractString)
    text, token = collect(lowercase(String(label)::String)), collect(lowercase(String(query)::String))
    positions = Int[]
    cursor = 1
    for (index, character) in enumerate(text)
        if cursor <= length(token) && character == token[cursor]
            push!(positions, index)
            cursor += 1
        end
    end
    score = Inf
    if length(positions) == length(token)
        score = menu_alignment_score(text, positions)
        for start in 1:(length(text) - length(token) + 1)
            indexes = collect(start:(start + length(token) - 1))
            if text[indexes] == token
                score = min(score, menu_alignment_score(text, indexes))
            end
        end
        text == token && (score -= 100)
    end
    score
end

"""Search all whitespace-separated tokens and retain stable ordering for equal scores."""
function search_settings(items::Vector{SettingSpec}, query::AbstractString)
    tokens = split(strip(query), r"[\s/]+"; keepempty=false)
    scored = [(item, sum(token -> menu_token_score(item.label, token), tokens; init=0.0)) for item in items]
    sort!(filter!(pair -> isfinite(last(pair)), scored); by=last, alg=Base.Sort.MergeSort)
    [first(pair) for pair in scored]
end

const WARNING_SETTINGS = [SettingSpec("anthropic-extra-usage", "Anthropic extra usage",
    "Warn when Anthropic subscription auth may use paid extra usage", "true", ["true", "false"])]

"""Select the active settings family without duplicating keyboard or rendering logic."""
active_settings(app::App) = app.menus.path == ["settings", "warnings"] ? WARNING_SETTINGS : settings_definitions(app.menus.images)
settings_searchable(app::App) = app.menus.path != ["settings", "warnings"]
visible_settings(app::App) = search_settings(active_settings(app), settings_searchable(app) ? Tachikoma.text(app.menus.search) : "")

"""Bound a string by terminal graphemes, never splitting combining or joined glyphs."""
function menu_clip(text::AbstractString, width::Integer; ellipsis::Bool=false)
    value = String(text)
    room = max(0, width)
    if textwidth(value) > room
        suffix = ellipsis && room > 0 ? first("...", min(room, 3)) : ""
        value = ""
        for grapheme in Base.Unicode.graphemes(text)
            if textwidth(value) + textwidth(grapheme) <= room - textwidth(suffix)
                value *= grapheme
            else
                break
            end
        end
        value *= suffix
    end
    value
end

"""Wrap descriptive text on spaces while preserving narrow-terminal readability."""
function menu_wrap(text::AbstractString, width::Integer)
    lines = String[]
    current = ""
    for word in split(text, ' '; keepempty=true)
        candidate = isempty(current) ? String(word) : current * " " * word
        if textwidth(candidate) <= max(1, width)
            current = candidate
        else
            isempty(current) || push!(lines, current)
            current = String(word)
            while textwidth(current) > max(1, width)
                prefix = menu_clip(current, max(1, width))
                if isempty(prefix)
                    prefix = String(first(Base.Unicode.graphemes(current)))
                end
                push!(lines, prefix)
                current = chop(current; head=length(prefix), tail=0)
            end
        end
    end
    isempty(current) || push!(lines, current)
    lines
end

"""Render the native grapheme-aware input using the terminal's default palette."""
menu_search_line(input::MenuSearchInput, width::Integer) = menu_search_spans(input, width)

menu_span(text::AbstractString, style::Symbol=:terminal_default) = Tachikoma.Span(String(text), pi_style(style))
menu_line(text::AbstractString="", style::Symbol=:terminal_default) = Tachikoma.Span[menu_span(text, style)]

"""Keep truncation markers unstyled, matching terminal-default ellipsis semantics."""
function menu_clipped_line(text::AbstractString, width::Integer, style::Symbol)
    if textwidth(text) > max(0, width)
        suffix = first("...", clamp(width, 0, 3))
        [menu_span(menu_clip(text, width - textwidth(suffix)), style), menu_span(suffix)]
    else
        menu_line(text, style)
    end
end

"""Render a searchable native settings list with centered scrolling and inline values."""
function settings_lines(app::App, width::Integer)
    items = visible_settings(app)
    lines = Vector{Tachikoma.Span}[]
    push!(lines, menu_line(repeat("─", max(0, width)), :menu_border))
    if settings_searchable(app)
        push!(lines, menu_search_line(app.menus.search, width))
        push!(lines, menu_line())
    end
    if isempty(items)
        push!(lines, menu_clipped_line("  No matching settings", width, :text_dim))
    else
        selected = clamp(app.menus.cursor, 1, length(items))
        first_item = max(1, min(selected - 5, length(items) - 9))
        last_item = min(first_item + 9, length(items))
        label_width = min(36, maximum(textwidth(item.label) for item in active_settings(app)))
        for index in first_item:last_item
            item = items[index]
            active = index == selected
            label = (active ? "→ " : "  ") * rpad(item.label, label_width)
            value = menu_clip(setting_value(app, item), width - label_width - 6)
            cursor_style = something(app.menus.settings_cursor_style, pi_style(:accent))
            row = menu_clipped_line(label, width, active ? :accent : :terminal_default)
            if active && !isempty(row)
                visible = row[1].content
                prefix = first(visible, min(2, length(visible)))
                remainder = chop(visible; head=length(prefix), tail=0)
                row = [Tachikoma.Span(prefix, cursor_style), menu_span(remainder, :accent), row[2:end]...]
            end
            used = textwidth(label)
            if used < width
                push!(row, menu_span(menu_clip("  ", width - used)))
                push!(row, menu_span(value, active ? :accent : :muted))
            end
            push!(lines, row)
        end
        if first_item > 1 || last_item < length(items)
            push!(lines, menu_line(menu_clip("  ($selected/$(length(items)))", width - 2), :text_dim))
        end
        description = items[selected].description
        if !isempty(description)
            push!(lines, menu_line())
            append!(lines, [menu_line("  " * line, :text_dim) for line in menu_wrap(description, width - 4)])
        end
    end
    push!(lines, menu_line())
    unavailable=!isempty(items) && !isempty(setting_unavailable_reason(Val(Symbol(items[clamp(app.menus.cursor,1,length(items))].id))))
    hint = unavailable ? "  Unavailable in this build · Esc to cancel" : settings_searchable(app) ? "  Type to search · Enter/Space to change · Esc to cancel" : "  Enter/Space to change · Esc to cancel"
    push!(lines, menu_clipped_line(hint, width, :text_dim))
    push!(lines, menu_line(repeat("─", max(0, width)), :menu_border))
    lines
end

"""Cycle a setting in place; submenu actions retain their parent selection."""
function activate_setting!(app::App)
    items = visible_settings(app)
    if !isempty(items)
        selected = items[clamp(app.menus.cursor, 1, length(items))]
        if isempty(selected.values)
            push!(app.menus.parents, (copy(app.menus.path), app.menus.cursor, Tachikoma.text(app.menus.search)))
            push!(app.menus.path, selected.id)
            app.menus.cursor = 1
            Tachikoma.clear!(app.menus.search)
            selected.id == "theme" && open_theme_control!(app)
            selected.id == "model-thinking" && open_thinking_defaults_control!(app)
        else
            index = findfirst(==(setting_value(app, selected)), selected.values)
            value = selected.values[isnothing(index) ? 1 : mod1(index + 1, length(selected.values))]
            set_setting_value!(app, selected.id, value)
        end
    end
    nothing
end

"""Handle search, selection, paging and cycling without leaving the settings list."""
function settings_input!(app::App, event::KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    items = visible_settings(app)
    count = length(items)
    if menu_search_pasting(app.menus.search, raw)
        menu_search_input!(app.menus.search, event, raw)
        app.menus.cursor = 1
    elseif event.key == :escape
        if isempty(app.menus.parents)
            app.page = :chat
        else
            path, cursor, query = pop!(app.menus.parents)
            app.menus.path = path
            app.menus.cursor = cursor
            Tachikoma.set_text!(app.menus.search, query)
        end
    elseif event.key in (:up, :down) && count > 0
        app.menus.cursor = mod1(app.menus.cursor + (event.key == :up ? -1 : 1), count)
    elseif event.key in (:pageup, :pagedown) && count > 0
        app.menus.cursor = clamp(app.menus.cursor + (event.key == :pageup ? -10 : 10), 1, count)
    elseif event.key == :enter || (event.key == :char && event.char == ' ' && isempty(Tachikoma.text(app.menus.search)))
        activate_setting!(app)
    elseif settings_searchable(app)
        edit_menu_search!(app.menus.search, event, raw)
        app.menus.cursor = 1
    end
    nothing
end

"""Draw exact menu spans into the active frame, leaving the existing transcript above."""
function draw_menu_lines!(buffer, x, y, width, lines)
    for (row, spans) in enumerate(lines)
        column = x
        for span in spans
            column = Tachikoma.set_string!(buffer, column, y + row - 1, span.content, span.style; max_x=x + width - 1)
        end
    end
    nothing
end

"""Keep silent successful settings silent, clearing only a still-owned failure for the same setting."""
function setting_status_outcome!(app::App,name::AbstractString,ok::Bool,reason::AbstractString="")
    previous=app.menus.preference_error
    if ok
        if !isnothing(previous) && first(previous)==name
            app.status==last(previous) && (app.status="Ready")
            app.menus.preference_error=nothing
        end
    else
        app.status=String(reason)
        app.menus.preference_error=(String(name),String(reason))
    end
    nothing
end

"""Commit private persistence and runtime effects together; publish only verified outcomes."""
function set_setting_value!(app::App, name::AbstractString, value::AbstractString)
    reason=setting_unavailable_reason(Val(Symbol(name)))
    if isempty(reason)
        commit_supported_setting_value!(app,name,value)
    else
        setting_status_outcome!(app,name,false,reason)
        frontend_notice!(app,reason;kind=:warning)
    end
    nothing
end

"""Only supported consumers may persist a preference or invoke runtime callbacks."""
function commit_supported_setting_value!(app::App, name::AbstractString, value::AbstractString)
    path = joinpath(app.settings.directory, "terminal-settings.json")
    previous = copy(app.menus.preferences)
    definitions = [TERMINAL_SETTINGS; WARNING_SETTINGS]
    spec = findfirst(item -> item.id == name, definitions)
    fallback = isnothing(spec) ? "" : definitions[spec].default
    old_value = get(previous, String(name), fallback)
    validate = (key, candidate) -> !isnothing(spec) && (isempty(definitions[spec].values) || candidate in definitions[spec].values)
    prepared = prepare_terminal_preference(path, name, value; validate)
    if prepared.ok
        apply = () -> begin
            app.menus.preferences[String(name)] = String(value)
            effect = apply_setting_effect!(app, Val(Symbol(name)), value)
            if preference_effect_ok(effect)
                with_component(app.session.kernel, :terminal_setting_changed; fallback=Returns(nothing)) do callback
                    Base.invokelatest(callback, String(name), String(value), app)
                end
            else
                effect
            end
        end
        restore = () -> begin
            empty!(app.menus.preferences)
            merge!(app.menus.preferences, previous)
            effect = apply_setting_effect!(app, Val(Symbol(name)), old_value)
            if preference_effect_ok(effect)
                with_component(app.session.kernel, :terminal_setting_changed; fallback=Returns(nothing)) do callback
                    Base.invokelatest(callback, String(name), old_value, app)
                end
            else
                effect
            end
        end
        result = commit_terminal_preference!(prepared.plan; apply, restore, active=() -> !app.operations.closing[])
        setting_status_outcome!(app,name,result.ok,result.reason)
        result.ok && setting_committed_notice!(app,Val(Symbol(name)),value)
    else
        setting_status_outcome!(app,name,false,prepared.reason)
    end
    nothing
end

"""Load known terminal preferences only; unrelated provider/auth state is not consulted."""
function load_menu_preferences!(app::App)
    path = joinpath(app.settings.directory, "terminal-settings.json")
    if isfile(path) && !islink(path)
        data = JuliaForever2.parse_json(read(path, String))
        if data isa AbstractDict
            for item in [TERMINAL_SETTINGS; WARNING_SETTINGS]
                value = get(data, item.id, nothing)
                if value isa String && (isempty(item.values) || value in item.values)
                    app.menus.preferences[item.id] = value
                end
            end
        end
    end
    for (name, value) in app.menus.preferences
        apply_setting_effect!(app, Val(Symbol(name)), value)
    end
    nothing
end

"""Terminal integrations can specialize setting effects independently of rendering."""
apply_setting_effect!(app::App, ::Val, value::AbstractString) = nothing
apply_setting_effect!(app::App, ::Val{Symbol("skill-commands")}, value::AbstractString) = set_skill_commands!(app, value == "true")
function apply_setting_effect!(app::App, ::Val{:autocompact}, value::AbstractString)
    policy = JuliaForever2.session_compaction_settings(app.session)
    install!(app.session.kernel, ComponentSpec(:compaction_settings,
        JuliaForever2.CompactionSettings(; enabled=value == "true", reserve_tokens=policy.reserve_tokens,
            keep_recent_tokens=policy.keep_recent_tokens, model_overrides=policy.model_overrides)))
    nothing
end

function apply_setting_effect!(app::App, ::Val{Symbol("http-idle-timeout")}, value::AbstractString)
    choices = Dict("30 sec" => 30_000, "1 min" => 60_000, "2 min" => 120_000,
        "5 min" => 300_000, "disabled" => 0)
    if haskey(choices, value)
        install!(app.session.kernel, ComponentSpec(:http_idle_timeout, choices[value]))
        nothing
    else
        (ok=false, reason="Invalid HTTP idle timeout")
    end
end

"""Read a numeric terminal preference with a validated bounded fallback."""
function terminal_integer(app::App, name::AbstractString, fallback::Int, low::Int, high::Int)
    value = tryparse(Int, menu_preference(app, name, string(fallback)))
    isnothing(value) ? fallback : clamp(value, low, high)
end

"""Use the same bottom-anchored geometry for mouse hit testing and rendering."""
settings_top(app::App) = startup_editor_geometry(app,settings_lines(app,app.area.width)).top

"""Move settings selection on press, activate on release, and clamp wheel movement."""
function settings_mouse!(app::App, event::MouseEvent)
    handled=false
    items = visible_settings(app)
    count = length(items)
    lines=settings_lines(app,app.area.width)
    geometry=startup_editor_geometry(app,lines)
    local_row=startup_editor_row(app,event,geometry)
    search=settings_searchable(app)
    row=local_row-(search ? 3 : 1)
    in_list=local_row>=0 && 0<=row<min(count,10)
    in_wheel_region=(search ? 3 : 1)<=local_row<length(lines)-1
    if in_wheel_region && count>0 && event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
        handled=true
        app.menus.cursor=clamp(app.menus.cursor+(event.button==Tachikoma.mouse_scroll_up ? -1 : 1),1,count)
    elseif event.button==Tachikoma.mouse_left
        first_item=max(1,min(app.menus.cursor-5,count-9))
        index=first_item+row
        visible_last=min(first_item+9,count)
        if search && local_row==1 && event.action==Tachikoma.mouse_press
            handled=menu_search_click!(app.menus.search,event.x-app.area.x,0)
        elseif in_list && first_item<=index<=visible_last
            if event.action==Tachikoma.mouse_press
                handled=true
                app.menus.cursor=index
                app.menus.pressed=index
            elseif event.action==Tachikoma.mouse_release && !isnothing(app.menus.pressed)
                handled=true
                app.menus.cursor=app.menus.pressed
                app.menus.pressed=nothing
                activate_setting!(app)
            end
        elseif event.action==Tachikoma.mouse_release
            app.menus.pressed=nothing
        end
    end
    handled
end
