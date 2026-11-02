# Native user-message selection; durable branching is owned by the session service.
public ForkMessage, ForkMenu, fork_menu, fork_input!, fork_lines, fork_selected, fork_mouse!, fork_dispose!, fork_draw!

Base.@kwdef struct ForkMessage
    id::String
    text::String
end
Base.@kwdef mutable struct ForkMenu{S,C,F} <: SessionSelectionMenu
    messages::Vector{ForkMessage}
    on_select::S
    on_cancel::C
    style::F
    bold::Bool=false
    cursor::Int=1
    maximum_rows::Int=10
    timer::Any=nothing
    disposed::Bool=false
end

"""Select original entry IDs; the owner alone creates a durable fork and restores editor text."""
function fork_menu(messages::AbstractVector{ForkMessage};on_select,on_cancel,initial_selected=nothing,
        style=tree_default_style,bold::Bool=false,schedule=tree_schedule)
    selected=findfirst(message->message.id==initial_selected,messages)
    menu=ForkMenu(;messages=deepcopy(messages),on_select,on_cancel,style,bold,
        cursor=isnothing(selected) ? max(1,length(messages)) : selected)
    if isempty(messages)
        menu.timer=schedule(()->(menu.disposed || menu.on_cancel()),0.1)
    end
    menu
end
fork_selected(menu::ForkMenu)=1<=menu.cursor<=length(menu.messages) ? menu.messages[menu.cursor].id : nothing
fork_mouse!(menu::ForkMenu,args...;kwargs...)=nothing

function fork_input!(menu::ForkMenu,data::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    count=length(menu.messages)
    navigation=native_selector_navigation(selectors,data)
    result=(action=:none,invoked=false,outcome=nothing)
    if !menu.disposed
        if navigation==:up
            menu.cursor=menu.cursor==1 ? count : menu.cursor-1
        elseif navigation==:down
            menu.cursor=menu.cursor==count ? 1 : menu.cursor+1
        elseif navigation in (:page_up,:page_down) && count>0
            menu.cursor=clamp(menu.cursor+(navigation==:page_up ? -1 : 1)*menu.maximum_rows,1,count)
        elseif native_selector_matches(selectors,:confirm,data) && 1<=menu.cursor<=count
            id=menu.messages[menu.cursor].id
            result=(action=:select,invoked=true,outcome=menu.on_select(id),entry_id=id)
        elseif native_selector_matches(selectors,:cancel,data)
            result=(action=:cancel,invoked=true,outcome=menu.on_cancel())
        end
    end
    result
end

function fork_lines(menu::ForkMenu,width::Integer)
    columns=Int(width)
    lines=[session_line(menu)]
    append!(lines,session_text(menu,"Fork from Message",columns;bold=true))
    append!(lines,session_text(menu,"Select a user message to copy the active path up to that point into a new session",columns;token=:muted))
    border=session_line(menu,repeat("─",max(0,columns)),:border)
    push!(lines,session_line(menu),border,session_line(menu))
    count=length(menu.messages)
    if count==0
        push!(lines,session_line(menu,"  No user messages found",:muted))
    else
        start=max(1,min(menu.cursor-fld(menu.maximum_rows,2),count-menu.maximum_rows+1))
        stop=min(start+menu.maximum_rows-1,count)
        for index in start:stop
            selected=index==menu.cursor
            text=String(strip(replace(menu.messages[index].text,'\n'=>' ')))
            body=session_clip(session_line(menu,text),columns-2)
            body=[Tachikoma.Span(span.content,session_style(menu;bold=selected)) for span in body]
            if menu_search_width(text)>columns-2
                body[end]=session_span(menu,body[end].content)
            end
            push!(lines,[session_span(menu,selected ? "› " : "  ",selected ? :accent : :default);body])
            push!(lines,session_line(menu,"  Message $index of $count",:muted),session_line(menu))
        end
        if start>1 || stop<count
            push!(lines,session_line(menu,"  ($(menu.cursor)/$count)",:muted))
        end
    end
    push!(lines,session_line(menu),border)
    lines
end
fork_draw!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,menu::ForkMenu)=session_draw_lines!(buffer,x,y,width,fork_lines(menu,width))
function fork_dispose!(menu::ForkMenu)
    menu.disposed=true
    session_cancel_timer(menu.timer)
    menu.timer=nothing
    nothing
end
