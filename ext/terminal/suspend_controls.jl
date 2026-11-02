"""Observe self-only job control without borrowing a remote or caller-selected terminal."""
function terminal_self_suspend_identity(app::App,adapter::JuliaForever2.TerminalJobs.TerminalJobAdapter)
    terminal=app.settings.terminal
    input=external_editor_input_source(Tachikoma._input_io())
    output=terminal_presentation_sink(app)
    if !Sys.islinux() || isnothing(terminal) || Tachikoma._is_remote_terminal(terminal) || !(input isa Base.TTY) || !local_terminal_stream(output)
        (ok=false,reason="Self suspension requires an attached local Linux job-control terminal",identity=nothing)
    else
        observed=preference_attempt() do
            input_fd=Base.cconvert(Cint,Base._fd(input));output_fd=Base.cconvert(Cint,Base._fd(output))
            state=JuliaForever2.TerminalJobs.self_terminal_state(adapter,input_fd,output_fd)
            (;state...,input_fd,output_fd,input_source=input,mode_source=stdin)
        end
        state=observed.value
        if !observed.ok
            (ok=false,reason=observed.reason,identity=nothing)
        elseif !state.ok || !state.foreground
            (ok=false,reason=state.ok ? "Self suspension requires this job to be in the foreground" : state.reason,identity=nothing)
        else
            (ok=true,reason="",identity=state)
        end
    end
end

"""Wait for a background-continued job's real foreground return, without taking terminal ownership."""
function terminal_self_suspend_foreground(adapter,identity,closing)
    current=JuliaForever2.TerminalJobs.self_terminal_state(adapter,identity.input_fd,identity.output_fd)
    same=state->state.ok && state.parent==identity.parent && state.group==identity.group && state.session==identity.session
    while same(current) && !current.foreground && !closing()
        sleep(0.05)
        current=JuliaForever2.TerminalJobs.self_terminal_state(adapter,identity.input_fd,identity.output_fd)
    end
    !closing() && same(current) && current.foreground ? (ok=true,reason="") :
        (ok=false,reason="Self suspension lost its parent, session, or controlling terminal; no foreground takeover attempted")
end

"""Acquire a screen lease under supervision and recover only a lease this request acquired."""
function terminal_self_suspend_acquire!(app::App)
    state=app.settings.presentation
    previous=state.leased
    attempt=preference_attempt(()->terminal_presentation_pause!(app))
    if attempt.ok
        attempt.value
    else
        recovered=preference_attempt() do
            if !previous && state.leased && !state.closed
                terminal_viewport_tracking!(app;force=true)
                terminal=app.settings.terminal::Tachikoma.Terminal
                terminal.frame_count=0
                foreach(Tachikoma.reset!,terminal.buffers)
                state.leased=false
            end
        end
        detail=recovered.ok ? "" : "; lease retained: "*recovered.reason
        (ok=false,reason="Self suspension could not acquire terminal: "*attempt.reason*detail)
    end
end

"""Relinquish UI ownership, request self-only suspension, and restore only a still-owned foreground TTY."""
function terminal_self_suspend_leased!(app::App,adapter,identity)
    terminal=app.settings.terminal::Tachikoma.Terminal
    session=app.session
    resume_input=app.settings.theme_input
    prepared=terminal_lease_output!(app,adapter,identity)
    paused=prepared.ok ? terminal_self_suspend_acquire!(app) : prepared
    if !paused.ok
        prepared.ok && app.settings.presentation.leased && abandon_terminal_lease!(app,terminal,paused.reason;adapter,identity)
        (ok=false,reason=paused.reason,requested=false)
    else
        performed=preference_attempt() do
            close_terminal_theme!(app)
            Tachikoma.leave_tui!(terminal)
            lock(session.conversation.lock) do
                idle=!app.operations.closing[] && app.session===session && !session.runtime.closed && all(istaskdone,session.runtime.handles)
                idle || error("Self suspension requires an idle unchanged session")
                JuliaForever2.TerminalJobs.suspend_self_terminal!(adapter,identity.input_fd,identity.output_fd,identity)
            end
        end
        foreground=preference_attempt(()->terminal_self_suspend_foreground(adapter,identity,()->app.operations.closing[]))
        can_restore=foreground.ok && foreground.value.ok
        restored=can_restore ? restore_external_editor_terminal!(app,terminal;resume_input) :
            (ok=false,reason=foreground.ok ? foreground.value.reason : foreground.reason)
        requested=performed.ok && performed.value.requested
        if !restored.ok
            abandon_terminal_lease!(app,terminal,restored.reason;adapter,identity)
            (ok=false,reason=restored.reason,requested)
        elseif !performed.ok || !performed.value.ok
            (ok=false,reason=performed.ok ? performed.value.reason : performed.reason,requested)
        else
            (ok=true,reason="",requested)
        end
    end
end

"""Suspend only this application, never sibling pipeline jobs or active native child processes."""
function terminal_self_suspend!(app::App;adapter=JuliaForever2.TerminalJobs.TerminalJobAdapter())
    editor=chat_editor_state!(app)
    active=!isnothing(app.operations.active) || app.operations.pending_continuation || !isempty(app.operations.pending_start_ids)
    viewport=app.menus.viewport
    overlay=app.page!=:chat || app.menu || !isnothing(viewport) && viewport.search.active
    result=if app.operations.closing[] || app.settings.presentation.leased || app.settings.presentation.closed || app.busy || active || overlay || editor.pasting || !isnothing(app.operations.shell.active) || !isnothing(app.settings.auth_task)
        (ok=false,reason="Self suspension is unavailable during active work, paste, overlays, authentication, shell jobs, or shutdown",requested=false)
    else
        observed=terminal_self_suspend_identity(app,adapter)
        observed.ok ? terminal_self_suspend_leased!(app,adapter,observed.identity) :
            (ok=false,reason=observed.reason,requested=false)
    end
    result.ok || (app.status=result.reason)
    result
end
