"""Report the selected runtime backend even before a real terminal is attached."""
terminal_presentation_mode(app::App)=app.settings.presentation.mode

"""Retain the caller's real output handle and attach after the framework finishes terminal setup."""
function initialize_terminal_presentation!(app::App,terminal::Tachikoma.Terminal)
    state=app.settings.presentation
    desired=state.mode
    state.mode=:fullscreen
    state.width=terminal.size.width;state.height=terminal.size.height
    state.attached=true;state.closed=false
    state.before_exit=()->terminal_presentation_exit_rows!(app)
    state.on_exit=io->terminal_presentation_resume_hint!(app,io)
    output=PresentationIO(terminal.io,state)
    terminal.io=output
    presentation_switch!(output,desired)
    nothing
end

"""Keep the terminal mode a real transactional setting, including owned mode-change notices."""
function apply_setting_effect!(app::App,::Val{Symbol("tui-mode")},value::AbstractString)
    state=app.settings.presentation
    mode=Symbol(value)
    terminal=app.settings.terminal
    result=if isnothing(terminal)
        state.mode=mode
        (ok=mode in (:regular,:fullscreen),reason=mode in (:regular,:fullscreen) ? "" : "Unknown terminal presentation mode")
    elseif terminal.io isa PresentationIO
        presentation_switch!(terminal.io,mode)
    else
        (ok=false,reason="Terminal presentation backend is not attached")
    end
    if result.ok && !isnothing(terminal)
        terminal.frame_count=0
        foreach(Tachikoma.reset!,terminal.buffers)
    end
    result
end

function apply_setting_effect!(app::App,::Val{Symbol("clear-on-shrink")},value::AbstractString)
    app.settings.presentation.clear_on_shrink=value=="true"
    nothing
end
function apply_setting_effect!(app::App,::Val{Symbol("fullscreen-exit-output")},value::AbstractString)
    app.settings.presentation.exit_output=Symbol(value)
    nothing
end

"""Share an explicit terminal lease with native external-editor and suspension services."""
function terminal_presentation_pause!(app::App)
    terminal=app.settings.terminal
    if !isnothing(terminal) && terminal.io isa PresentationIO
        presentation_pause!(terminal.io)
    else
        (ok=false,reason="Terminal presentation backend is not attached")
    end
end

function terminal_presentation_resume!(app::App)
    terminal=app.settings.terminal
    result=if !isnothing(terminal) && terminal.io isa PresentationIO
        presentation_resume!(terminal.io)
    else
        (ok=false,reason="Terminal presentation backend is not attached")
    end
    if result.ok && !isnothing(terminal)
        terminal.frame_count=0
        foreach(Tachikoma.reset!,terminal.buffers)
    end
    result
end

"""Use only a genuinely retained native session in the shutdown hint; never advertise nonexistent CLI flags."""
function terminal_presentation_resume_hint!(app::App,io::IO)
    timeline=app.archive.timeline
    if !isnothing(timeline)
        path=timeline.path
        if !isnothing(path) && isfile(path)
            print(io,"\e[2mTo resume this session:\e[22m run jf2 and use /resume to select ",startup_safe_text(timeline.identity.id),"\n")
        end
    end
    nothing
end

"""Return the same real terminal IO for an authorized child process without transferring ownership."""
function terminal_presentation_sink(app::App)
    terminal=app.settings.terminal
    isnothing(terminal) ? nothing : terminal.io isa PresentationIO ? terminal.io.sink : terminal.io
end

"""Publish a success notice only after persistence and its runtime effect have both committed."""
setting_committed_notice!(app::App,::Val,value::AbstractString)=nothing
function setting_committed_notice!(app::App,::Val{Symbol("tui-mode")},value::AbstractString)
    frontend_notice!(app,string("TUI mode: ",value))
end
