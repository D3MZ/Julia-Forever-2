"""Read protocol mode from the actual attached terminal, not from a guessed keyboard layout."""
native_keybinding_kitty(app::App)=!isnothing(app.settings.terminal) && app.settings.terminal.kitty_keyboard
native_keybinding_matches(app::App,action::AbstractString,packet::AbstractString)=native_keybinding_matches(app.menus.keybindings,action,packet;kitty=native_keybinding_kitty(app))

"""Refresh displayed startup help from the same effective app-action registry used for dispatch."""
function native_keybinding_refresh_help!(app::App)
    app.transcript.display.expand_key=native_keybinding_text(app,"app.tools.expand")
    controls=app.menus.startup
    if !isnothing(controls)
        controls.document.bindings=startup_host_bindings(app)
    end
    app.transcript.display_key=nothing
    nothing
end

"""Load private bindings without writes or grants; a failed reload leaves the last valid map intact."""
function load_native_keybindings!(app::App;announce::Bool=false)
    state=app.menus.keybindings
    isempty(state.effective) && native_keybinding_install!(state,native_keybinding_plan(state,Dict{String,Vector{String}}()))
    path=joinpath(app.settings.directory,"keybindings.json")
    attempt=native_keybinding_prepare(state,path)
    if attempt.ok
        native_keybinding_install!(state,attempt.value)
        state.path=path
        native_keybinding_refresh_help!(app)
        if !isempty(state.conflicts)
            pairs=[first(pair)*": "*join(last(pair),", ") for pair in state.conflicts]
            frontend_notice!(app,"Keybinding conflicts (focused handler order wins): "*join(pairs,"; ");kind=:warning)
        end
        announce && (app.status="Native chat keybindings reloaded")
    else
        state.error=attempt.reason
        app.status=attempt.reason
        frontend_notice!(app,attempt.reason;kind=:warning)
    end
    (ok=attempt.ok,reason=attempt.ok ? "" : attempt.reason)
end

"""Reload only implemented native resources, and never while an owned operation is active."""
function native_reload_command!(app::App)
    if app.busy || app.operations.closing[] || !isnothing(app.operations.shell.active)
        app.status="Wait for the active response, compaction or shell operation to finish before reloading."
    else
        outcome=load_native_keybindings!(app)
        if outcome.ok
            refreshed=preference_attempt() do
                refresh_settings!(app)
                discover_disk_resources!(app)
            end
            app.status=refreshed.ok ? "Reloaded native chat keybindings, skills, prompts and provider settings. Extension and context-file reload is not available in this build." : "Keybindings reloaded; resource refresh failed: "*refreshed.reason
            refreshed.ok || frontend_notice!(app,app.status;kind=:warning)
        end
    end
    nothing
end

"""Run only existing native owners; configuration cannot supply code, destinations or provider credentials."""
function native_chat_keybinding_action!(app::App,action::String)
    if action=="app.interrupt"
        chat_editor_escape!(app,chat_editor_state!(app))
    elseif action=="app.clear"
        chat_host_interrupt!(app)
    elseif action=="app.exit"
        quit_command!(app,"")
    elseif action=="app.thinking.cycle"
        cycle_terminal_thinking!(app)
    elseif action=="app.model.cycleForward" || action=="app.model.cycleBackward"
        cycle_terminal_model!(app,action=="app.model.cycleForward" ? 1 : -1)
    elseif action=="app.model.select"
        open_menu!(app,"model")
    elseif action=="app.tools.expand"
        display=app.transcript.display
        session_display_transition!(display,display.expand_all ? :collapse_all : :expand_all)
        user_shell_expand!(app,display.expand_all)
        controls=app.menus.startup
        isnothing(controls) || startup_set_expanded!(controls.document,display.expand_all;on_notice=message->frontend_notice!(app,message))
    elseif action=="app.thinking.toggle"
        toggle_thinking_visibility!(app)
    elseif action=="app.editor.external"
        external_editor_command!(app)
    elseif action=="app.message.copy"
        terminal_viewport_copy!(app) || copy_last_assistant!(app)
    elseif action=="app.message.followUp"
        chat_host_follow_up!(app)
    elseif action=="app.message.dequeue"
        restore_pending_input!(app)
    elseif action=="app.session.new"
        session_action!(app,:new)
    elseif action=="app.session.tree"
        open_menu!(app,"tree")
    elseif action=="app.session.fork"
        open_menu!(app,"fork")
    elseif action=="app.session.resume"
        session_action!(app,:list)
    end
    nothing
end

"""Resolve only chat app actions in pinned handler order, retaining autocomplete and nonempty-editor ownership."""
function native_chat_keybinding!(app::App,packet::AbstractString)
    handled=false
    completion_page=chat_host_completion_open(app) && menu_select_navigation(packet) in (:page_up,:page_down)
    if app.page==:chat && !completion_page && !chat_host_pasting(app,packet) && !occursin(r":3[u~ABCDHFPQS]$",packet)
        order=vcat(["app.interrupt","app.exit"],[item.id for item in app.menus.keybindings.definitions if item.id ∉ ("app.interrupt","app.exit")])
        for action in order
            eligible=action=="app.interrupt" ? !chat_host_completion_open(app) : action=="app.exit" ? isempty(chat_text(chat_editor_state!(app))) : true
            if eligible && native_keybinding_matches(app,action,packet)
                native_chat_keybinding_action!(app,action)
                handled=true
                break
            elseif action=="app.interrupt" && native_keybinding_matches(app,action,packet)
                # The original passes an interrupt matching an open completion to that editor,
                # rather than falling through to a conflicting later app action.
                break
            end
        end
    end
    handled
end

"""Return actual configured app key names; empty arrays remain visibly unbound, not unavailable."""
function native_app_keybinding_labels(app::App)
    Dict(definition.id=>join(native_keybinding_keys(app.menus.keybindings,definition.id),"/") for definition in app.menus.keybindings.definitions)
end

"""Keep a fragmented CSI paste opener with the chat editor, never promote its contents to app actions."""
function native_chat_paste_prefix!(app::App,packet::AbstractString;escape_key::Bool=false)
    state=app.menus.keybindings
    marker="\e[200~"
    handled=false
    if app.page==:chat && !terminal_search_host_focused(app)
        if !isempty(state.paste_prefix)
            combined=state.paste_prefix*String(packet)
            state.paste_prefix=""
            if startswith(marker,combined) && combined!=marker
                state.paste_prefix=combined
            elseif startswith(combined,marker)
                chat_host_packet!(app,combined)
            else
                # Ambiguous bytes are inserted as sanitized paste data, never decoded as keys.
                chat_paste!(chat_editor_state!(app),combined)
                chat_completion_ready!(app,nothing)
            end
            handled=true
        elseif 1<=ncodeunits(packet)<ncodeunits(marker) && startswith(marker,packet) && (packet!="\e" || !escape_key)
            state.paste_prefix=String(packet)
            handled=true
        end
    else
        state.paste_prefix=""
    end
    handled
end

"""Format a real chat action binding for native menus without changing their fixed selector controls."""
native_keybinding_hint(app::App,id::AbstractString)=command_key_label(join(native_keybinding_keys(app.menus.keybindings,id),"/"))

"""Preserve source lower-case hint spelling and macOS Option naming for actual configured keys."""
native_keybinding_text(app::App,id::AbstractString)=command_key_label(join(native_keybinding_keys(app.menus.keybindings,id),"/");capitalize=false)
