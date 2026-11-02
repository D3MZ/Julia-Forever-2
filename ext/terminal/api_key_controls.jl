"""Keep prompt readiness and key validation tied to the same native auth owner."""
function api_key_prompt_ready!(app::App,value)
    flow=value
    control=app.menus.auth_menu_control
    ready=control isa AuthMenuControl && api_key_dialog_status(app,control).available
    if app.settings.auth_flow===flow && active_auth(flow) && ready
        app.status="Enter the API key in the private field. No model request will be sent."
    end
    nothing
end

"""Start an actual key validator without launching a browser or changing the selected model."""
function authenticate!(app::App,provider::Symbol,method::JuliaForever2.APIKeyAuthMethod)
    flow=AuthFlow()
    app.settings.auth_flow=flow
    app.settings.auth_url=""
    app.settings.auth_provider=provider
    app.busy=true
    app.page=:auth
    app.status="Preparing private API key sign-in…"
    control=app.menus.auth_menu_control
    if !(control isa AuthMenuControl && auth_menu_owned(app,control))
        control=AuthMenuControl(;on_login=auth_menu_start_login!,on_logout=auth_menu_start_logout!,
            generation=app.menus.generation,direct=true)
        app.menus.auth_menu_control=control
    end
    control.key_method=method
    control.flow=flow
    control.stage=:auth
    control.callback_input=AuthCallbackInput()
    generation=control.generation
    register_event_handler!(app,:api_key_prompt_ready,api_key_prompt_ready!)
    registry=app.settings.registry
    commit=action->lock(registry.lock) do
        descriptor=provider_descriptor(registry,provider)
        owned=app.settings.auth_flow===flow && app.menus.generation==generation &&
            !app.operations.closing[] && !isnothing(descriptor) && descriptor.auth===method
        owned ? action() : (ok=false,reason=:changed)
    end
    task=Threads.@spawn begin
        notify=()->enqueue_event!(app,TaskEvent(:api_key_prompt_ready,flow))
        result=method(flow,provider,app.settings.directory;notify,commit)
        (;result...,preserve_selection=true)
    end
    app.settings.auth_task=task
    notify_completion!(app,:auth_done,task,(flow,task);cleanup=()->close(flow))
    task
end

"""Observe readiness without reading or retaining the private request's key bytes."""
function api_key_dialog_status(app,control::AuthMenuControl)
    flow=control.flow
    method=control.key_method
    if auth_dialog_owned(app,control) && !isnothing(flow) && !isnothing(method)
        JuliaForever2.api_key_request_status(method,flow)
    else
        (available=false,phase=:absent,prompt="",provider=:none)
    end
end
api_key_input_notice(::Val{:none})=""
api_key_input_notice(::Val{:too_long})="API key exceeds the 8192-byte limit."
api_key_input_notice(::Val{:unsafe_input})="Enter the key without control characters."
api_key_input_notice(::Val)="API key intake was rejected; sign-in is not complete."

"""Render the source-compatible secret prompt with a deliberate privacy-only masking exception."""
function api_key_dialog_layout(app,control::AuthMenuControl,columns::Int)
    lines=Vector{Tachikoma.Span}[]
    cursor=nothing
    border=[auth_dialog_span(app,repeat("─",columns),:menu_border)]
    push!(lines,border)
    descriptor=provider_descriptor(app.settings.registry,app.settings.auth_provider)
    name=auth_dialog_provider_name(descriptor,app.settings.auth_provider)::String
    append!(lines,auth_dialog_text([auth_dialog_span(app,"Login to "*name,:accent;bold=auth_menu_bold(app.menus.theme_runtime))],columns))
    status=api_key_dialog_status(app,control)
    if status.available || control.callback_input.received
        input=control.callback_input
        method=control.key_method
        prompt=isempty(status.prompt) && !isnothing(method) ? "Enter "*method.name : status.prompt
        push!(lines,Tachikoma.Span[])
        append!(lines,auth_dialog_text([auth_dialog_span(app,prompt,:text)],columns))
        if input.received
            append!(lines,auth_dialog_text([auth_dialog_span(app,"> API key received; validating…")],columns;padding=0))
        else
            masked=MenuSearchInput(;value=repeat("•",input.used),cursor=input.cursor)
            row=menu_search_spans(masked,columns)
            cursor=(x=min(2+masked.cursor-masked.rendered_start_column,columns-1),y=length(lines))
            push!(lines,row)
        end
        if input.warning!=:none
            append!(lines,auth_dialog_text([auth_dialog_span(app,api_key_input_notice(Val(input.warning)),:error)],columns))
        end
        hint=[auth_dialog_span(app,"("),auth_dialog_span(app,native_selector_text(native_selector_context(app),:cancel),:dim),auth_dialog_span(app," to cancel,",:muted),
            auth_dialog_span(app," "),auth_dialog_span(app,"enter",:dim),auth_dialog_span(app," to submit",:muted),auth_dialog_span(app,")")]
        append!(lines,auth_dialog_text(hint,columns))
    end
    push!(lines,border)
    (;lines,cursor)
end

"""Private input cannot become chat history, a copied URL, or an authenticated status by itself."""
function api_key_dialog_input!(app,control::AuthMenuControl,event::KeyEvent,raw::AbstractVector{UInt8})
    packet=menu_packet(event,raw)
    status=api_key_dialog_status(app,control)
    flow=control.flow
    method=control.key_method
    input=control.callback_input
    if !input.pasting && isempty(input.opening) && native_selector_matches(native_selector_context(app),:cancel,packet)
        auth_menu_cancel_auth!(app,control)
    elseif (status.available || input.received) && !isnothing(flow) && !isnothing(method)
        action=auth_callback_input!(input,packet;selectors=native_selector_context(app),escape_key=event.key==:escape)
        if action==:cancel
            auth_menu_cancel_auth!(app,control)
        elseif action==:submit
            descriptor=provider_descriptor(app.settings.registry,method.provider)
            if isnothing(descriptor) || descriptor.auth!==method
                auth_callback_clear!(input)
                cancel_auth!(flow)
                app.status="Provider authentication changed; sign-in cancelled."
            else
                result=auth_callback_submit!(input,value->JuliaForever2.submit_api_key!(method,flow,value))
                app.status=result.ok ? "API key received; validating…" : "API key intake rejected; sign-in is not complete."
            end
        end
    end
    nothing
end

api_key_configured(action,directory,id,current::Bool)=current
api_key_configured(action::JuliaForever2.APIKeyAuthMethod,directory,id,current::Bool)=JuliaForever2.api_key_observed_state(directory,id)==:stored

"""Lazy native key resolvers retain no secret, so logout can preserve the selected model safely."""
function logout_backend(provider::JuliaForever2.ModelProvider{M,B},directory::AbstractString;stored::Bool) where {M,B<:JuliaForever2.HTTPModelBackend}
    backend=provider.backend
    if backend.credentials isa JuliaForever2.APIKeyCredentialResolver
        provider
    else
        error("This model backend does not implement safe credential-cache invalidation.")
    end
end
