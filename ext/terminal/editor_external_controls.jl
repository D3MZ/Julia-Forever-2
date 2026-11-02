external_editor_input_source(input::IO)=input
external_editor_input_source(input::ThemeTerminalInput)=external_editor_input_source(input.source)

"""Accept only concrete locally owned terminal streams, including the framework's /dev/tty IOStream."""
local_terminal_stream(::IO)=false
local_terminal_stream(io::CheckedTerminalOutput)=local_terminal_stream(io.source)
local_terminal_stream(io::Union{Base.TTY,IOStream})=Sys.isunix() && isopen(io) && ccall(:isatty,Cint,(Cint,),Base.cconvert(Cint,Base._fd(io)))==1

"""Restore the same terminal and its single-reader theme adapter after a real external-process lease."""
function restore_external_editor_terminal!(app::App,terminal::Tachikoma.Terminal;resume_input=nothing)
    state=app.settings.presentation
    state.leased=true
    entered=preference_attempt() do
        Tachikoma.enter_tui!(terminal)
        Tachikoma.check_resize!(terminal)
        initialize_terminal_theme!(app,terminal;resume_input)
        isnothing(app.settings.theme_input) && error("Terminal input restore failed: "*app.status)
        resumed=terminal_presentation_resume!(app;release=false)
        resumed.ok || error(resumed.reason)
    end
    if entered.ok && !state.closed
        state.leased=false
        (ok=true,reason="")
    else
        state.leased=true
        detail=entered.ok ? "Terminal closed while restoring" : entered.reason
        (ok=false,reason="Terminal restoration failed; lease retained: "*detail)
    end
end

"""Run an explicitly selected editor while the UI owner, input adapter and renderer relinquish the same TTY."""
function external_editor_leased!(app::App,terminal::Tachikoma.Terminal,command::String,content::String,owner::ExternalEditorProcess)
    resume_input=app.settings.theme_input
    observed=terminal_self_suspend_identity(app,JuliaForever2.TerminalJobs.TerminalJobAdapter())
    prepared=observed.ok ? terminal_lease_output!(app,JuliaForever2.TerminalJobs.TerminalJobAdapter(),observed.identity) : observed
    paused=prepared.ok ? terminal_self_suspend_acquire!(app) : prepared
    if !paused.ok
        prepared.ok && app.settings.presentation.leased && abandon_terminal_lease!(app,terminal,paused.reason;
            adapter=JuliaForever2.TerminalJobs.TerminalJobAdapter(),identity=observed.identity)
        external_editor_failure(paused.reason)
    else
        performed=preference_attempt() do
            close_terminal_theme!(app)
            input=Tachikoma._input_io()
            output=terminal_presentation_sink(app)
            input isa Base.TTY && output isa IO || error("External editor requires the attached local terminal")
            Tachikoma.leave_tui!(terminal)
            print(output,"Launching external editor: ",startup_safe_text(command),"\nJuliaForever2 will resume when the editor exits.\n")
            flush(output)
            edit_external_text(command,content;directory=app.settings.workspace,owner,input,output,errors=output,
                job_adapter=JuliaForever2.TerminalJobs.TerminalJobAdapter())
        end
        process=owner.process
        foreground_ready=!(process isa JuliaForever2.TerminalJobs.TerminalJob) || process.restored
        restored=foreground_ready ? restore_external_editor_terminal!(app,terminal;resume_input) : (ok=false,reason="Terminal foreground was not restored; native job ownership retained")
        if !restored.ok
            abandon_terminal_lease!(app,terminal,restored.reason;
                adapter=JuliaForever2.TerminalJobs.TerminalJobAdapter(),identity=observed.identity)
            external_editor_failure(restored.reason)
        elseif !performed.ok
            external_editor_failure(performed.reason)
        else
            performed.value
        end
    end
end

"""Replace the actual draft only after successful child exit, terminal restoration and unchanged draft ownership."""
function external_editor_command!(app::App;command::AbstractString=external_editor_command(menu_preference(app,"external-editor","")),owner::ExternalEditorProcess=ExternalEditorProcess())
    terminal=app.settings.terminal
    if app.operations.closing[] || app.page!=:chat || app.settings.presentation.leased || app.settings.presentation.closed
        (ok=false,reason="External editor is unavailable while closing or outside chat")
    elseif isnothing(terminal) || Tachikoma._is_remote_terminal(terminal) || !(external_editor_input_source(Tachikoma._input_io()) isa Base.TTY) || !local_terminal_stream(terminal_presentation_sink(app))
        app.status="External editor requires an attached local terminal"
        (ok=false,reason=app.status)
    else
        editor=chat_editor_state!(app);state=chat_completion_state!(app)
        snapshot=chat_completion_context(editor);previous_status=app.status
        content=chat_expanded_text(editor)
        result=external_editor_leased!(app,terminal,String(command),content,owner)
        if result.ok && app.menus.chat_editor===editor && chat_completion_context(editor)==snapshot && !app.operations.closing[]
            chat_completion_set_text!(state,result.content)
            app.menu=false
            app.status=previous_status
            (ok=true,reason="")
        elseif result.ok
            app.status="Draft changed while the external editor was open; existing draft preserved"
            (ok=false,reason=app.status)
        else
            app.status=result.reason
            (ok=false,reason=result.reason)
        end
    end
end

"""Recognize only the original Ctrl+G binding, including negotiated terminal encodings."""
external_editor_packet(packet::AbstractString)=packet in ("\a","\e[103;5u","\e[71;5u","\e[27;5;103~","\e[27;5;71~")
