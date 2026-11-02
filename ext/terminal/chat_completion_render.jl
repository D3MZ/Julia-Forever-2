"""Render untrusted filesystem labels literally, never as terminal control sequences."""
function chat_completion_label(text::AbstractString)::String
    join(iscntrl(char) || 0x202a<=Int(char)<=0x202e || 0x2066<=Int(char)<=0x2069 ? escape_string(string(char)) : string(char) for char in text)
end
chat_completion_style(::Nothing,token)=pi_style(token==:accent ? :accent : :text_dim)
chat_completion_style(runtime::ThemeRuntime,token)=theme_style(runtime,token)
chat_completion_clip(text::AbstractString,width::Int)=menu_search_slice(text,0,max(0,width))
"""Render the source list's adaptive primary column and actual selected/scroll states."""
function chat_completion_list_lines(state::ChatCompletionState,width::Int;runtime=nothing)
    rows=Vector{Tachikoma.Span}[];selected=chat_completion_style(runtime,:accent);muted=chat_completion_style(runtime,:muted)
    if isempty(state.items)
        push!(rows,[Tachikoma.Span("  No matching commands",muted)])
    else
        widest=maximum(item->menu_search_width(chat_completion_label(isempty(item.label) ? item.value : item.label))+2,state.items)
        primary=startswith(state.prefix,'/') ? clamp(widest,12,32) : 32
        indices=chat_completion_range(state)
        for index in indices
            item=state.items[index];active=index==state.selected;prefix=active ? "→ " : "  "
            label=chat_completion_label(isempty(item.label) ? item.value : item.label)
            description=isnothing(item.description) ? "" : chat_completion_label(strip(replace(item.description,r"[\r\n]+"=>" ")))
            spans=Tachikoma.Span[];detailed=false
            if !isempty(description) && width>40
                column=max(1,min(primary,width-6));value=chat_completion_clip(label,max(1,column-2))
                spacing=repeat(" ",max(1,column-menu_search_width(value)));remaining=width-(2+menu_search_width(value)+length(spacing))-2
                if remaining>10
                    detail=chat_completion_clip(description,remaining)
                    if active
                        push!(spans,Tachikoma.Span(prefix*value*spacing*detail,selected))
                    else
                        push!(spans,Tachikoma.Span(prefix*value,Tachikoma.RESET),Tachikoma.Span(spacing*detail,muted))
                    end
                    detailed=true
                end
            end
            detailed || push!(spans,Tachikoma.Span(prefix*chat_completion_clip(label,width-4),active ? selected : Tachikoma.RESET))
            push!(rows,spans)
        end
        if first(indices)>1 || last(indices)<length(state.items)
            push!(rows,[Tachikoma.Span(chat_completion_clip("  ($(state.selected)/$(length(state.items)))",width-2),muted)])
        end
    end
    rows
end
"""Compose the actual completion rows below the native bordered editor without writing terminal bytes."""
function chat_completion_lines(state::ChatCompletionState,width::Int,height::Int;runtime=nothing,padding=0,hardware_cursor=false,top_border=nothing,border_style=nothing)
    chat_completion_sync!(state)
    base=chat_editor_lines(state.editor,width,height;runtime,padding,hardware_cursor,top_border,border_style)
    rows=copy(base.lines)
    if state.mode!=:none
        margin=clamp(padding,0,max(0,fld(width-1,2)));content=max(1,width-2margin)
        for line in chat_completion_list_lines(state,content;runtime)
            count=sum(span->menu_search_width(span.content),line;init=0)
            push!(rows,vcat([Tachikoma.Span(repeat(" ",margin),Tachikoma.RESET)],line,[Tachikoma.Span(repeat(" ",max(0,content-count)+margin),Tachikoma.RESET)]))
        end
    end
    merge(base,(lines=rows,))
end
"""Use recorded visible list geometry for click/press/wheel; editor drag selection remains untouched."""
function chat_completion_open_mouse!(state::ChatCompletionState,type::Symbol,button::Symbol,x::Int,y::Int,width::Int;height=32,padding=0,wheel_delta=0)
    chat_completion_sync!(state)
    before=chat_completion_context(state.editor)
    start=state.editor.visible_rows+2;indices=chat_completion_range(state)
    rows=length(indices)+(isempty(indices) || first(indices)==1 && last(indices)==length(state.items) ? 0 : 1)
    active=state.mode!=:none && start<=y<start+rows
    handled=false;previous=state.selected
    if type==:release && (!active || x<0 || x>=width) || type==:press && !active
        state.pressed=nothing;state.press_position=nothing
    end
    if active && !isempty(state.items)
        if type==:wheel && wheel_delta!=0
            state.selected=clamp(state.selected+(wheel_delta<0 ? -1 : 1),1,length(state.items));handled=true
        elseif button==:left && type in (:press,:click)
            index=first(indices)+y-start
            if index in indices
                handled=true
                if type==:press
                    state.pressed=index;state.press_position=(x,y);state.selected=index
                else
                    state.selected=state.press_position==(x,y) ? something(state.pressed,index) : index
                    state.pressed=nothing;state.press_position=nothing
                    result=chat_completion_install!(state,state.items[state.selected],state.prefix)
                    result.ok && chat_completion_cancel!(state)
                end
            end
        end
    elseif !active
        handled=chat_editor_mouse!(state.editor,type,button,x,y,width;padding).handled
        if before!=chat_completion_context(state.editor) && state.mode!=:none
            chat_completion_request!(state;force=state.mode==:force)
        end
    end
    state.observed=chat_completion_context(state.editor)
    state.selected==previous || chat_completion_changed!(state)
    (handled,focus=handled)
end

function chat_completion_mouse!(state::ChatCompletionState,type::Symbol,button::Symbol,x::Int,y::Int,width::Int;kwargs...)
    state.closed ? (handled=false,focus=false) : chat_completion_open_mouse!(state,type,button,x,y,width;kwargs...)
end
