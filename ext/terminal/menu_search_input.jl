# Native single-line search input. Behavior is independently tested against
# earendil-works/pi (MIT), commit 2c8d1feb147f6b3d97e855da803bfe7b19f3c403.

public MenuSearchInput, menu_search_text, menu_search_set!, menu_search_clear!, menu_search_input!, menu_search_click!
public menu_search_render!, menu_search_spans, menu_search_draw!, menu_search_width

Base.@kwdef mutable struct MenuSearchInput
    value::String = ""
    cursor::Int = 0
    prompt::String = "> "
    rendered_start_column::Int = 0
    pasting::Bool = false
    paste_buffer::String = ""
end

Base.@kwdef struct MenuSearchRun
    text::String = ""
    inverse::Bool = false
end

"""Read search text without exposing the storage or cursor representation."""
menu_search_text(input::MenuSearchInput) = input.value
menu_search_graphemes(value::AbstractString) = String.(collect(Base.Unicode.graphemes(value)))
menu_search_prefix(input::MenuSearchInput) = join(menu_search_graphemes(input.value)[1:input.cursor])

"""Set search text while preserving its clamped grapheme cursor by default."""
function menu_search_set!(input::MenuSearchInput, value::AbstractString; at_end::Bool=false)
    input.value = String(value)
    count = length(menu_search_graphemes(input.value))
    input.cursor = at_end ? count : min(input.cursor, count)
    nothing
end

"""Clear query, cursor and incomplete bracketed-paste state together."""
function menu_search_clear!(input::MenuSearchInput)
    input.value = ""
    input.cursor = 0
    input.rendered_start_column = 0
    input.pasting = false
    input.paste_buffer = ""
    nothing
end

"""Identify combining marks that occupy their own terminal cell."""
function menu_search_spacing_mark(character::Char)
    code = Int(character)
    (occursin(r"^\p{Mc}$", string(character)) && !(code in (0x1734, 0x302e, 0x302f))) ||
        code in (0x065f, 0x0f7f, 0x102b, 0x102c, 0x1031, 0x1033, 0x1034, 0x1035, 0x1038, 0x103a, 0x103b, 0x103c, 0x103d, 0x103e)
end

# Unicode 17.0 emoji variation bases, generated from the original oracle engine property.
const MENU_SEARCH_EMOJI_VARIATION_BASES = Set(Int[
    0xa9, 0xae, 0x203c, 0x2049, 0x2122, 0x2139, 0x2194, 0x2195, 0x2196, 0x2197, 0x2198, 0x2199,
    0x21a9, 0x21aa, 0x2328, 0x23cf, 0x23ed, 0x23ee, 0x23ef, 0x23f1, 0x23f2, 0x23f8, 0x23f9, 0x23fa,
    0x24c2, 0x25aa, 0x25ab, 0x25b6, 0x25c0, 0x25fb, 0x25fc, 0x2600, 0x2601, 0x2602, 0x2603, 0x2604,
    0x260e, 0x2611, 0x2618, 0x261d, 0x2620, 0x2622, 0x2623, 0x2626, 0x262a, 0x262e, 0x262f, 0x2638,
    0x2639, 0x263a, 0x2640, 0x2642, 0x265f, 0x2660, 0x2663, 0x2665, 0x2666, 0x2668, 0x267b, 0x267e,
    0x2692, 0x2694, 0x2695, 0x2696, 0x2697, 0x2699, 0x269b, 0x269c, 0x26a0, 0x26a7, 0x26b0, 0x26b1,
    0x26c8, 0x26cf, 0x26d1, 0x26d3, 0x26e9, 0x26f0, 0x26f1, 0x26f4, 0x26f7, 0x26f8, 0x26f9, 0x2702,
    0x2708, 0x2709, 0x270c, 0x270d, 0x270f, 0x2712, 0x2714, 0x2716, 0x271d, 0x2721, 0x2733, 0x2734,
    0x2744, 0x2747, 0x2763, 0x2764, 0x27a1, 0x2934, 0x2935, 0x2b05, 0x2b06, 0x2b07, 0x3030, 0x303d,
    0x3297, 0x3299, 0x1f170, 0x1f171, 0x1f17e, 0x1f17f, 0x1f202, 0x1f237, 0x1f321, 0x1f324, 0x1f325, 0x1f326,
    0x1f327, 0x1f328, 0x1f329, 0x1f32a, 0x1f32b, 0x1f32c, 0x1f336, 0x1f37d, 0x1f396, 0x1f397, 0x1f399, 0x1f39a,
    0x1f39b, 0x1f39e, 0x1f39f, 0x1f3cb, 0x1f3cc, 0x1f3cd, 0x1f3ce, 0x1f3d4, 0x1f3d5, 0x1f3d6, 0x1f3d7, 0x1f3d8,
    0x1f3d9, 0x1f3da, 0x1f3db, 0x1f3dc, 0x1f3dd, 0x1f3de, 0x1f3df, 0x1f3f3, 0x1f3f5, 0x1f3f7, 0x1f43f, 0x1f441,
    0x1f4fd, 0x1f549, 0x1f54a, 0x1f56f, 0x1f570, 0x1f573, 0x1f574, 0x1f575, 0x1f576, 0x1f577, 0x1f578, 0x1f579,
    0x1f587, 0x1f58a, 0x1f58b, 0x1f58c, 0x1f58d, 0x1f590, 0x1f5a5, 0x1f5a8, 0x1f5b1, 0x1f5b2, 0x1f5bc, 0x1f5c2,
    0x1f5c3, 0x1f5c4, 0x1f5d1, 0x1f5d2, 0x1f5d3, 0x1f5dc, 0x1f5dd, 0x1f5de, 0x1f5e1, 0x1f5e3, 0x1f5e8, 0x1f5ef,
    0x1f5f3, 0x1f5fa, 0x1f6cb, 0x1f6cd, 0x1f6ce, 0x1f6cf, 0x1f6e0, 0x1f6e1, 0x1f6e2, 0x1f6e3, 0x1f6e4, 0x1f6e5,
    0x1f6e9, 0x1f6f0, 0x1f6f3,
])

"""Measure a complete grapheme rather than summing the members of joined emoji."""
function menu_search_grapheme_width(grapheme::AbstractString)
    characters = collect(grapheme)
    spacing = all(menu_search_spacing_mark, characters)
    emoji_join = '\u200d' in characters && count(character -> 0x1f000 <= Int(character) <= 0x1fbff, characters) > 1
    emoji_variant = (length(characters) == 2 && last(characters) == '\ufe0f' && Int(first(characters)) in MENU_SEARCH_EMOJI_VARIATION_BASES) ||
        (length(characters) == 3 && characters[2:3] == ['\ufe0f', '\u20e3'] && first(characters) in "#*0123456789")
    regional = !isempty(characters) && 0x1f1e6 <= Int(first(characters)) <= 0x1f1ff
    if grapheme == "\t"
        3
    elseif spacing
        length(characters)
    elseif all(character -> iscntrl(character) || occursin(r"^[\p{M}\p{Cf}]$", string(character)), characters)
        0
    elseif emoji_join || emoji_variant || regional
        2
    else
        width = 0
        found = false
        follows_mark = false
        for character in characters
            mark = occursin(r"^\p{M}$", string(character))
            visible = !iscntrl(character) && !occursin(r"^[\p{M}\p{Cf}]$", string(character)) && textwidth(character) > 0
            if !found && visible
                width = textwidth(character)
                found = true
            elseif found && menu_search_spacing_mark(character)
                width += 1
                follows_mark = false
            elseif found && mark
                follows_mark = true
            elseif found && visible
                code = Int(character)
                if follows_mark || 0xff00 <= code <= 0xffef
                    width += textwidth(character)
                elseif code in (0x0e33, 0x0eb3)
                    width += 1
                end
                follows_mark = false
            end
        end
        width
    end
end

const MENU_SEARCH_ANSI = r"\e(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\e]*(?:\x07|\e\\)|_[^\x07\e]*(?:\x07|\e\\))"

"""Measure terminal columns while treating supported ANSI sequences as zero width."""
menu_search_width(value::AbstractString) = sum(menu_search_grapheme_width, Base.Unicode.graphemes(replace(value, MENU_SEARCH_ANSI => "")); init=0)

"""Extract whole graphemes fully contained in a display-column interval."""
function menu_search_slice(value::AbstractString, start::Int, columns::Int)
    result = IOBuffer()
    column = 0
    stop = start + max(0, columns)
    pending = ""
    position = firstindex(value)
    while position <= lastindex(value) && column < stop
        tail = SubString(value, position)
        ansi = match(MENU_SEARCH_ANSI, tail)
        if !isnothing(ansi) && ansi.offset == 1
            if column >= start
                print(result, pending, ansi.match)
                pending = ""
            else
                pending *= ansi.match
            end
            position += ncodeunits(ansi.match)
        else
            grapheme = first(Base.Unicode.graphemes(tail))
            width = menu_search_grapheme_width(grapheme)
            if column >= start && column + width <= stop
                print(result, pending, grapheme)
                pending = ""
            end
            column += width
            position += ncodeunits(grapheme)
        end
    end
    String(take!(result))
end

"""Render a centered horizontal viewport and retain its origin for mouse input."""
function menu_search_render!(input::MenuSearchInput, width::Integer)
    available = width - menu_search_width(input.prompt)
    runs = MenuSearchRun[]
    if available <= 0
        push!(runs, MenuSearchRun(; text=menu_search_slice(input.prompt, 0, max(0, width))))
    else
        input.rendered_start_column = 0
        total = menu_search_width(input.value)
        visible = input.value
        cursor = input.cursor
        if total >= available
            count = length(menu_search_graphemes(input.value))
            room = input.cursor == count ? available - 1 : available
            position = menu_search_width(menu_search_prefix(input))
            if room > 0
                half = fld(room, 2)
                start = position < half ? 0 : position > total - half ? max(0, total - room) : max(0, position - half)
                input.rendered_start_column = start
                visible = menu_search_slice(input.value, start, room)
                cursor = length(menu_search_graphemes(menu_search_slice(input.value, start, max(0, position - start))))
            else
                visible = ""
                cursor = 0
            end
        end
        graphemes = menu_search_graphemes(visible)
        before = join(graphemes[1:min(cursor, length(graphemes))])
        at_cursor = cursor < length(graphemes) ? graphemes[cursor + 1] : " "
        after = cursor + 1 < length(graphemes) ? join(graphemes[cursor + 2:end]) : ""
        padding = repeat(" ", max(0, available - menu_search_width(before * at_cursor * after)))
        append!(runs, (MenuSearchRun(; text=input.prompt * before), MenuSearchRun(; text=at_cursor, inverse=true), MenuSearchRun(; text=after * padding)))
    end
    runs
end

"""Emit the native search runs as terminal ANSI, without assuming a color palette."""
menu_search_ansi(runs::Vector{MenuSearchRun}) = join(run.inverse ? "\e[7m" * run.text * "\e[27m" : run.text for run in runs)

"""Insert one packet, merging combining characters into their neighboring graphemes."""
function menu_search_insert!(input::MenuSearchInput, text::AbstractString)
    graphemes = menu_search_graphemes(input.value)
    before = join(graphemes[1:input.cursor]) * text
    input.value = before * join(graphemes[input.cursor + 1:end])
    input.cursor = length(menu_search_graphemes(before))
    nothing
end

"""Remove a half-open range of graphemes and leave the cursor at its beginning."""
function menu_search_delete!(input::MenuSearchInput, start::Int, stop::Int)
    graphemes = menu_search_graphemes(input.value)
    input.value = join(graphemes[1:start]) * join(graphemes[stop + 1:end])
    input.cursor = start
    nothing
end

const MENU_SEARCH_KEYS = Dict(
    "\x1b" => :cancel, "\x03" => :cancel, "\r" => :submit, "\n" => :submit,
    "\x7f" => :backspace, "\x08" => :backspace, "\e[3~" => :delete, "\x04" => :delete,
    "\e[D" => :left, "\x02" => :left, "\e[C" => :right, "\x06" => :right,
    "\e[H" => :home, "\eOH" => :home, "\e[1~" => :home, "\x01" => :home,
    "\e[F" => :end, "\eOF" => :end, "\e[4~" => :end, "\x05" => :end,
    "\x15" => :delete_start, "\x0b" => :delete_end,
)

"""Apply one normalized search editing command without leaking terminal key types."""
function menu_search_edit!(input::MenuSearchInput, operation::Symbol)
    count = length(menu_search_graphemes(input.value))
    if operation == :left
        input.cursor = max(0, input.cursor - 1)
    elseif operation == :right
        input.cursor = min(count, input.cursor + 1)
    elseif operation == :home
        input.cursor = 0
    elseif operation == :end
        input.cursor = count
    elseif operation == :backspace && input.cursor > 0
        menu_search_delete!(input, input.cursor - 1, input.cursor)
    elseif operation == :delete && input.cursor < count
        menu_search_delete!(input, input.cursor, input.cursor + 1)
    elseif operation == :delete_start
        menu_search_delete!(input, 0, input.cursor)
    elseif operation == :delete_end
        menu_search_delete!(input, input.cursor, count)
    end
    operation in (:cancel, :submit) ? operation : :handled
end

"""Decode printable Kitty key packets while leaving modified controls to the caller."""
function menu_search_printable(data::AbstractString)
    matched = match(r"^\e\[([0-9]+)(?:;([0-9]+))?u$", data)
    result = nothing
    if !isnothing(matched)
        code = tryparse(Int, something(matched.captures[1], ""))
        modifier = tryparse(Int, something(matched.captures[2], "1"))
        if !isnothing(code) && modifier in (1, 2) && 32 <= code <= 0x10ffff && !(0x7f <= code <= 0x9f) && !(0xd800 <= code <= 0xdfff)
            result = string(Char(code))
        end
    end
    result
end

"""Consume raw input including split paste endings; report submit/cancel to the owner."""
function menu_search_input!(input::MenuSearchInput, packet::AbstractString)
    data = String(packet)
    if occursin("\e[200~", data)
        input.pasting = true
        input.paste_buffer = ""
        data = replace(data, "\e[200~" => ""; count=1)
    end
    action = :handled
    if input.pasting
        input.paste_buffer *= data
        ending = findfirst("\e[201~", input.paste_buffer)
        if !isnothing(ending)
            content = input.paste_buffer[1:prevind(input.paste_buffer, first(ending))]
            remaining = input.paste_buffer[nextind(input.paste_buffer, last(ending)):end]
            clean = replace(content, "\r\n" => "", "\r" => "", "\n" => "", "\t" => "    ")
            menu_search_insert!(input, clean)
            input.pasting = false
            input.paste_buffer = ""
            if !isempty(remaining)
                action = menu_search_input!(input, remaining)
            end
        end
    elseif haskey(MENU_SEARCH_KEYS, data)
        action = menu_search_edit!(input, MENU_SEARCH_KEYS[data])
    else
        printable = menu_search_printable(data)
        if !isnothing(printable)
            menu_search_insert!(input, printable)
        elseif all(character -> !(Int(character) < 32 || 0x7f <= Int(character) <= 0x9f), data)
            menu_search_insert!(input, data)
        else
            action = :ignored
        end
    end
    action
end

"""Map a zero-based local press column through the most recently rendered viewport."""
function menu_search_click!(input::MenuSearchInput, x::Integer, y::Integer=0; button::Symbol=:left, action::Symbol=:press)
    handled = button == :left && action == :press && y == 0
    if handled
        target = input.rendered_start_column + max(0, x - 2)
        column = 0
        graphemes = menu_search_graphemes(input.value)
        cursor = length(graphemes)
        found = false
        for (index, grapheme) in enumerate(graphemes)
            next_column = column + menu_search_width(grapheme)
            if !found && target < next_column
                cursor = index - 1
                found = true
            end
            column = next_column
        end
        input.cursor = cursor
    end
    handled
end

Tachikoma.text(input::MenuSearchInput) = menu_search_text(input)
Tachikoma.set_text!(input::MenuSearchInput, value::AbstractString) = menu_search_set!(input, value; at_end=true)
Tachikoma.clear!(input::MenuSearchInput) = menu_search_clear!(input)

"""Use terminal inverse video without guessing the foreground or background palette."""
struct MenuSearchInverseColor <: Tachikoma.AbstractColor end
Tachikoma.write_fg(io::IO, ::MenuSearchInverseColor) = write(io, "\e[7m")

"""Adapt reusable search runs to the terminal's existing styled-line interface."""
function menu_search_spans(input::MenuSearchInput, width::Integer)
    [Tachikoma.Span(run.text, run.inverse ? Tachikoma.Style(; fg=MenuSearchInverseColor()) : Tachikoma.RESET)
        for run in menu_search_render!(input, width)]
end

"""Write grapheme cells with native display widths instead of summing ZWJ members."""
function menu_search_draw!(buffer::Tachikoma.Buffer, x::Int, y::Int, width::Int, input::MenuSearchInput)
    column = x
    previous = x - 1
    limit = x + max(0, width) - 1
    for run in menu_search_render!(input, width)
        style = run.inverse ? Tachikoma.Style(; fg=MenuSearchInverseColor()) : Tachikoma.RESET
        clean = replace(run.text, MENU_SEARCH_ANSI => "")
        clean = join(iscntrl(character) ? ' ' : character for character in clean)
        for grapheme in Base.Unicode.graphemes(clean)
            glyph = String(grapheme)
            columns = menu_search_grapheme_width(glyph)
            if columns == 0 && previous >= x && Tachikoma.in_bounds(buffer, previous, y)
                offset = Tachikoma.buf_index(buffer, previous, y)
                cell = buffer.content[offset]
                Tachikoma.set!(buffer, previous, y, Tachikoma.Cell(cell.char, cell.style, cell.suffix * glyph))
            elseif columns > 0 && column + columns - 1 <= limit
                characters = collect(glyph)
                Tachikoma.set!(buffer, column, y, Tachikoma.Cell(first(characters), style, join(characters[2:end])))
                for offset in 1:columns - 1
                    Tachikoma.set!(buffer, column + offset, y, Tachikoma.Cell('\0', style))
                end
                previous = column
                column += columns
            end
        end
    end
    column
end

"""Translate decoded key events only when their original terminal packet is unavailable."""
function menu_search_input!(input::MenuSearchInput, event::Tachikoma.KeyEvent, raw::AbstractVector{UInt8}=UInt8[])
    if event.action == Tachikoma.key_release
        :ignored
    elseif !isempty(raw)
        menu_search_input!(input, String(copy(raw)))
    elseif event.key == :char
        menu_search_input!(input, string(event.char))
    elseif event.key == :ctrl && 'a' <= event.char <= 'z'
        menu_search_input!(input, string(Char(Int(event.char) - Int('a') + 1)))
    elseif event.key in (:ctrl_c, :escape)
        menu_search_input!(input, "\e")
    elseif event.key == :enter
        menu_search_input!(input, "\r")
    elseif event.key in (:left, :right, :home, :backspace, :delete)
        menu_search_edit!(input, event.key)
    elseif event.key == :end_key
        menu_search_edit!(input, :end)
    else
        :ignored
    end
end
