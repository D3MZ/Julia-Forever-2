public RegularTerminalState, regular_present!, regular_finish!, regular_invalidate!

"""Native main-screen state; row indices are logical document rows, never guessed terminal coordinates."""
Base.@kwdef mutable struct RegularTerminalState
    rows::Vector{String} = String[]
    width::Int = 0
    height::Int = 0
    cursor::Int = 0
    viewport::Int = 0
    working_rows::Int = 0
    cleared::Int = 0
end

"""Serialize trusted native styles while sanitizing every untrusted text glyph."""
function regular_row(line::Vector{Tachikoma.Span})
    sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,startup_safe_text(span.content))
        end
        print(io,"\e[0m\e]8;;\a")
    end
end

function regular_move!(io::IO,delta::Int)
    delta==0 || print(io,"\e[",abs(delta),delta>0 ? "B" : "A")
    nothing
end

"""Invalidate after a terminal lease or resize without discarding ownership of the caller's IO."""
function regular_invalidate!(state::RegularTerminalState)
    state.width=-1
    nothing
end

function regular_cursor!(state::RegularTerminalState,io::IO,cursor::Union{Nothing,Tuple{Int,Int}},count::Int,visible::Bool)
    if isnothing(cursor) || count==0
        print(io,"\e[?25l")
    else
        column,row=cursor
        target=clamp(row-1,0,count-1)
        regular_move!(io,target-state.cursor)
        print(io,"\e[",max(1,column),"G",visible ? "\e[?25h" : "\e[?25l")
        state.cursor=target
    end
    nothing
end

function regular_full!(state::RegularTerminalState,io::IO,rows::Vector{String},width::Int,height::Int,clear::Bool)
    print(io,"\e[?2026h")
    if clear
        print(io,"\e[2J\e[H\e[3J")
        state.cleared+=1
    end
    for (index,row) in enumerate(rows)
        index==1 || print(io,"\r\n")
        print(io,row)
    end
    print(io,"\e[?2026l")
    state.cursor=max(0,length(rows)-1)
    state.viewport=max(0,length(rows)-height)
    state.working_rows=clear ? length(rows) : max(state.working_rows,length(rows))
    nothing
end

function regular_changes(old::Vector{String},rows::Vector{String})
    first_changed=0;last_changed=0
    for index in 1:max(length(old),length(rows))
        previous=index<=length(old) ? old[index] : ""
        current=index<=length(rows) ? rows[index] : ""
        if previous!=current
            first_changed==0 && (first_changed=index)
            last_changed=index
        end
    end
    if length(rows)>length(old)
        first_changed==0 && (first_changed=length(old)+1)
        last_changed=length(rows)
    end
    (;first_changed,last_changed)
end

function regular_deleted!(state::RegularTerminalState,io::IO,rows::Vector{String},height::Int)
    target=max(0,length(rows)-1)
    extra=length(state.rows)-length(rows)
    possible=target>=state.viewport && extra<=height
    if possible
        print(io,"\e[?2026h")
        regular_move!(io,target-state.cursor)
        print(io,"\r")
        offset=isempty(rows) ? 0 : 1
        regular_move!(io,offset)
        for index in 1:extra
            print(io,"\r\e[2K")
            index==extra || regular_move!(io,1)
        end
        regular_move!(io,-max(0,extra-1+offset))
        print(io,"\e[?2026l")
        state.cursor=target
    end
    possible
end

function regular_patch!(state::RegularTerminalState,io::IO,rows::Vector{String},height::Int,first_changed::Int,last_changed::Int)
    append_only=length(rows)>length(state.rows) && first_changed==length(state.rows)+1 && first_changed>1
    target=first_changed-1-Int(append_only)
    bottom=state.viewport+height-1
    print(io,"\e[?2026h")
    if target>bottom
        regular_move!(io,height-1-clamp(state.cursor-state.viewport,0,height-1))
        print(io,repeat("\r\n",target-bottom))
        state.viewport+=target-bottom
        state.cursor=target
    end
    regular_move!(io,target-state.cursor)
    print(io,append_only ? "\r\n" : "\r")
    final=min(last_changed,length(rows))
    for index in first_changed:final
        index==first_changed || print(io,"\r\n")
        print(io,"\e[2K",rows[index])
    end
    state.cursor=final-1
    if length(state.rows)>length(rows)
        regular_move!(io,max(0,length(rows)-final))
        state.cursor=max(state.cursor,length(rows)-1)
        extra=length(state.rows)-length(rows)
        print(io,repeat("\r\n\e[2K",extra))
        regular_move!(io,-extra)
    end
    print(io,"\e[?2026l")
    state.working_rows=max(state.working_rows,length(rows))
    state.viewport=max(state.viewport,state.cursor-height+1)
    nothing
end

"""Render native rows into normal terminal scrollback with relative updates and explicit shrink policy."""
function regular_present!(state::RegularTerminalState,io::IO,lines::Vector{Vector{Tachikoma.Span}},width::Integer,height::Integer;
        cursor::Union{Nothing,Tuple{Int,Int}}=nothing,hardware_cursor::Bool=false,clear_on_shrink::Bool=false)
    regular_rendered!(state,io,regular_row.(lines),Int(width),Int(height);cursor,hardware_cursor,clear_on_shrink)
end

"""Consume only ANSI already generated by the native structured row serializer."""
function regular_rendered!(state::RegularTerminalState,io::IO,rows::Vector{String},width::Int,height::Int;
        cursor::Union{Nothing,Tuple{Int,Int}}=nothing,hardware_cursor::Bool=false,clear_on_shrink::Bool=false)
    changed=regular_changes(state.rows,rows)
    resized=(state.width!=0 && state.width!=width)||(state.height!=0 && state.height!=height)
    clear=resized || (clear_on_shrink && length(rows)<state.working_rows)
    first_frame=isempty(state.rows) && !resized
    if clear || first_frame
        regular_full!(state,io,rows,width,height,clear)
    elseif changed.first_changed>length(rows)
        regular_deleted!(state,io,rows,height) || regular_full!(state,io,rows,width,height,true)
    elseif changed.first_changed>0
        if changed.first_changed-1<state.viewport
            regular_full!(state,io,rows,width,height,true)
        else
            regular_patch!(state,io,rows,height,changed.first_changed,changed.last_changed)
        end
    end
    regular_cursor!(state,io,cursor,length(rows),hardware_cursor)
    state.rows=copy(rows);state.width=width;state.height=height
    flush(io)
    nothing
end

"""Leave the shell below the actual retained document; a suspended lease preserves the screen instead."""
function regular_finish!(state::RegularTerminalState,io::IO;preserve::Bool=false)
    if !preserve && !isempty(state.rows)
        print(io," ")
        regular_move!(io,length(state.rows)-state.cursor)
        print(io,"\r\n")
    end
    print(io,"\e[?25h")
    flush(io)
    nothing
end
