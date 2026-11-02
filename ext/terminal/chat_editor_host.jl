"""Retain one native editor around the existing public TextInput identity."""
function chat_editor_state!(app::App)
    state=app.menus.chat_editor
    if isnothing(state) || state.input!==app.input
        state=ChatEditorState(app.input)
        app.menus.chat_editor=state
    end
    state.focused=app.page==:chat
    state
end

"""Keep completion work bound to the actual editor, cached workspace and terminal event queue."""
function chat_completion_state!(app::App)
    editor=chat_editor_state!(app)
    state=app.menus.chat_completion
    if isnothing(state) || state.editor!==editor || state.provider.directory!=app.settings.workspace || state.closed
        isnothing(state) || chat_completion_close!(state)
        wake=()->enqueue_event!(app,TaskEvent(:completion_ready,nothing))
        state=ChatCompletionState(editor,chat_completion_provider(app);on_change=wake,
            max_visible=terminal_integer(app,"autocomplete-max-visible",5,3,20))
        app.menus.chat_completion=state
    end
    maximum=terminal_integer(app,"autocomplete-max-visible",5,3,20)
    state.max_visible==maximum || chat_completion_set_visible!(state,maximum)
    state
end

function chat_completion_ready!(app::App,value)
    state=app.menus.chat_completion
    if !isnothing(state) && !state.closed && !app.operations.closing[]
        app.menu=app.page==:chat && state.mode!=:none
        app.selected=state.selected
        reason=state.error
        isnothing(reason) || (app.status="Completion failed: "*reason)
    end
    nothing
end

chat_host_completion_open(app::App)=!isnothing(app.menus.chat_completion) && app.menus.chat_completion.mode!=:none

"""Cancel and detach native completion work during terminal teardown."""
function close_chat_completion!(app::App)
    state=app.menus.chat_completion
    isnothing(state) || chat_completion_close!(state)
    app.menus.chat_completion=nothing
    nothing
end

"""Apply the original two-stage interrupt to the real editor and shutdown owner."""
function chat_host_interrupt!(app::App; now_ms::Integer=floor(Int,time()*1000))
    editor=chat_editor_state!(app)
    if now_ms-app.menus.last_sigint_ms<500
        quit_command!(app,"")
    else
        chat_completion_set_text!(chat_completion_state!(app),"")
        app.menu=false
        app.menus.last_sigint_ms=Int(now_ms)
    end
    nothing
end

chat_command_accepted(result) = true
chat_command_accepted(result::NamedTuple) = hasproperty(result,:ok) ? result.ok===true : true

"""Submit expanded editor text only to a real command or durable provider/queue operation."""
function chat_host_submit!(app::App,editor::ChatEditorState,text::AbstractString;kind::Symbol=:steering)
    value=String(strip(text))
    if isempty(value) || app.operations.closing[] || !isopen(app.session)
        (ok=false,reason="Input is empty or session is closed")
    else
        snapshot=chat_snapshot(editor)
        shell=raw_user_shell(value)
        accepted=if !isnothing(shell) && (kind==:steering || !app.busy)
            start_user_shell!(app,shell).ok
        elseif startswith(value,"/") && (kind==:steering || !app.busy || pending_extension_command(app,value))
            command=prompt_command_parts(value)
            available=isnothing(command) ? nothing : command_dispatch_index(discover_commands(app),command.name)
            if isnothing(available)
                app.status="Unknown command: "*value
                false
            else
                result=submit!(app,value)
                chat_command_accepted(result)
            end
        else
            expanded=expand_registered_resources(app,value)
            if expanded.ok
                submit_literal_input!(app,expanded.text;kind).ok
            else
                app.status=expanded.reason
                false
            end
        end
        if accepted
            chat_add_history!(editor,value)
            chat_accept!(editor)
            app.menu=false
        else
            chat_write!(editor,snapshot.text,snapshot.cursor)
            editor.pastes=copy(snapshot.pastes)
            editor.paste_counter=snapshot.paste_counter
        end
        (ok=accepted,reason=accepted ? "" : app.status)
    end
end

"""Consume an actual packet once, then dispatch only the native editor's requested owner action."""
function chat_host_packet!(app::App,packet::AbstractString)
    editor=chat_editor_state!(app)
    before=chat_text(editor)
    state=chat_completion_state!(app)
    result=if external_editor_packet(packet) && !editor.pasting
        external_editor_command!(app)
        (action=:handled,text="")
    else
        chat_completion_input!(state,packet)
    end
    if result.action==:submit
        chat_host_submit!(app,editor,result.text)
    elseif result.action==:interrupt
        chat_editor_escape!(app,editor)
    elseif result.action==:exit
        quit_command!(app,"")
    elseif result.action==:copy
        chat_host_interrupt!(app)
    end
    chat_completion_ready!(app,nothing)
    nothing
end

"""Give fragmented paste priority over every application shortcut."""
function chat_host_pasting(app::App,packet::AbstractString)
    editor=chat_editor_state!(app)
    editor.pasting || occursin("\e[200~",packet)
end

"""Expand pending paste tokens before Alt+Enter's actual follow-up queue submission."""
function chat_host_follow_up!(app::App)
    editor=chat_editor_state!(app)
    chat_sync!(editor)
    chat_host_submit!(app,editor,chat_expanded_text(editor);kind=:follow_up)
end
