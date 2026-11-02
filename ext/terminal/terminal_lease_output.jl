"""Borrow a pre-flushed unbuffered terminal stream and reject every incomplete native write."""
struct CheckedTerminalOutput <: IO
    source::IOStream
end
Base.isopen(io::CheckedTerminalOutput)=isopen(io.source)
Base.close(::CheckedTerminalOutput)=nothing
Base.flush(io::CheckedTerminalOutput)=flush(io.source)
Base._fd(io::CheckedTerminalOutput)=Base._fd(io.source)
function Base.unsafe_write(io::CheckedTerminalOutput,pointer::Ptr{UInt8},count::UInt)
    written=Base.unsafe_write(io.source,pointer,count)
    written==count || error("Incomplete terminal output write")
    written
end
Base.write(io::CheckedTerminalOutput,text::String)=GC.@preserve text Base.unsafe_write(io,pointer(text),UInt(ncodeunits(text)))
Base.write(io::CheckedTerminalOutput,bytes::Vector{UInt8})=GC.@preserve bytes Base.unsafe_write(io,pointer(bytes),UInt(length(bytes)))
Base.write(io::CheckedTerminalOutput,byte::UInt8)=write(io,UInt8[byte])

"""Gate the internal ios buffering contract to the exact runtime whose empty-buffer close was reviewed."""
terminal_lease_runtime_verified()=VERSION==v"1.13.3" && Base.GIT_VERSION_INFO.commit=="67ac47b9cd855e02134d41d5428ac9f2a73f2694"
terminal_lease_identity_matches(state,identity)=state.ok && state.foreground && state.parent==identity.parent &&
    state.group==identity.group && state.session==identity.session

"""Establish silent owned closure before granting a lease, never after foreground ownership is lost."""
function terminal_lease_output!(app::App,adapter,identity)
    terminal=app.settings.terminal
    output=terminal_presentation_sink(app)
    if app.settings.presentation.leased || app.settings.presentation.closed
        (ok=false,reason="The terminal presentation already has an owner or is closed")
    elseif output isa CheckedTerminalOutput
        checked=preference_attempt(()->JuliaForever2.TerminalJobs.self_terminal_state(adapter,identity.input_fd,identity.output_fd))
        valid=checked.ok && terminal_lease_identity_matches(checked.value,identity)
        (ok=valid,reason=valid ? "" : "Terminal ownership changed before the repeated lease")
    elseif !(output isa IOStream) || !terminal_lease_runtime_verified() || !(terminal.io isa PresentationIO)
        (ok=false,reason="Unbuffered terminal leases are not verified for this output or Julia runtime")
    else
        attempt=preference_attempt() do
            checked=CheckedTerminalOutput(output)
            wrapped=PresentationIO(checked,app.settings.presentation)
            lock(output.lock) do
                state=JuliaForever2.TerminalJobs.self_terminal_state(adapter,identity.input_fd,identity.output_fd)
                terminal_lease_identity_matches(state,identity) || error("Terminal ownership changed before lease preparation")
                flush(output)
                # ios.h at the verified runtime defines bm_none=1000; it does not flush prior dirty bytes.
                code=ccall(:ios_bufmode,Cint,(Ptr{Cvoid},Cint),output,1000)
                code==0 || error("Unbuffered terminal output could not be established")
                terminal.io=wrapped
            end
        end
        (ok=attempt.ok,reason=attempt.ok ? "" : attempt.reason)
    end
end

"""Stop only the retained input source, without draining or closing a caller-owned stream."""
terminal_lease_stop_input!(::Nothing)=nothing
terminal_lease_stop_input!(::IO)=nothing
terminal_lease_stop_input!(source::Base.LibuvStream)=Base.stop_reading(source)

"""Restore local cooked mode only after fresh matching foreground identity, without emitting output."""
terminal_lease_cooked!(::Nothing,identity)=nothing
terminal_lease_cooked!(::JuliaForever2.TerminalJobs.TerminalJobAdapter,::Nothing)=nothing
function terminal_lease_cooked!(adapter::JuliaForever2.TerminalJobs.TerminalJobAdapter,identity)
    source=identity.mode_source
    if source isa Base.TTY && isopen(source)
        fd=Base.cconvert(Cint,Base._fd(source))
        state=JuliaForever2.TerminalJobs.self_terminal_state(adapter,fd,fd)
        if terminal_lease_identity_matches(state,identity)
            code=ccall(:uv_tty_set_mode,Cint,(Ptr{Cvoid},Cint),source.handle,0)
            code==0 || error("Owned terminal cooked-mode restoration failed")
        end
    end
    nothing
end
terminal_lease_cooked!(::Nothing,::Nothing)=nothing

"""Abandon an already-unbuffered lease before any fallible cleanup or final framework frame."""
function abandon_terminal_lease!(app::App,terminal::Tachikoma.Terminal,reason::AbstractString;adapter=nothing,identity=nothing)
    app.operations.closing[]=true
    app.quit=true
    state=app.settings.presentation
    state.closed=true;state.leased=true
    app.status=String(reason)
    Tachikoma.INPUT_ACTIVE[]=false
    terminal.io=devnull
    terminal.external_size=true
    terminal.remote_tty_path=nothing
    app.settings.terminal=nothing
    source=isnothing(identity) ? nothing : identity.input_source
    preference_attempt(()->terminal_lease_stop_input!(source))
    preference_attempt(()->terminal_lease_cooked!(adapter,identity))
    lock(app.operations.event_lock) do
        empty!(app.queue.channel)
    end
    input=app.settings.theme_input
    if !isnothing(input)
        preference_attempt(()->theme_input_abandon!(input))
        app.settings.theme_input=nothing
    end
    for action in (close_terminal_viewport!,close_chat_completion!,close_terminal_output!,close_session_selectors!)
        preference_attempt(()->action(app))
    end
    nothing
end
terminal_lease_failed(app::App)=app.settings.presentation.closed && app.settings.presentation.leased
