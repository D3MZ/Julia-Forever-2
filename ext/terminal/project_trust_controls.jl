"""Detect only native project resources; detection never reads their content or executes extensions."""
function project_trust_resources_present(directory::String)
    root=joinpath(directory,".pi")
    any(name->ispath(joinpath(root,name)) || islink(joinpath(root,name)),("skills","prompts"))
end

"""Load the session's admission decision before any project prompt or skill is parsed."""
function initialize_project_trust!(app::App;directory::AbstractString=app.settings.workspace)
    location=abspath(directory)
    state=ProjectTrustState(;directory=location,canonical=location,path=joinpath(abspath(app.settings.directory),"project-trust.json"))
    app.menus.project_trust=state
    result=preference_attempt() do
        canonical=project_trust_canonical(location)
        state.canonical=canonical
        snapshot=project_trust_read(state.path)
        entry=project_trust_entry(snapshot.data,canonical)
        resources=project_trust_resources_present(canonical)
        fallback=menu_preference(app,"default-project-trust","Ask")
        valid=fallback in ("Ask","Always trust","Never trust")
        valid || error("Default project trust is invalid; project resources are blocked")
        trusted=!isnothing(entry) ? entry.decision : !resources ? true : fallback=="Always trust"
        pending=isnothing(entry) && resources && fallback=="Ask"
        (;canonical,snapshot,entry,trusted,pending,admitted=trusted && (!isnothing(entry) || resources || fallback=="Always trust"))
    end
    if result.ok
        value=result.value
        state.canonical=value.canonical
        state.revision=value.snapshot.raw
        state.saved_path=isnothing(value.entry) ? nothing : value.entry.path
        state.saved_decision=isnothing(value.entry) ? nothing : value.entry.decision
        state.trusted=value.trusted
        state.resource_admitted=value.admitted
        state.pending=value.pending
        if state.pending
            open_project_trust!(app;startup=true)
        end
    else
        state.store_error=result.reason
        app.status=result.reason
        frontend_notice!(app,result.reason;kind=:warning)
    end
    state
end

"""Keep identity and admission checks separate from loading; new resources cannot inherit an empty-directory bypass."""
function project_trust_prepare_discovery!(app::App,directory::AbstractString)
    state=app.menus.project_trust
    location=abspath(directory)
    if isnothing(state)
        state=initialize_project_trust!(app;directory=location)
    elseif state.directory!=location
        identity=preference_attempt() do
            previous=project_trust_canonical(state.directory)
            current=project_trust_canonical(location)
            previous==state.canonical || error("Previously admitted project identity changed; project resources are blocked")
            current
        end
        if !identity.ok
            state.error=identity.reason
            app.status=identity.reason
            frontend_notice!(app,identity.reason;kind=:warning)
        elseif identity.value==state.canonical
            state.directory=location
        else
            state=initialize_project_trust!(app;directory=location)
        end
    elseif isempty(state.error) && !state.resource_admitted && !state.pending && state.trusted && project_trust_resources_present(location)
        state=initialize_project_trust!(app;directory=location)
    end
    state
end

"""Preserve the current admission across same-project new/fork/resume rather than applying next-start policy early."""
function project_trust_session_transition!(app::App)
    state=project_trust_prepare_discovery!(app,app.settings.workspace)
    state.pending && open_project_trust!(app;startup=true)
    controls=app.menus.startup
    isnothing(controls) || startup_discover_resources!(controls,app)
    nothing
end

"""Admit only unchanged canonical project text resources, rejecting symlink paths before content reads."""
function project_resource_path(app::App,path::AbstractString;directory::AbstractString=app.settings.workspace)
    state=project_trust_prepare_discovery!(app,directory)
    if !state.trusted || !state.resource_admitted || !isempty(state.error)
        nothing
    else
        outcome=preference_attempt() do
            project_trust_canonical(directory)==state.canonical || error("Project directory identity changed; project resources are blocked")
            candidate=abspath(path)
            inside(root)=begin
                relative=relpath(candidate,root)
                relative!=".." && !startswith(relative,".."*string(Base.Filesystem.path_separator)) && !isabspath(relative)
            end
            root=inside(state.directory) ? state.directory : inside(state.canonical) ? state.canonical : nothing
            isnothing(root) && error("Project resource escapes the admitted directory")
            current=candidate
            while current!=root
                islink(current) && error("Symlinked project resources are not admitted")
                current=dirname(current)
            end
            resolved=realpath(candidate)
            relative=relpath(resolved,state.canonical)
            relative!=".." && !startswith(relative,".."*string(Base.Filesystem.path_separator)) && !isabspath(relative) || error("Project resource target is outside the admitted directory")
            resolved
        end
        if outcome.ok
            outcome.value
        else
            state.error=outcome.reason
            app.status=outcome.reason
            frontend_notice!(app,outcome.reason;kind=:warning)
            nothing
        end
    end
end

"""Open the explicit trust selector; saved choices apply only after restart outside the first-run prompt."""
function open_project_trust!(app::App;startup::Bool=false)
    state=app.menus.project_trust
    if isnothing(state)
        state=initialize_project_trust!(app)
    end
    if !startup
        result=preference_attempt() do
            project_trust_canonical(state.directory)==state.canonical || error("Project directory identity changed; restart before saving a decision")
            project_trust_read(state.path)
        end
        if result.ok
            state.store_error=""
            snapshot=result.value
            entry=project_trust_entry(snapshot.data,state.canonical)
            state.revision=snapshot.raw
            state.saved_path=isnothing(entry) ? nothing : entry.path
            state.saved_decision=isnothing(entry) ? nothing : entry.decision
        else
            state.store_error=result.reason
        end
    end
    state.startup_prompt=startup
    state.pasting=false
    state.paste_marker=""
    state.options=isempty(state.error) && isempty(state.store_error) ? project_trust_options(state.canonical;session_only=startup) : ProjectTrustOption[]
    selected=findfirst(option->!isnothing(option.saved_path) && option.saved_path==state.saved_path && option.trusted===state.saved_decision,state.options)
    state.cursor=isnothing(selected) ? 1 : selected
    app.menu=false
    app.page=:pi_menu
    app.menus.path=["trust"]
    nothing
end

"""Commit a deliberate selector choice, with no grant on cancellation, error, or stale storage."""
function project_trust_select!(app::App)
    state=app.menus.project_trust
    if !app.operations.closing[] && !isnothing(state) && !isempty(state.options)
        option=state.options[clamp(state.cursor,1,length(state.options))]
        result=project_trust_save!(state,option)
        if result.ok
            was_startup=state.startup_prompt
            state.pending=false
            state.startup_prompt=false
            if was_startup
                state.trusted=option.trusted
                state.resource_admitted=option.trusted
                app.page=:chat
                controls=app.menus.startup
                isnothing(controls) || startup_discover_resources!(controls,app)
                app.status="Project "*(option.trusted ? "trusted" : "untrusted")*" for this session; host permissions remain unchanged."
            else
                app.page=:chat
                app.status="Saved trust decision: "*(option.trusted ? "trusted" : "untrusted")*". Restart Julia Forever 2 for this to take effect."
            end
            frontend_notice!(app,app.status)
        else
            state.store_error=result.reason
            app.status=result.reason
            frontend_notice!(app,result.reason;kind=:warning)
        end
    end
    nothing
end

"""Cancel admission without saving or loading project resources."""
function project_trust_cancel!(app::App)
    state=app.menus.project_trust
    if !isnothing(state) && state.startup_prompt
        state.trusted=false
        state.resource_admitted=false
        state.pending=false
        state.startup_prompt=false
    end
    app.page=:chat
    nothing
end

"""Discard bracketed paste bytes without retaining content or allowing pasted control sequences to grant trust."""
function project_trust_paste!(state::ProjectTrustState,packet::String;escape_key::Bool=false)
    marker=state.pasting ? "\e[201~" : "\e[200~"
    pending=!isempty(state.paste_marker)
    candidate=state.paste_marker*packet
    found=findfirst(marker,candidate)
    if !isnothing(found)
        state.paste_marker=""
        if state.pasting
            state.pasting=false
        else
            state.pasting=true
            remainder=String(SubString(candidate,nextind(candidate,last(found))))
            isempty(remainder) || project_trust_paste!(state,remainder)
        end
        true
    elseif state.pasting || pending || ((packet!="\e" || !escape_key) && occursin('\e',packet))
        state.paste_marker=""
        for count in 1:length(marker)-1
            prefix=first(marker,count)
            endswith(candidate,prefix) && (state.paste_marker=prefix)
        end
        state.pasting || pending || !isempty(state.paste_marker)
    else
        false
    end
end

"""Use clamped source selector navigation while preserving release and modifier distinctions."""
function project_trust_input!(app::App,event::KeyEvent,raw::AbstractVector{UInt8})
    state=app.menus.project_trust
    if !isnothing(state)
        packet=menu_packet(event,raw)
        pasted=project_trust_paste!(state,packet;escape_key=event.key==:escape)
        navigation=pasted ? :none : menu_select_navigation(packet)
        action=pasted || terminal_viewport_action(packet)==:release ? :none : chat_key_packet(packet).action
        if pasted
            nothing
        elseif navigation==:up || packet=="k"
            state.cursor=max(1,state.cursor-1)
        elseif navigation==:down || packet=="j"
            state.cursor=min(max(1,length(state.options)),state.cursor+1)
        elseif action==:submit || packet=="\n"
            project_trust_select!(app)
        elseif action in (:interrupt,:copy)
            project_trust_cancel!(app)
        end
    end
    nothing
end
