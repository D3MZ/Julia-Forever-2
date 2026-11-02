"""Own cancellable completion work separately from the public editor and from session/provider tasks."""
Base.@kwdef mutable struct ChatCompletionState{P}
    editor::ChatEditorState
    observed::NamedTuple{(:text,:cursor),Tuple{String,Int}}=chat_completion_context(editor)
    provider::P
    mode::Symbol=:none
    prefix::String=""
    items::Vector{ChatCompletionItem}=ChatCompletionItem[]
    selected::Int=1
    pressed::Union{Nothing,Int}=nothing
    press_position::Union{Nothing,Tuple{Int,Int}}=nothing
    max_visible::Int=5
    generation::UInt=UInt(0)
    revision::UInt=UInt(0)
    cancelled::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false)
    timer::Union{Nothing,Timer}=nothing
    worker::Union{Nothing,Task}=nothing
    closed::Bool=false
    error::Union{Nothing,String}=nothing
    on_change::Function=Returns(nothing)
end
chat_completion_visible(value::Real)=isfinite(value) ? clamp(floor(Int,value),3,20) : 5
ChatCompletionState(editor::ChatEditorState,provider;max_visible=5,on_change::Function=Returns(nothing))=ChatCompletionState(;editor,provider,max_visible=chat_completion_visible(max_visible),on_change)
"""Publish a revision and notify only through the owner-supplied wake-up callback."""
function chat_completion_changed!(state::ChatCompletionState)
    state.revision+=UInt(1);generation=state.generation
    notified=preference_attempt(state.on_change)
    notified.ok || generation!=state.generation || (state.error="Completion wake-up callback failed: "*notified.reason)
    nothing
end
function chat_completion_cancel_request!(state::ChatCompletionState)
    state.generation+=UInt(1);state.cancelled[]=true
    timer=state.timer
    isnothing(timer) || close(timer)
    state.timer=nothing
    nothing
end
function chat_completion_cancel!(state::ChatCompletionState)
    chat_completion_cancel_request!(state)
    state.mode=:none;state.prefix="";empty!(state.items);state.selected=1;state.pressed=nothing;state.press_position=nothing;chat_completion_changed!(state)
    nothing
end
function chat_completion_close!(state::ChatCompletionState)
    state.closed=true;chat_completion_cancel!(state)
    nothing
end
function chat_completion_install!(state::ChatCompletionState,item::ChatCompletionItem,prefix::String)
    snapshot=chat_completion_context(state.editor)
    attempt=preference_attempt(()->chat_completion_apply(state.provider,snapshot,item,prefix))
    if attempt.ok && attempt.value isa NamedTuple && attempt.value.text isa String && attempt.value.cursor isa Int
        chat_push_undo!(state.editor);state.editor.last_action=:none
        chat_write!(state.editor,attempt.value.text,attempt.value.cursor);chat_cursor!(state.editor,attempt.value.cursor)
        state.observed=chat_completion_context(state.editor);chat_completion_changed!(state)
        (ok=true,reason="")
    else
        reason=attempt.ok ? "Completion returned an invalid text/cursor result" : attempt.reason
        state.error=reason
        (ok=false,reason)
    end
end
function chat_completion_publish!(state::ChatCompletionState,result::ChatCompletionResult,force::Bool)
    state.items=copy(result.items);state.prefix=result.prefix;state.selected=1;state.mode=force ? :force : :regular
    exact=findfirst(item->item.value==result.prefix,state.items)
    prefix=findfirst(item->startswith(item.value,result.prefix),state.items)
    state.selected=something(exact,prefix,1);state.pressed=nothing;state.press_position=nothing;chat_completion_changed!(state)
    nothing
end
function chat_completion_start!(state::ChatCompletionState,generation::UInt,force::Bool,explicit::Bool)
    previous=state.worker
    state.worker=@async begin
        isnothing(previous) || wait(previous;throw=false)
        if !state.closed && generation==state.generation
            cancelled=Threads.Atomic{Bool}(false);state.cancelled=cancelled
            snapshot=chat_completion_context(state.editor)
            attempt=preference_attempt(()->chat_completion_suggest(state.provider,snapshot,force,cancelled))
            current=!state.closed && !cancelled[] && state.generation==generation && chat_completion_context(state.editor)==snapshot
            if current
                state.cancelled=Threads.Atomic{Bool}(false)
                if !attempt.ok
                    state.error=attempt.reason;chat_completion_cancel!(state)
                elseif isnothing(attempt.value) || attempt.value isa ChatCompletionResult && isempty(attempt.value.items)
                    chat_completion_cancel!(state)
                elseif attempt.value isa ChatCompletionResult
                    result=attempt.value
                    if force && explicit && length(result.items)==1
                        chat_completion_install!(state,first(result.items),result.prefix)
                    else
                        chat_completion_publish!(state,result,force)
                    end
                else
                    state.error="Completion provider returned invalid suggestions";chat_completion_cancel!(state)
                end
            end
        end
    end
    nothing
end
"""Queue source-faithful requests; later generations wait for prior work and cannot publish stale text."""
function chat_completion_request!(state::ChatCompletionState;force::Bool=false,explicit::Bool=false)
    if !state.closed && (!force || chat_completion_should_force(state.provider,chat_completion_context(state.editor)))
        chat_completion_cancel_request!(state);state.error=nothing;generation=state.generation
        before=chat_completion_before(chat_completion_context(state.editor))
        debounce=!force && !explicit && !isnothing(chat_completion_prefix(before;attachment=true))
        if debounce
            state.timer=Timer(0.020) do timer
                state.timer===timer && (state.timer=nothing)
                state.closed || generation!=state.generation || chat_completion_start!(state,generation,force,explicit)
            end
        else
            chat_completion_start!(state,generation,force,explicit)
        end
    end
    nothing
end
function chat_completion_set_visible!(state::ChatCompletionState,visible::Real)
    state.max_visible=chat_completion_visible(visible);chat_completion_changed!(state)
    nothing
end
chat_completion_range(state::ChatCompletionState)=begin
    first=max(1,min(state.selected-fld(state.max_visible,2),length(state.items)-state.max_visible+1))
    first:min(first+state.max_visible-1,length(state.items))
end
"""Route actual completion interactions before editing; requests remain owned by the host."""
function chat_completion_open_input!(state::ChatCompletionState,packet::AbstractString)
    chat_completion_sync!(state)
    action=chat_key_packet(packet).action;response=(action=:handled,text="")
    active=state.mode!=:none && !isempty(state.items)
    if action==:copy
        response=(action=:copy,text="")
    elseif active && action==:interrupt
        chat_completion_cancel!(state)
    elseif active && action in (:up,:down,:page_up,:page_down)
        count=length(state.items);previous=state.selected
        state.selected=action==:up ? mod1(state.selected-1,count) : action==:down ? mod1(state.selected+1,count) : clamp(state.selected+(action==:page_up ? -1 : 1)*state.max_visible,1,count)
        state.selected==previous || chat_completion_changed!(state)
    elseif active && (action in (:complete,:submit) || packet=="\n")
        slash=startswith(state.prefix,'/')
        outcome=chat_completion_install!(state,state.items[state.selected],state.prefix)
        if outcome.ok
            chat_completion_cancel!(state)
            action!=:complete && slash && (response=chat_editor_input!(state.editor,packet))
        end
    elseif action==:complete
        snapshot=chat_completion_context(state.editor);before=lstrip(chat_completion_before(snapshot))
        firstline=chat_position(state.editor).line==1
        force=!(firstline && startswith(before,'/') && !occursin(' ',before))
        chat_completion_request!(state;force,explicit=true)
    else
        before=chat_completion_context(state.editor)
        jumping=state.editor.jump!=:none
        paste=occursin("\e[200~",packet) || state.editor.pasting
        paste && chat_completion_cancel!(state)
        response=chat_editor_input!(state.editor,packet)
        after=chat_completion_context(state.editor)
        if response.action==:submit || action==:newline || action==:submit && before.text!=after.text
            chat_completion_cancel!(state)
        elseif !paste
            typed=!jumping && action==:none && before.text!=after.text
            refresh=action in (:left,:right,:backspace,:delete) || typed
            if active && refresh
                chat_completion_request!(state;force=state.mode==:force)
            elseif !active && (action in (:backspace,:delete) || typed)
                text=chat_completion_before(after)
                slash=chat_position(state.editor).line==1 && startswith(lstrip(text),'/')
                attachment=!isnothing(chat_completion_prefix(text;attachment=true))
                printable=something(chat_key_packet(packet).printable,String(packet))
                trigger=action in (:backspace,:delete) || printable=="/" && strip(text)=="/" || printable=="@" || occursin(r"[a-zA-Z0-9.\-_\p{scx:Han}\p{scx:Hiragana}\p{scx:Katakana}\p{scx:Hangul}\p{scx:Bopomofo}]",printable)
                trigger && (slash || attachment) && chat_completion_request!(state)
            end
        end
    end
    state.observed=chat_completion_context(state.editor)
    response
end

"""Invalidate completion ownership when another real host control edits shared text or moves its cursor."""
function chat_completion_sync!(state::ChatCompletionState)
    current=chat_completion_context(state.editor)
    if current!=state.observed
        chat_completion_cancel!(state);state.observed=current
    end
    nothing
end
function chat_completion_set_text!(state::ChatCompletionState,text::AbstractString)
    chat_completion_cancel!(state);chat_set_text!(state.editor,text)
    state.observed=chat_completion_context(state.editor)
    nothing
end

function chat_completion_input!(state::ChatCompletionState,packet::AbstractString)
    state.closed ? (action=:handled,text="") : chat_completion_open_input!(state,packet)
end
