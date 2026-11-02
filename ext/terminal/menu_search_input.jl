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
    kills::Vector{String} = String[]
    undo::Vector{Tuple{String,Int}} = Tuple{String,Int}[]
    last_action::Symbol = :none
end
MenuSearchInput(value,cursor,prompt,rendered_start_column,pasting,paste_buffer) =
    MenuSearchInput(;value,cursor,prompt,rendered_start_column,pasting,paste_buffer)

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
    empty!(input.kills);empty!(input.undo);input.last_action=:none
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

"""Snapshot owned immutable text and its public grapheme cursor, not the kill ring."""
menu_search_push_undo!(input::MenuSearchInput) = push!(input.undo,(input.value,input.cursor))

"""Insert one packet with word-typing undo coalescing and native grapheme boundaries."""
function menu_search_insert!(input::MenuSearchInput, text::AbstractString;snapshot::Bool=true,typed::Bool=true)
    if snapshot && (!typed || editor_input_space(text) || input.last_action!=:type_word)
        menu_search_push_undo!(input)
    end
    graphemes = menu_search_graphemes(input.value)
    before = join(graphemes[1:input.cursor]) * text
    input.value = before * join(graphemes[input.cursor + 1:end])
    input.cursor = min(length(menu_search_graphemes(before)),length(menu_search_graphemes(input.value)))
    input.last_action=typed ? :type_word : :none
    nothing
end

"""Remove a half-open grapheme interval, preserving kill direction and reversible text."""
function menu_search_delete!(input::MenuSearchInput,start::Int,stop::Int;kill::Bool=false,backward::Bool=false)
    if stop>start
        menu_search_push_undo!(input)
        graphemes=menu_search_graphemes(input.value)
        if kill
            editor_kill_push!(input.kills,join(graphemes[start+1:stop]);prepend=backward,accumulate=input.last_action==:kill)
        end
        input.value=join(graphemes[1:start])*join(graphemes[stop+1:end])
        input.cursor=min(start,length(menu_search_graphemes(input.value)))
        input.last_action=kill ? :kill : :none
    elseif !kill
        input.last_action=:none
    end
    nothing
end

"""Resolve ordinary input words through the same native dictionary reducer as the chat editor."""
function menu_search_word_boundary(input::MenuSearchInput,direction::Int)
    if isvalid(input.value)
        graphemes=menu_search_graphemes(input.value)
        before=join(graphemes[1:input.cursor])
        part=direction<0 ? before : join(graphemes[input.cursor+1:end])
        segments=[(;segment...,atomic=false) for segment in JuliaForever2.WordSegmentation.segments(part)]
        distance=editor_word_distance(segments,direction,editor_input_space)
        position=clamp(length(before)+direction*distance,0,length(input.value))
        min(length(menu_search_graphemes(first(input.value,position))),length(graphemes))
    else
        input.cursor
    end
end

"""Yank or rotate killed text without removing neighboring combining characters."""
function menu_search_yank!(input::MenuSearchInput;rotate::Bool=false)
    if !isempty(input.kills) && (!rotate || input.last_action==:yank && length(input.kills)>1)
        menu_search_push_undo!(input)
        if rotate
            before=menu_search_prefix(input)
            after=join(menu_search_graphemes(input.value)[input.cursor+1:end])
            prefix=first(before,max(0,length(before)-length(last(input.kills))))
            editor_kill_rotate!(input.kills)
            inserted=prefix*last(input.kills)
            input.value=inserted*after
            input.cursor=min(length(menu_search_graphemes(inserted)),length(menu_search_graphemes(input.value)))
        else
            menu_search_insert!(input,last(input.kills);snapshot=false,typed=false)
        end
        input.last_action=:yank
    end
    nothing
end

const MENU_SEARCH_KEYS = Dict(
    "\x1b" => :cancel, "\x03" => :cancel, "\r" => :submit, "\n" => :submit,
    "\x7f" => :backspace, "\x08" => :backspace, "\e[3~" => :delete, "\x04" => :delete,
    "\e[D" => :left, "\eOD" => :left, "\x02" => :left, "\e[C" => :right, "\eOC" => :right, "\x06" => :right,
    "\e[H" => :home, "\eOH" => :home, "\e[1~" => :home, "\e[7~" => :home, "\x01" => :home,
    "\e[F" => :end, "\eOF" => :end, "\e[4~" => :end, "\e[8~" => :end, "\x05" => :end,
    "\eb"=>:word_left,"\e[1;3D"=>:word_left,"\e[1;5D"=>:word_left,
    "\ef"=>:word_right,"\e[1;3C"=>:word_right,"\e[1;5C"=>:word_right,
    "\x17"=>:delete_word_backward,"\e\x7f"=>:delete_word_backward,"\e\x08"=>:delete_word_backward,"\ed"=>:delete_word_forward,"\e[3;3~"=>:delete_word_forward,
    "\x15"=>:delete_start,"\x0b"=>:delete_end,"\x19"=>:yank,"\ey"=>:yank_pop,"\x1f"=>:undo,
)

"""Apply one shared single-line command without adopting multiline editor ownership."""
function menu_search_edit!(input::MenuSearchInput,operation::Symbol)
    count=length(menu_search_graphemes(input.value))
    if operation in (:left,:right,:home,:end)
        input.last_action=:none
        input.cursor=operation==:left ? max(0,input.cursor-1) : operation==:right ? min(count,input.cursor+1) : operation==:home ? 0 : count
    elseif operation in (:word_left,:word_right)
        direction=operation==:word_left ? -1 : 1
        if direction<0 ? input.cursor>0 : input.cursor<count
            input.last_action=:none
            input.cursor=menu_search_word_boundary(input,direction)
        end
    elseif operation in (:backspace,:delete)
        input.last_action=:none
        menu_search_delete!(input,operation==:backspace ? max(0,input.cursor-1) : input.cursor,
            operation==:backspace ? input.cursor : min(count,input.cursor+1))
    elseif operation in (:delete_start,:delete_end,:delete_word_backward,:delete_word_forward)
        backward=operation in (:delete_start,:delete_word_backward)
        if backward ? input.cursor>0 : input.cursor<count
            boundary=operation==:delete_start ? 0 : operation==:delete_end ? count : menu_search_word_boundary(input,backward ? -1 : 1)
            menu_search_delete!(input,min(input.cursor,boundary),max(input.cursor,boundary);kill=true,backward)
        end
    elseif operation in (:yank,:yank_pop)
        menu_search_yank!(input;rotate=operation==:yank_pop)
    elseif operation==:undo && !isempty(input.undo)
        input.value,input.cursor=pop!(input.undo);input.last_action=:none
    end
    operation in (:cancel,:submit) ? operation : :handled
end

const MENU_SEARCH_KEYPAD = Dict(57409=>46,57410=>47,57411=>42,57412=>45,57413=>43,57414=>13,57415=>61,57416=>44,
    57417=>-4,57418=>-3,57423=>-14,57424=>-15,57426=>-10)

"""Decode default single-line shortcuts while preserving modifier and release ownership."""
function menu_search_key_packet(data::AbstractString)
    action=get(MENU_SEARCH_KEYS,String(data),:none);printable=nothing
    arrow=match(r"^\e\[1;(\d+)(?::(\d+))?([CDHF])$",data)
    deletion=match(r"^\e\[3;(\d+)(?::(\d+))?~$",data)
    kitty=native_kitty_packet(data)
    other=match(r"^\e\[27;(\d+);(\d+)~$",data)
    code=0;raw_code=0;modifier=-1;released=false;shifted=nothing
    if !isnothing(arrow) || !isnothing(deletion)
        matched=isnothing(arrow) ? deletion::RegexMatch : arrow
        modifier=(something(tryparse(Int,something(matched.captures[1],"")),0)-1)&~192
        released=matched.captures[2]=="3"
        code=isnothing(arrow) ? -10 : arrow.captures[3]=="C" ? -3 : arrow.captures[3]=="D" ? -4 : arrow.captures[3]=="H" ? -14 : -15
    elseif !isnothing(kitty) || !isnothing(other)
        code=something(tryparse(Int,something(isnothing(kitty) ? other.captures[2] : kitty.captures[1],"")),0)
        raw_code=code
        modifier=(isnothing(kitty) ? native_binding_number(other.captures[1],1) : native_binding_number(kitty.captures[4],1))-1
        if !isnothing(kitty)
            modifier &= ~192
            released=kitty.captures[5]=="3"
            shifted=tryparse(Int,something(kitty.captures[2],""))
            base=something(tryparse(Int,something(kitty.captures[3],"")),0)
            code=(modifier & 1)!=0 && 65<=code<=90 ? code+32 : code
            if !(97<=code<=122) && !(code in (96,45,61,91,93,92,59,39,44,46,47,33,64,35,36,37,94,38,42,40,41,95,43,124,126,123,125,58,34,60,62,63)) && base>0
                code=base
            end
        end
        code=57399<=code<=57408 ? code-57351 : get(MENU_SEARCH_KEYPAD,code,code)
    end
    if released
        action=:release
    elseif modifier>=0
        if code in (-4,-3) && modifier in (0,2,4)
            action=code==-4 ? (modifier==0 ? :left : :word_left) : (modifier==0 ? :right : :word_right)
        elseif code in (-14,-15) && modifier==0
            action=code==-14 ? :home : :end
        elseif code==-10 && modifier in (0,2)
            action=modifier==0 ? :delete : :delete_word_forward
        elseif code==127 && modifier in (0,2)
            action=modifier==0 ? :backspace : :delete_word_backward
        elseif code==13 && modifier==0
            action=:submit
        elseif code==27 && modifier==0
            action=:cancel
        elseif modifier==4 && (97<=code<=122 || 65<=code<=90)
            action=get(MENU_SEARCH_KEYS,string(Char(code-(code<=90 ? 64 : 96))),:none)
        elseif modifier==4 && code==45
            action=:undo
        elseif modifier==2 && 32<=code<=126
            action=get(MENU_SEARCH_KEYS,"\e"*string(Char(code)),:none)
        elseif !isnothing(kitty) && modifier in (0,1)
            effective=modifier==1 ? something(shifted,raw_code) : raw_code
            effective=57399<=effective<=57408 ? effective-57351 : get(MENU_SEARCH_KEYPAD,effective,effective)
            if 32<=effective<=0x10ffff && !(0x7f<=effective<=0x9f) && !(0xd800<=effective<=0xdfff) && !(57344<=effective<=63743)
                printable=string(Char(effective))
            end
        end
    end
    if action==:none && native_kitty_text_modifier(modifier)
        associated=native_kitty_text(kitty)
        !isnothing(associated) && (printable=associated)
    end
    (;action,printable)
end

"""Expose safe printable decoding without interpreting modified packets as literal text."""
menu_search_printable(data::AbstractString) = menu_search_key_packet(data).printable

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
            menu_search_insert!(input, clean;typed=false)
            input.pasting = false
            input.paste_buffer = ""
            if !isempty(remaining)
                action = menu_search_input!(input, remaining)
            end
        end
    else
        decoded=menu_search_key_packet(data)
        if decoded.action==:release
            action=:ignored
        elseif decoded.action!=:none
            action=menu_search_edit!(input,decoded.action)
        elseif !isnothing(decoded.printable)
            menu_search_insert!(input,decoded.printable)
        elseif isvalid(data) && all(character -> !(Int(character) < 32 || 0x7f <= Int(character) <= 0x9f), data)
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
        input.last_action=:none
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
