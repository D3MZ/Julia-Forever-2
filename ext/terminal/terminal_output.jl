"""Own terminal-only progress and cursor state without background timers or message content."""
Base.@kwdef mutable struct TerminalOutputState
    progress::Bool = false
    last_progress::Float64 = -Inf
    cursor_visible::Bool = false
    cursor::Union{Nothing,Tuple{Int,Int}} = nothing
    closed::Bool = false
end

"""Emit actual indeterminate progress, including the original one-second keepalive contract."""
function terminal_progress!(state::TerminalOutputState, io::IO, active::Bool; now::Real=time_ns()/1e9, force::Bool=false)
    if !state.closed
        if active
            if force || !state.progress || now-state.last_progress >= 1
                print(io,"\e]9;4;3\a")
                state.last_progress=Float64(now)
            end
        elseif state.progress || force
            print(io,"\e]9;4;0\a")
        end
        state.progress=active
    end
    nothing
end

"""Position a real composed cursor for IME even when hidden; visibility remains a separate preference."""
function terminal_cursor!(state::TerminalOutputState,io::IO,enabled::Bool,cursor::Union{Nothing,Tuple{Int,Int}};width::Integer,height::Integer)
    if !state.closed
        positioned=!isnothing(cursor) && 1<=cursor[1]<=width && 1<=cursor[2]<=height
        visible=enabled && positioned
        if positioned
            x,y=cursor::Tuple{Int,Int}
            print(io,"\e[",y,";",x,"H",visible ? "\e[?25h" : "\e[?25l")
        elseif state.cursor_visible
            print(io,"\e[?25l")
        end
        state.cursor_visible=visible
    end
    nothing
end

"""Release only owned terminal indicators when the frontend is closed."""
function terminal_output_close!(state::TerminalOutputState,io::IO)
    if !state.closed
        terminal_progress!(state,io,false)
        state.cursor_visible && print(io,"\e[?25h")
        state.cursor=nothing
        state.closed=true
        flush(io)
    end
    nothing
end
