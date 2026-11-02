public TerminalPresentation, PresentationIO, presentation_switch!, presentation_pause!, presentation_resume!

"""Own the real screen backend independently of terminal input and provider activity."""
Base.@kwdef mutable struct TerminalPresentation
    mode::Symbol = :fullscreen
    regular::RegularTerminalState = RegularTerminalState()
    lines::Vector{Vector{Tachikoma.Span}} = Vector{Tachikoma.Span}[]
    cursor::Union{Nothing,Tuple{Int,Int}} = nothing
    width::Int = 0
    height::Int = 0
    clear_on_shrink::Bool = false
    hardware_cursor::Bool = false
    exit_output::Symbol = :transcript
    leased::Bool = false
    closed::Bool = false
    attached::Bool = false
    consistent::Bool = true
    before_exit::Function = Returns(nothing)
    on_exit::Function = Returns(nothing)
end

"""Adapt only this application's output sink; never replace framework methods or own the underlying IO."""
struct PresentationIO <: IO
    sink::IO
    state::TerminalPresentation
end
Base.isopen(io::PresentationIO)=isopen(io.sink)
Base.flush(io::PresentationIO)=io.state.closed ? nothing : flush(io.sink)
Base.displaysize(io::PresentationIO)=(io.state.height,io.state.width)
Base.close(::PresentationIO)=nothing

"""Never hide a short terminal control write as a successful complete transition."""
function presentation_checked_write(io::IO,text::String)
    written=write(io,text)
    written==ncodeunits(text) || error("Incomplete terminal control write")
    written
end

function presentation_frame!(io::PresentationIO)
    state=io.state
    regular_present!(state.regular,io.sink,state.lines,state.width,state.height;
        cursor=state.cursor,hardware_cursor=state.hardware_cursor,clear_on_shrink=state.clear_on_shrink)
    nothing
end

"""Consume complete framework frames in regular mode while forwarding independent native terminal controls."""
function presentation_write(io::PresentationIO,text::String)
    state=io.state
    isframe=startswith(text,"\e[?2026h") && endswith(text,"\e[?2026l")
    if state.closed
        nothing
    elseif isframe
        if !state.leased && !state.closed && state.consistent
            state.mode==:regular ? presentation_frame!(io) : presentation_checked_write(io.sink,fullscreen_grapheme_frame(text;width=state.width,height=state.height).text)
        end
    else
        # A second DECRST 1049 restores an obsolete saved cursor even on the main screen.
        forwarded=state.attached && state.mode==:regular ? replace(text,"\e[?1049l"=>"") : text
        presentation_checked_write(io.sink,forwarded)
        if occursin("\e[?1049l",text) && state.attached && !state.leased && !state.closed
            state.before_exit()
            state.closed=true
            if state.mode==:regular
                regular_finish!(state.regular,io.sink)
            elseif state.exit_output==:transcript
                presentation_frame!(io)
                regular_finish!(state.regular,io.sink)
            end
            state.on_exit(io.sink)
        end
    end
    ncodeunits(text)
end
Base.write(io::PresentationIO,text::String)=presentation_write(io,text)
Base.write(io::PresentationIO,data::Vector{UInt8})=presentation_write(io,String(copy(data)))
Base.write(io::PresentationIO,byte::UInt8)=io.state.closed ? 1 : write(io.sink,byte)
function Base.unsafe_write(io::PresentationIO,pointer::Ptr{UInt8},count::UInt)
    presentation_write(io,String(copy(unsafe_wrap(Vector{UInt8},pointer,Int(count)))))
end

"""Switch actual screen modes without losing the preserved main-screen render state."""
function presentation_switch!(io::PresentationIO,mode::Symbol;overlay::Bool=false)
    state=io.state
    if !(mode in (:regular,:fullscreen))
        (ok=false,reason="Unknown terminal presentation mode")
    elseif state.leased || state.closed
        (ok=false,reason="The terminal is owned by an external process or is closed")
    elseif overlay && mode!=state.mode
        (ok=false,reason="Close active overlays before changing TUI mode")
    else
        if mode!=state.mode || !state.consistent
            state.consistent=false
            state.mode=mode
            if mode==:regular
                print(io.sink,"\e[?1049l",Tachikoma.MOUSE_OFF)
            else
                print(io.sink,"\e[?1049h",Tachikoma.MOUSE_ON)
            end
            flush(io.sink)
            state.consistent=true
        end
        (ok=true,reason="")
    end
end

"""Mark a terminal lease before the framework disables modes; frames and final-output hooks stay paused."""
function presentation_pause!(io::PresentationIO)
    state=io.state
    accepted=!state.closed && !state.leased
    accepted && (state.leased=true)
    (ok=accepted,reason=accepted ? "" : "Terminal lease is unavailable")
end

"""Restore the saved backend after framework setup, then force a valid repaint of externally changed content."""
function presentation_resume!(io::PresentationIO;release::Bool=true)
    state=io.state
    accepted=!state.closed && state.leased
    if accepted
        if state.mode==:regular
            print(io.sink,"\e[?1049l",Tachikoma.MOUSE_OFF)
            regular_invalidate!(state.regular)
        end
        flush(io.sink)
        release && (state.leased=false)
    end
    (ok=accepted,reason=accepted ? "" : "No active terminal lease")
end
