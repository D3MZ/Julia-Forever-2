"""Create a fresh search anchored to the owned document's current viewport, without changing scroll."""
function terminal_search_open!(state::TerminalTranscriptSearch,view::TerminalScrollViewport)
    state.active=true;state.focused=true;state.owner=view.owner;state.epoch=view.epoch
    menu_search_clear!(state.input);state.index=TerminalSearchIndex();state.query="";state.input_error=nothing
    state.matches=TerminalSearchMatch[];state.selected=-1;state.selected_key=nothing;state.anchor=view.top;state.mode=:query
    state.bounds=Tachikoma.Rect();state.previous=-1:-2;state.next=-1:-2;state.hovered=0
    nothing
end
function terminal_search_close!(state::TerminalTranscriptSearch)
    state.active=false;state.focused=false;state.bounds=Tachikoma.Rect();state.hovered=0
    nothing
end

"""Retain selected match identity during streaming; only explicit query/navigation reveals a match."""
function terminal_search_refresh!(state::TerminalTranscriptSearch,view::TerminalScrollViewport)
    target=nothing
    if state.active
        if !view.fullscreen || state.owner!=view.owner || state.epoch!=view.epoch
            terminal_search_close!(state)
        elseif isempty(terminal_search_normalize(state.query))
            state.matches=TerminalSearchMatch[];state.selected=-1;state.selected_key=nothing;state.mode=:retain
        else
            reveal=state.mode!=:retain
            indexed=terminal_search_index!(state.index,terminal_search_plain.(view.document),state.query)
            state.matches=indexed.matches
            if indexed.changed || state.mode!=:retain
                exact=indexed.changed ? findfirst(item->terminal_search_match_key(item)==state.selected_key,state.matches) : state.selected+1
                exact_index=isnothing(exact) ? -1 : exact-1
                total=length(state.matches);selected=-1
                if total>0
                    if state.mode==:query
                        index=findfirst(item->first(item.segments).row>=state.anchor,state.matches)
                        selected=isnothing(index) ? 0 : index-1
                    elseif state.mode in (:next,:previous)
                        base=exact_index>=0 ? exact_index : min(state.selected,total-1)
                        selected=base<0 ? (state.mode==:next ? 0 : total-1) : mod(base+(state.mode==:next ? 1 : -1),total)
                    else
                        selected=exact_index>=0 ? exact_index : clamp(state.selected,0,total-1)
                    end
                end
                state.selected=selected;state.selected_key=selected>=0 ? terminal_search_match_key(state.matches[selected+1]) : nothing
                state.mode=:retain
                if reveal && selected>=0 && view.rect.height>0
                    matched=state.matches[selected+1];top=first(matched.segments).row;bottom=last(matched.segments).row
                    target=top<view.top || bottom>view.top+view.rect.height-1 ? top-fld(view.rect.height,3) : view.top
                end
            end
        end
    end
    target
end

"""Preserve the original first shortcut bindings without stealing ordinary Ctrl+F editor movement."""
function terminal_search_packet(packet::AbstractString;kitty::Bool=false)
    text=terminal_search_text(packet);action=:none;released=false
    if text=="\e"
        action=:close
    elseif text in ("\r","\eOM") || !kitty && text=="\n"
        action=:next
    elseif text=="\x07"
        action=:next
    elseif kitty && text in ("\n","\e\r")
        action=:previous
    else
        code=0;modifiers=-1;base=0
        key=native_kitty_packet(text)
        other=match(r"^\e\[27;(\d+);(\d+)~$",text)
        if !isnothing(key)
            code=something(tryparse(Int,something(key.captures[1],"")),0)
            modifiers=(native_binding_number(key.captures[4],1)-1)&~192
            released=key.captures[5]=="3"
            base=something(tryparse(Int,something(key.captures[3],"")),0)
        elseif !isnothing(other)
            code=something(tryparse(Int,something(other.captures[2],"")),0)
            modifiers=something(tryparse(Int,something(other.captures[1],"")),0)-1
        end
        code=(modifiers & 1)!=0 && 65<=code<=90 ? code+32 : code
        if !(97<=code<=122) && !(code in (96,45,61,91,93,92,59,39,44,46,47,33,64,35,36,37,94,38,42,40,41,95,43,124,126,123,125,58,60,62,63)) && base in (102,103)
            code=base
        end
        if code==102 && modifiers==5
            action=:toggle
        elseif code==103 && modifiers==5
            action=:previous
        elseif code==103 && modifiers==4
            action=:next
        elseif code in (13,57414) && modifiers in (0,1)
            action=modifiers==0 ? :next : :previous
        elseif code==27 && modifiers==0
            action=:close
        end
    end
    (;action,released)
end

"""Use the shared single-line editor, including its paste boundary and advanced editing state."""
function terminal_search_edit!(input::MenuSearchInput,packet::String)
    menu_search_input!(input,packet)
    nothing
end

"""Keep query changes anchored to the selected real match after shared input or paste handling."""
function terminal_search_query_input!(state::TerminalTranscriptSearch,view::TerminalScrollViewport,text::String)
    previous=state.query
    terminal_search_edit!(state.input,text)
    query=menu_search_text(state.input)
    if query!=previous
        state.anchor=0<=state.selected<length(state.matches) ? first(state.matches[state.selected+1].segments).row : view.top
        state.query=query;state.mode=:query
    end
    nothing
end

"""Route a real packet to the search owner; Ctrl+C is not an invented close shortcut."""
function terminal_search_key!(state::TerminalTranscriptSearch,view::TerminalScrollViewport,packet::AbstractString;
        focused::Bool=state.focused,kitty::Bool=false,viewport_owned::Bool=false)
    text=terminal_search_text(packet)
    command=terminal_search_packet(text;kitty);handled=false;closed=false
    if !isvalid(packet) && state.active && focused
        state.input_error="Search input contains invalid UTF-8";handled=true
    elseif state.active && focused && (state.input.pasting || occursin("\e[200~",text))
        handled=true;state.input_error=nothing
        terminal_search_query_input!(state,view,text)
    elseif view.fullscreen && command.action==:toggle
        handled=true
        if !command.released
            if state.active
                terminal_search_close!(state);closed=true
            else
                terminal_search_open!(state,view)
            end
        end
    elseif state.active && focused && !viewport_owned
        handled=true;state.input_error=nothing
        if !command.released
            if command.action==:close
                terminal_search_close!(state);closed=true
            elseif command.action in (:next,:previous)
                isempty(state.query) || (state.mode=command.action)
            else
                terminal_search_query_input!(state,view,text)
            end
        end
    end
    (;handled,closed)
end

"""Hover and press only the original navigation hitboxes; query mouse clicks do not move its cursor."""
function terminal_search_mouse!(state::TerminalTranscriptSearch,x::Integer,y::Integer;
        button::Symbol=:left,action::Symbol=:press)
    bounds=state.bounds;local_x=Int(x)-bounds.x;local_y=Int(y)-bounds.y
    inside=state.active && 0<=local_x<bounds.width && 0<=local_y<bounds.height
    direction=inside && local_y==2 ? (local_x in state.previous ? -1 : local_x in state.next ? 1 : 0) : 0
    changed=state.hovered!=direction;state.hovered=direction
    handled=direction!=0 && button==:left && action==:press
    handled && !isempty(state.query) && (state.mode=direction<0 ? :previous : :next)
    (;handled,changed,inside)
end
