"""An owned editor checkpoint keeps paste expansion and cursor position reversible together."""
Base.@kwdef struct ChatEditSnapshot
    text::String = ""
    cursor::Int = 0
    pastes::Dict{Int,String} = Dict{Int,String}()
    paste_counter::Int = 0
end

"""Native multiline state shares its text storage with the existing public TextInput widget."""
Base.@kwdef mutable struct ChatEditorState
    input::Tachikoma.TextInput = Tachikoma.TextInput(;label="")
    observed::String = ""
    observed_cursor::Int = 0
    undo::Vector{ChatEditSnapshot} = ChatEditSnapshot[]
    pastes::Dict{Int,String} = Dict{Int,String}()
    paste_counter::Int = 0
    paste_buffer::String = ""
    pasting::Bool = false
    history::Vector{String} = String[]
    history_index::Int = -1
    history_draft::Union{Nothing,ChatEditSnapshot} = nothing
    kills::Vector{String} = String[]
    last_action::Symbol = :none
    preferred::Union{Nothing,Int} = nothing
    snapped::Union{Nothing,Int} = nothing
    jump::Symbol = :none
    scroll::Int = 0
    layout_width::Int = 80
    terminal_rows::Int = 24
    visible_rows::Int = 1
    focused::Bool = false
    disable_submit::Bool = false
    last_escape_ms::Int = 0
end
ChatEditorState(input::Tachikoma.TextInput) = ChatEditorState(;input,observed=Tachikoma.text(input),observed_cursor=input.cursor)
chat_text(editor::ChatEditorState) = Tachikoma.text(editor.input)
chat_normalize(text::AbstractString)::String = replace(replace(replace(String(text),"\r\n"=>"\n"),'\r'=>'\n'),'\t'=>"    ")
chat_prefix(text::AbstractString,count::Integer) = first(text,clamp(count,0,length(text)))
chat_suffix(text::AbstractString,count::Integer) = chop(text;head=clamp(count,0,length(text)),tail=0)
chat_slice(text::AbstractString,start::Integer,stop::Integer) = chat_prefix(chat_suffix(text,start),max(0,stop-start))
chat_parseint(::Nothing) = nothing
chat_parseint(text::AbstractString) = tryparse(Int,text)
chat_utf16(text::AbstractString) = sum(char->Int(char)>0xffff ? 2 : 1,text;init=0)
chat_space(text::AbstractString) = occursin(r"\s",text)
chat_cjk(text::AbstractString) = occursin(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Bopomofo}]",text)
const CHAT_PASTE_MARKER = r"\[paste #(\d+)( (\+\d+ lines|\d+ chars))?\]"

"""Commit shared text and cursor together, recording the last native-owned observable state."""
function chat_write!(editor::ChatEditorState,text::AbstractString,cursor::Integer)
    Tachikoma.set_text!(editor.input,String(text))
    editor.input.cursor=clamp(cursor,0,length(editor.input.buffer))
    editor.observed=String(text);editor.observed_cursor=editor.input.cursor
    nothing
end
chat_snapshot(editor::ChatEditorState) = ChatEditSnapshot(;text=chat_text(editor),cursor=editor.input.cursor,pastes=copy(editor.pastes),paste_counter=editor.paste_counter)
chat_push_undo!(editor::ChatEditorState) = push!(editor.undo,chat_snapshot(editor))
function chat_exit_history!(editor::ChatEditorState)
    editor.history_index=-1;editor.history_draft=nothing
    nothing
end
function chat_cursor!(editor::ChatEditorState,cursor::Integer)
    editor.input.cursor=clamp(cursor,0,length(editor.input.buffer));editor.observed_cursor=editor.input.cursor
    editor.preferred=nothing;editor.snapped=nothing
    nothing
end
function chat_set_text!(editor::ChatEditorState,text::AbstractString)
    normalized=chat_normalize(text)
    chat_text(editor)!=normalized && chat_push_undo!(editor)
    editor.last_action=:none;chat_exit_history!(editor)
    empty!(editor.pastes);editor.paste_counter=0;editor.scroll=0
    chat_write!(editor,normalized,length(normalized));chat_cursor!(editor,length(normalized))
    nothing
end

"""Reconcile external TextInput text setters without replacing the public input object."""
function chat_sync!(editor::ChatEditorState)
    text=chat_text(editor)
    if text!=editor.observed
        push!(editor.undo,ChatEditSnapshot(;text=editor.observed,cursor=editor.observed_cursor,pastes=copy(editor.pastes),paste_counter=editor.paste_counter))
        cursor=editor.input.cursor
        empty!(editor.pastes);editor.paste_counter=0;editor.scroll=0;editor.last_action=:none
        chat_exit_history!(editor);chat_write!(editor,chat_normalize(text),cursor);chat_cursor!(editor,cursor)
    elseif editor.input.cursor!=editor.observed_cursor
        chat_cursor!(editor,editor.input.cursor)
    end
    nothing
end
function chat_position(editor::ChatEditorState)
    before=chat_prefix(chat_text(editor),editor.input.cursor)
    lines=split(before,'\n';keepempty=true)
    (line=length(lines),col=length(last(lines)))
end
function chat_line_offset(lines,line::Int)
    sum(value->length(value)+1,lines[1:line-1];init=0)
end
function chat_expanded_text(editor::ChatEditorState)
    replace(chat_text(editor),CHAT_PASTE_MARKER=>marker->begin
        found=match(CHAT_PASTE_MARKER,marker)
        id=chat_parseint(found.captures[1])
        get(editor.pastes,id,marker)
    end)
end

"""Return marker-aware graphemes with character offsets, preserving atomic paste editing."""
function chat_segments(editor::ChatEditorState,text::AbstractString)
    result=NamedTuple{(:text,:start,:stop,:atomic),Tuple{String,Int,Int,Bool}}[]
    offset=0
    while offset<length(text)
        tail=chat_suffix(text,offset)
        found=startswith(tail,"[paste #") ? match(CHAT_PASTE_MARKER,tail) : nothing
        id=isnothing(found) ? nothing : chat_parseint(found.captures[1])
        atomic=!isnothing(found) && found.offset==1 && haskey(editor.pastes,id)
        segment=atomic ? String(found.match) : String(first(Base.Unicode.graphemes(tail)))
        push!(result,(text=segment,start=offset,stop=offset+length(segment),atomic))
        offset+=length(segment)
    end
    result
end

"""Maintain bounded newest-first history while preserving consecutive duplicate suppression."""
function chat_add_history!(editor::ChatEditorState,text::AbstractString)
    value=String(strip(text))
    if !isempty(value) && (isempty(editor.history) || first(editor.history)!=value)
        pushfirst!(editor.history,value)
        length(editor.history)>100 && pop!(editor.history)
    end
    nothing
end
function chat_history!(editor::ChatEditorState,direction::Int)
    editor.last_action=:none
    next=editor.history_index-direction
    if !isempty(editor.history) && -1<=next<length(editor.history)
        if editor.history_index==-1 && next>=0
            chat_push_undo!(editor);editor.history_draft=chat_snapshot(editor)
        end
        editor.history_index=next
        if next==-1
            draft=editor.history_draft;editor.history_draft=nothing
            text=isnothing(draft) ? "" : draft.text;cursor=isnothing(draft) ? 0 : draft.cursor
            chat_write!(editor,text,cursor);chat_cursor!(editor,cursor)
        else
            text=editor.history[next+1];cursor=direction==-1 ? 0 : length(text)
            chat_write!(editor,text,cursor);chat_cursor!(editor,cursor)
        end
        editor.scroll=0
    end
    nothing
end

"""Restore the owned text/paste checkpoint without changing kill-ring or prompt-history contents."""
function chat_undo!(editor::ChatEditorState)
    chat_exit_history!(editor)
    if !isempty(editor.undo)
        snapshot=pop!(editor.undo);editor.pastes=copy(snapshot.pastes);editor.paste_counter=snapshot.paste_counter
        chat_write!(editor,snapshot.text,snapshot.cursor);editor.last_action=:none;editor.preferred=nothing
    end
    nothing
end

"""Insert normalized text atomically at the shared cursor, leaving policy acceptance to the owner."""
function chat_insert!(editor::ChatEditorState,text::AbstractString;snapshot::Bool=true,typed::Bool=false)
    if !isempty(text)
        if snapshot && (!typed || chat_space(text) || editor.last_action!=:type_word)
            chat_push_undo!(editor)
        end
        chat_exit_history!(editor)
        editor.last_action=typed ? :type_word : :none
        value=chat_normalize(text);cursor=editor.input.cursor
        chat_write!(editor,chat_prefix(chat_text(editor),cursor)*value*chat_suffix(chat_text(editor),cursor),cursor+length(value))
        chat_cursor!(editor,editor.input.cursor)
    end
    nothing
end

"""Delete a half-open text interval with reversible, direction-sensitive kill accumulation."""
function chat_delete!(editor::ChatEditorState,start::Int,stop::Int;kill::Bool=false,backward::Bool=false)
    chat_exit_history!(editor)
    if stop>start
        chat_push_undo!(editor)
        text=chat_text(editor);removed=chat_slice(text,start,stop)
        if kill
            if editor.last_action==:kill && !isempty(editor.kills)
                editor.kills[end]=backward ? removed*editor.kills[end] : editor.kills[end]*removed
            else
                push!(editor.kills,removed)
            end
        end
        editor.last_action=kill ? :kill : :none
        chat_write!(editor,chat_prefix(text,start)*chat_suffix(text,stop),start);chat_cursor!(editor,start)
    elseif !kill
        editor.last_action=:none
    end
    nothing
end
function chat_yank!(editor::ChatEditorState;rotate::Bool=false)
    if !isempty(editor.kills) && (!rotate || editor.last_action==:yank && length(editor.kills)>1)
        chat_push_undo!(editor)
        if rotate
            stop=editor.input.cursor;start=max(0,stop-length(last(editor.kills)))
            chat_write!(editor,chat_prefix(chat_text(editor),start)*chat_suffix(chat_text(editor),stop),start)
            pushfirst!(editor.kills,pop!(editor.kills))
        end
        chat_insert!(editor,last(editor.kills);snapshot=false);editor.last_action=:yank
    end
    nothing
end

"""Clear only after a successful submission, preserving unsent data when the owner rejects it."""
function chat_accept!(editor::ChatEditorState)
    chat_write!(editor,"",0);empty!(editor.undo);empty!(editor.pastes)
    editor.paste_counter=0;editor.scroll=0;editor.last_action=:none
    chat_exit_history!(editor);chat_cursor!(editor,0)
    nothing
end
