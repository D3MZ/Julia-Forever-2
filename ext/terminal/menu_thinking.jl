# Julia-native thinking selector; differential reference: earendil-works/pi (MIT),
# pinned 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; see licenses/pi-LICENSE.
public ThinkingMenu, thinking_menu, supported_thinking_levels, thinking_lines
public thinking_input!, thinking_mouse!, thinking_selected, thinking_hardware_cursor

const THINKING_MENU_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
const THINKING_MENU_DESCRIPTIONS = Dict(
    "off" => "No reasoning", "minimal" => "Very brief reasoning (~1k tokens)",
    "low" => "Light reasoning (~2k tokens)", "medium" => "Moderate reasoning (~8k tokens)",
    "high" => "Deep reasoning (~16k tokens)", "xhigh" => "Extra-high reasoning (~32k tokens)",
    "max" => "Maximum reasoning",
)

"""Resolve model-supported levels without confusing an absent mapping with explicit null."""
function supported_thinking_levels(reasoning::Bool, level_map::AbstractDict=Dict{String,Any}())
    if reasoning
        filter(THINKING_MENU_LEVELS) do level
            mapped = haskey(level_map, level) ? level_map[level] : get(level_map, Symbol(level), missing)
            !isnothing(mapped) && (!(level in ("xhigh", "max")) || !ismissing(mapped))
        end
    else
        ["off"]
    end
end

Base.@kwdef mutable struct ThinkingMenu{S,C,D}
    current::String
    levels::Vector{String}
    on_select::S
    on_cancel::C
    on_default::D = nothing
    default_level::Union{Nothing,String} = nothing
    search::MenuSearchInput = MenuSearchInput()
    filtered::Vector{String} = String[]
    cursor::Int = 1
    pressed::Union{Nothing,Int} = nothing
    focused::Bool = false
    width::Int = 0
    height::Int = 0
    search_row::Int = 0
    list_row::Int = 0
    list_height::Int = 1
end

"""Construct a selector with real owner callbacks; no selection or persistence is simulated."""
function thinking_menu(current::AbstractString, levels::AbstractVector; on_select, on_cancel,
        on_default=nothing, default_level=nothing, focused::Bool=false)
    available = String[String(level) for level in levels]
    index = findfirst(==(current), available)
    ThinkingMenu(; current=String(current), levels=available, on_select, on_cancel, on_default,
        default_level=isnothing(default_level) ? nothing : String(default_level), focused,
        filtered=copy(available), cursor=isnothing(index) ? 1 : index)
end

"""Read the selected supported level, including the legitimate empty-list state."""
thinking_selected(menu::ThinkingMenu) = 1 <= menu.cursor <= length(menu.filtered) ? menu.filtered[menu.cursor] : nothing

"""Keep current ticks and default markers tied to owner-supplied constructor state."""
function thinking_item(menu::ThinkingMenu, level::AbstractString)
    description = get(THINKING_MENU_DESCRIPTIONS, level, "")
    (value=String(level), label=(level == menu.current ? "✓ " : "  ") * level,
        description=description * (level == menu.default_level ? " · default" : ""))
end
thinking_items(menu::ThinkingMenu) = [thinking_item(menu, level) for level in menu.filtered]

"""Reuse native token scoring and support numeric/letter reversal when the first match fails."""
function thinking_token_score(text::AbstractString, query::AbstractString)
    score = menu_token_score(text, query)
    if !isfinite(score)
        letters_first = match(r"^([a-z]+)([0-9]+)$", lowercase(query))
        digits_first = match(r"^([0-9]+)([a-z]+)$", lowercase(query))
        matched = isnothing(letters_first) ? digits_first : letters_first
        if !isnothing(matched)
            swapped = something(matched.captures[2], "") * something(matched.captures[1], "")
            score = menu_token_score(text, swapped) + 5
        end
    end
    score
end

"""Filter by level and description while preserving the selected value when it survives."""
function thinking_filter!(menu::ThinkingMenu)
    selected = thinking_selected(menu)
    tokens = split(strip(menu_search_text(menu.search)), r"[\s/]+"; keepempty=false)
    scored = [(level, sum(tokens; init=0.0) do token
        thinking_token_score(level * " " * thinking_item(menu, level).description, token)
    end) for level in menu.levels]
    sort!(filter!(pair -> isfinite(last(pair)), scored); by=last, alg=Base.Sort.MergeSort)
    menu.filtered = first.(scored)
    index = findfirst(==(selected), menu.filtered)
    menu.cursor = isnothing(index) ? 1 : index
    menu.pressed = nothing
    nothing
end

"""Describe an invocation without claiming that the owner's operation succeeded."""
thinking_result() = (invoked=false, kind=:none, level=nothing, outcome=nothing)
thinking_result(kind::Symbol, level, outcome) = (invoked=true, kind=kind, level=level, outcome=outcome)

"""Forward a selection to the owner and propagate its real result unchanged."""
function thinking_select!(menu::ThinkingMenu)
    level = thinking_selected(menu)
    isnothing(level) ? thinking_result() : thinking_result(:select, level, menu.on_select(level))
end

"""Dispatch default requests only when a real default-setting hook exists."""
thinking_default!(menu::ThinkingMenu, ::Nothing) = thinking_result()
function thinking_default!(menu::ThinkingMenu, callback)
    level = thinking_selected(menu)
    isnothing(level) ? thinking_result() : thinking_result(:default, level, callback(level))
end

"""Handle the list's keyboard contract, separate from the selector's page-key routing."""
function thinking_list_input!(menu::ThinkingMenu, data::AbstractString)
    count = length(menu.filtered)
    result = thinking_result()
    if data in ("\e[A", "\eOA")
        menu.cursor = menu.cursor == 1 ? count : menu.cursor - 1
    elseif data in ("\e[B", "\eOB")
        menu.cursor = menu.cursor == count ? 1 : menu.cursor + 1
    elseif data in ("\e[5~", "\e[6~") && count > 0
        menu.cursor = data == "\e[5~" ? 1 : count
    elseif data in ("\r", "\n")
        result = thinking_select!(menu)
    elseif data in ("\e", "\x03")
        result = thinking_result(:cancel, nothing, menu.on_cancel())
    end
    result
end

"""Route selector keys exactly; page keys edit neither selection nor the query."""
function thinking_input!(menu::ThinkingMenu, data::AbstractString)
    if data == "\x13" && !isnothing(menu.on_default)
        thinking_default!(menu, menu.on_default)
    elseif data in ("\e[A", "\eOA", "\e[B", "\eOB", "\r", "\e", "\x03")
        thinking_list_input!(menu, data)
    else
        action = menu_search_input!(menu.search, data)
        result = action == :submit ? thinking_select!(menu) : thinking_result()
        thinking_filter!(menu)
        result
    end
end

"""Wrap literal menu prose, preserving leading spaces and the original narrow-word breaks."""
function thinking_wrap(text::AbstractString, width::Int)
    room = max(1, width)
    lines = String[]
    current = ""
    used = 0
    for match in eachmatch(r" +|[^ ]+", text)
        token = String(match.match)
        columns = menu_search_width(token)
        spaces = all(==(' '), token)
        if columns > room && !spaces
            if !isempty(current)
                push!(lines, rstrip(current))
            end
            current = ""
            used = 0
            for grapheme in menu_search_graphemes(token)
                size = menu_search_width(grapheme)
                if used + size > room
                    push!(lines, rstrip(current))
                    current = ""
                    used = 0
                end
                current *= grapheme
                used += size
            end
        elseif used + columns > room && used > 0
            push!(lines, rstrip(current))
            current = spaces ? "" : token
            used = spaces ? 0 : columns
        else
            current *= token
            used += columns
        end
    end
    if !isempty(current)
        push!(lines, rstrip(current))
    end
    isempty(lines) ? [""] : lines
end

thinking_span(text::AbstractString, style::Symbol=:terminal_default) = Tachikoma.Span(String(text), pi_style(style))
thinking_line(text::AbstractString="", style::Symbol=:terminal_default) = [thinking_span(text, style)]

"""Wrap a text component with terminal-default padding except while a color continues."""
function thinking_text_lines(text::AbstractString, width::Int; style::Symbol=:terminal_default)
    wrapped = thinking_wrap(text, width)
    [[thinking_span(line, style), thinking_span(repeat(" ", max(0, width - menu_search_width(line))),
        index == length(wrapped) ? :terminal_default : style)] for (index, line) in enumerate(wrapped)]
end

"""Render a list row with the original two-column breakpoint and selected-row colors."""
function thinking_item_line(item, selected::Bool, width::Int, primary_width::Int)
    prefix = selected ? "→ " : "  "
    if !isempty(item.description) && width > 40
        primary = max(1, min(primary_width, width - 6))
        label = menu_search_slice(item.label, 0, max(1, primary - 2))
        spacing = repeat(" ", max(1, primary - menu_search_width(label)))
        remaining = width - 2 - menu_search_width(label) - length(spacing) - 2
        description = menu_search_slice(item.description, 0, max(0, remaining))
        if remaining > 10
            selected ? thinking_line(prefix * label * spacing * description, :accent) :
                [thinking_span(prefix * label), thinking_span(spacing * description, :muted)]
        else
            thinking_line(prefix * menu_search_slice(item.label, 0, max(0, width - 4)), selected ? :accent : :terminal_default)
        end
    else
        thinking_line(prefix * menu_search_slice(item.label, 0, max(0, width - 4)), selected ? :accent : :terminal_default)
    end
end

"""Render the actual selector and retain zero-based hit-test coordinates after wrapping."""
function thinking_lines(menu::ThinkingMenu, width::Integer; cycle_hint::AbstractString="Shift+Tab")
    columns = Int(width)
    lines = Vector{Tachikoma.Span}[]
    push!(lines, thinking_line(repeat("─", max(1, columns)), :menu_border))
    push!(lines, thinking_line())
    append!(lines, thinking_text_lines("Thinking Level", columns))
    push!(lines, thinking_line())
    append!(lines, thinking_text_lines(cycle_hint*" cycles thinking levels in-session", columns))
    push!(lines, thinking_line())
    menu.search_row = length(lines)
    push!(lines, menu_search_spans(menu.search, columns))
    push!(lines, thinking_line())
    menu.list_row = length(lines)
    items = thinking_items(menu)
    if isempty(items)
        push!(lines, thinking_line("  No matching commands", :muted))
    else
        primary_width = clamp(maximum(menu_search_width(item.label) + 2 for item in items), 12, 32)
        append!(lines, [thinking_item_line(item, index == menu.cursor, columns, primary_width) for (index, item) in enumerate(items)])
    end
    menu.list_height = max(1, length(items))
    push!(lines, thinking_line())
    append!(lines, thinking_text_lines("  Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel", columns; style=:text_dim))
    push!(lines, thinking_line(repeat("─", max(1, columns)), :menu_border))
    menu.width = columns
    menu.height = length(lines)
    lines
end

"""Expose cursor coordinates to the owner without deciding hardware-cursor visibility."""
function thinking_hardware_cursor(menu::ThinkingMenu)
    if menu.focused && menu.width > 2
        runs = menu_search_render!(menu.search, menu.width)
        (row=menu.search_row, col=menu_search_width(first(runs).text))
    else
        nothing
    end
end

"""Dispatch clicks using the rendered layout; wheel affects only the list region."""
function thinking_mouse!(menu::ThinkingMenu, x::Int, y::Int; action::Symbol=:press, button::Symbol=:left, wheel_delta::Int=0)
    result = nothing
    if 0 <= y < menu.height && y == menu.search_row
        if menu_search_click!(menu.search, x, 0; button, action)
            result = (handled=true, focus=true, capture=false, render=nothing, target="search", focusTarget="selector", request=thinking_result())
        end
    elseif menu.list_row <= y < menu.list_row + menu.list_height && !isempty(menu.filtered)
        if action == :wheel && wheel_delta != 0
            previous = menu.cursor
            menu.cursor = clamp(menu.cursor + (wheel_delta < 0 ? -1 : 1), 1, length(menu.filtered))
            result = (handled=true, focus=false, capture=false, render=previous != menu.cursor, target="list", focusTarget=nothing, request=thinking_result())
        elseif button == :left && action in (:press, :click)
            index = y - menu.list_row + 1
            if action == :press
                menu.pressed = index
                menu.cursor = index
                result = (handled=true, focus=true, capture=false, render=nothing, target="list", focusTarget="selector", request=thinking_result())
            else
                menu.cursor = something(menu.pressed, index)
                menu.pressed = nothing
                result = (handled=true, focus=false, capture=false, render=nothing, target="list", focusTarget=nothing, request=thinking_select!(menu))
            end
        end
    end
    result
end
