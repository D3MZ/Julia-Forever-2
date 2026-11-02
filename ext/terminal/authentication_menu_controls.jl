# Host ownership for authentication menus. Native services remain the only grant/removal writers.
public AuthMenuControl, auth_menu_open!, auth_menu_active, auth_menu_input!, auth_menu_lines, auth_menu_cursor
public auth_menu_finish!, auth_menu_cancel_auth!, auth_menu_dispose!, auth_menu_logout_finish!
public auth_menu_manual_active, auth_menu_manual_input!, auth_menu_manual_lines, auth_menu_manual_cursor

"""Separate UI ownership, actual provider observation and replaceable native service boundaries."""
Base.@kwdef mutable struct AuthMenuControl{L,O,A,S}
    on_login::L
    on_logout::O
    on_manual_available::A = auth_menu_manual_available
    on_manual_submit::S = auth_menu_manual_submit!
    callback_input::AuthCallbackInput = AuthCallbackInput()
    key_method::Union{Nothing,JuliaForever2.APIKeyAuthMethod}=nothing
    mode::Symbol = :login
    stage::Symbol = :methods
    scope::Symbol = :oauth
    selector::Union{Nothing,AuthenticationSelector} = nothing
    generation::UInt = UInt(0)
    flow::Union{Nothing,JuliaForever2.AuthFlow} = nothing
    query::String = ""
    active::Bool = true
    direct::Bool = false
end

Base.show(io::IO,control::AuthMenuControl)=print(io,"AuthMenuControl(",control.mode,", ",control.stage,", private flow redacted)")
Base.show(io::IO,::MIME"text/plain",control::AuthMenuControl)=show(io,control)

auth_menu_manual_available(flow)=JuliaForever2.manual_auth_available(flow)
auth_menu_manual_submit!(flow,value)=JuliaForever2.submit_auth_callback!(flow,value)
auth_menu_start_login!(app,id;action)=start_sign_in!(app,id;action)
auth_menu_start_logout!(app,id)=start_logout!(app,String(id))
auth_menu_method(descriptor::JuliaForever2.ProviderDescriptor)=auth_menu_method(descriptor.auth,Val(descriptor.id))
auth_menu_method(action,id::Val)=auth_menu_method(id)
auth_menu_method(action::JuliaForever2.APIKeyAuthMethod,::Val)=(kind=:api_key,subscription=false,label=action.name)
auth_menu_method(::Val{:chatgpt})=(kind=:oauth,subscription=true,label="Sign in with ChatGPT")
auth_menu_method(::Val{:openrouter})=(kind=:oauth,subscription=false,label="Browser authorization for an OpenRouter API key")
auth_menu_method(::Val{:codex})=(kind=:provider_flow,subscription=false,label="Sign in using the Codex CLI")
auth_menu_method(::Val)=(kind=:provider_flow,subscription=false,label="Provider-specific sign in")
auth_menu_stored_kind(descriptor::JuliaForever2.ProviderDescriptor)=auth_menu_stored_kind(descriptor.auth,Val(descriptor.id))
auth_menu_stored_kind(action,id::Val)=auth_menu_stored_kind(id)
auth_menu_stored_kind(action::JuliaForever2.APIKeyAuthMethod,::Val)=:api_key
auth_menu_stored_kind(::Val{:chatgpt})=:oauth
auth_menu_stored_kind(::Val{:openrouter})=:api_key
auth_menu_stored_kind(::Val)=:provider_flow

"""Observe only presence and source of app-owned credentials; no secret enters menu state."""
function auth_menu_observed_status(app,id::Symbol)
    probe=Task(()->JuliaForever2.CredentialStorage.credential_revision(app.settings.directory,id))
    schedule(probe)
    wait(probe;throw=false)
    if istaskfailed(probe)
        (ok=false,status=nothing)
    else
        saved=fetch(probe)::Union{Nothing,String}
        descriptor=provider_descriptor(app.settings.registry,id)
        stored_kind=isnothing(descriptor) ? auth_menu_stored_kind(Val(id)) : auth_menu_stored_kind(descriptor)
        status=if !isnothing(saved)
            AuthProviderStatus(;kind=stored_kind,source="stored credential")
        elseif id==:openrouter && !isempty(get(ENV,"OPENROUTER_API_KEY",""))
            AuthProviderStatus(;kind=:api_key,source="OPENROUTER_API_KEY")
        else
            nothing
        end
        (ok=true,status)
    end
end

"""Build rows only from live registry methods or removal claims supplied by the real logout owner."""
function auth_menu_options(app,mode::Symbol)
    options=AuthProviderOption[]
    for descriptor in provider_descriptors(app.settings.registry)
        removable=mode==:logout && haskey(app.menus.logout_revisions,String(descriptor.id))
        available=mode==:login && !isnothing(descriptor.auth)
        if removable || available
            method=auth_menu_method(descriptor)
            observed=removable ? (ok=true,status=AuthProviderStatus(;kind=auth_menu_stored_kind(descriptor),source="stored credential")) : auth_menu_observed_status(app,descriptor.id)
            if observed.ok
                status=observed.status
                kind=removable ? auth_menu_stored_kind(descriptor) : method.kind
                push!(options,AuthProviderOption(;id=String(descriptor.id),name=descriptor.label,kind,
                    method_name=method.label,subscription=method.subscription,status))
            else
                app.status="Credential state is unsafe or unavailable for "*descriptor.label*"; authentication is blocked."
            end
        end
    end
    sort!(options;by=option->lowercase(option.name),alg=Base.Sort.MergeSort)
end

auth_menu_bold(::Nothing)=false
auth_menu_bold(runtime)=runtime.active.bold
auth_menu_runtime_style(::Nothing,token::Symbol)=Tachikoma.Style()
auth_menu_runtime_style(runtime,token::Symbol)=theme_style(runtime,token)
function auth_menu_style(app,token::Symbol)
    token==:default ? Tachikoma.Style() : auth_menu_runtime_style(app.menus.theme_runtime,token)
end

"""Release a menu without changing credentials, active services or another menu's generation."""
function auth_menu_dispose!(control::AuthMenuControl)
    control.active=false
    auth_callback_dispose!(control.callback_input)
    selector=control.selector
    if !isnothing(selector)
        auth_selector_dispose!(selector)
    end
    control.selector=nothing
    nothing
end
auth_menu_dispose!(::Nothing)=nothing

auth_menu_owned(app,control::AuthMenuControl)=control.active && control.generation==app.menus.generation && !app.operations.closing[]
auth_menu_active(app,::Nothing)=false
auth_menu_active(app,control::AuthMenuControl)=auth_menu_owned(app,control) && app.page==:pi_menu && control.stage in (:methods,:providers,:logout)

function auth_menu_close!(app,control::AuthMenuControl)
    if auth_menu_owned(app,control)
        app.page=:chat
        auth_menu_dispose!(control)
    end
    nothing
end

function auth_menu_method_choice!(app,control::AuthMenuControl,option::AuthMethodOption)
    if auth_menu_owned(app,control)
        control.scope=Symbol(option.id)
        control.query=""
        auth_menu_providers!(app,control)
    end
    nothing
end

"""Offer only callable native methods; unavailable API-key entry is never a decorative action."""
function auth_menu_methods!(app,control::AuthMenuControl)
    options=auth_menu_options(app,:login)
    methods=AuthMethodOption[]
    if any(option->option.kind==:oauth,options)
        push!(methods,AuthMethodOption(;id="oauth",label="Sign in with an account"))
    end
    if any(option->option.kind==:api_key,options)
        push!(methods,AuthMethodOption(;id="api_key",label="Sign in with an API key"))
    end
    if any(option->option.kind==:provider_flow,options)
        push!(methods,AuthMethodOption(;id="provider_flow",label="Provider-specific sign in"))
    end
    previous=control.selector
    isnothing(previous) || auth_selector_dispose!(previous)
    control.stage=:methods
    control.selector=AuthMethodMenu("Select authentication method:",methods;
        style=token->auth_menu_style(app,token),bold=auth_menu_bold(app.menus.theme_runtime),on_select=option->auth_menu_method_choice!(app,control,option),
        on_cancel=()->auth_menu_close!(app,control))
    app.page=:pi_menu
    isempty(methods) && (app.status="No implemented authentication methods are available.")
    nothing
end

function auth_menu_provider_selected!(app,control::AuthMenuControl,option::AuthProviderOption)
    selector=control.selector
    if auth_menu_owned(app,control) && !isnothing(selector)
        descriptor=provider_descriptor(app.settings.registry,Symbol(option.id))
        if app.busy
            app.status="Finish or cancel the active operation first."
        elseif control.mode==:logout
            control.on_logout(app,option.id)
            if app.busy
                auth_selector_dispose!(selector)
                control.stage=:removing
                app.page=:chat
            end
        elseif isnothing(descriptor) || isnothing(descriptor.auth) || auth_menu_method(descriptor).kind!=option.kind
            app.status="Provider authentication changed; reopen the selector."
            auth_menu_providers!(app,control)
        else
            control.query=selector isa AuthProviderMenu ? selector.search.value : ""
            auth_selector_dispose!(selector)
            control.stage=:auth
            control.callback_input=AuthCallbackInput()
            control.key_method=descriptor.auth isa JuliaForever2.APIKeyAuthMethod ? descriptor.auth : nothing
            control.on_login(app,descriptor.id;action=descriptor.auth)
            control.flow=app.settings.auth_flow
            if isnothing(control.flow)
                app.status="The provider did not start an authentication flow."
                auth_menu_providers!(app,control)
            end
        end
    end
    nothing
end

function auth_menu_providers!(app,control::AuthMenuControl)
    options=auth_menu_options(app,control.mode)
    selected=control.mode==:logout || control.scope==:all ? options : filter(option->option.kind==control.scope,options)
    previous=control.selector
    isnothing(previous) || auth_selector_dispose!(previous)
    control.stage=control.mode==:logout ? :logout : :providers
    cancel=control.mode==:logout || control.scope==:all ? ()->auth_menu_close!(app,control) : ()->auth_menu_methods!(app,control)
    control.selector=AuthProviderMenu(selected;mode=control.mode,query=control.query,
        style=token->auth_menu_style(app,token),bold=auth_menu_bold(app.menus.theme_runtime),on_select=option->auth_menu_provider_selected!(app,control,option),on_cancel=cancel)
    app.page=:pi_menu
    nothing
end

"""Open after the caller increments menu generation; no sign-in occurs until a real row is confirmed."""
function auth_menu_open!(app,name::AbstractString;on_login=auth_menu_start_login!,on_logout=auth_menu_start_logout!,on_manual_available=auth_menu_manual_available,on_manual_submit=auth_menu_manual_submit!)
    control=AuthMenuControl(;on_login,on_logout,on_manual_available,on_manual_submit,mode=Symbol(name),generation=app.menus.generation)
    if name=="logout"
        open_logout_controls!(app)
        auth_menu_providers!(app,control)
    else
        auth_menu_methods!(app,control)
    end
    control
end

function auth_menu_input!(app,control::AuthMenuControl,event::KeyEvent,raw::AbstractVector{UInt8}=UInt8[])
    selector=control.selector
    if auth_menu_active(app,control) && !isnothing(selector)
        packet=menu_packet(event,raw)
        isempty(packet) || auth_selector_input!(selector,packet;selectors=native_selector_context(app))
    end
    nothing
end
function auth_menu_lines(app,control::AuthMenuControl,width::Integer)
    selector=control.selector
    auth_menu_active(app,control) && !isnothing(selector) ? auth_selector_lines(selector,width;selectors=native_selector_context(app)) : Vector{Tachikoma.Span}[]
end
auth_menu_cursor(::Nothing)=nothing
auth_menu_cursor(control::AuthMenuControl)=auth_menu_cursor(control.selector)
auth_menu_cursor(::AuthMethodMenu)=nothing
function auth_menu_cursor(menu::AuthProviderMenu)
    (x=2+menu_search_width(menu_search_prefix(menu.search))-menu.search.rendered_start_column,y=4)
end

"""Cancel the owned flow, then wait for the normal completion event before returning to its selector."""
function auth_menu_cancel_auth!(app,control::AuthMenuControl)
    flow=control.flow
    owned=auth_menu_owned(app,control) && control.stage==:auth && app.settings.auth_flow===flow && !isnothing(flow)
    if owned && !isnothing(flow)
        auth_callback_dispose!(control.callback_input)
        cancel_auth!(flow)
        app.status="Cancelling sign-in…"
    end
    owned
end

"""Restore back navigation only after native completion and only for the same owned flow."""
function auth_menu_finish!(app,control::AuthMenuControl,flow;ok::Bool)
    if auth_menu_owned(app,control) && control.stage==:auth && control.flow===flow
        auth_callback_dispose!(control.callback_input)
        control.flow=nothing
        if ok || control.direct
            auth_menu_close!(app,control)
        else
            auth_menu_providers!(app,control)
        end
    end
    nothing
end

"""Close the selection owner after the credential service has reported its verified completion."""
function auth_menu_logout_finish!(app,control::AuthMenuControl)
    if auth_menu_owned(app,control) && control.stage==:removing
        auth_menu_close!(app,control)
    end
    nothing
end


"""Expose intake only for the same active native flow and never resurrect a disposed input."""
function auth_menu_manual_active(app,control::AuthMenuControl)
    flow=control.flow
    owned=auth_menu_owned(app,control) && app.page==:auth && control.stage==:auth && !isnothing(flow) && app.settings.auth_flow===flow
    available=owned && !isnothing(flow) && !control.callback_input.disposed && (control.callback_input.received || control.on_manual_available(flow))
    if !available
        auth_callback_clear!(control.callback_input)
    end
    available
end
auth_menu_manual_active(app,::Nothing)=false

"""Route private input directly to the owned native callback service, never the chat editor."""
function auth_menu_manual_input!(app,control::AuthMenuControl,event::KeyEvent,raw::AbstractVector{UInt8}=UInt8[])
    flow=control.flow
    handled=!isnothing(flow) && auth_menu_manual_active(app,control) && control.flow===flow
    if handled && !isnothing(flow)
        action=auth_callback_input!(control.callback_input,menu_packet(event,raw);selectors=native_selector_context(app),escape_key=event.key==:escape)
        if action==:cancel
            auth_menu_cancel_auth!(app,control)
        elseif action==:submit
            result=auth_callback_submit!(control.callback_input,value->control.on_manual_submit(flow,value))
            app.status=result.ok ? "Callback received; verifying sign-in…" : "Callback was rejected; sign-in is not complete."
        end
    end
    handled
end
function auth_menu_manual_lines(app,control::AuthMenuControl,width::Integer)
    auth_menu_manual_active(app,control) ? auth_callback_lines(control.callback_input,width;style=token->auth_menu_style(app,token),selectors=native_selector_context(app)) : Vector{Tachikoma.Span}[]
end
auth_menu_manual_cursor(control::AuthMenuControl)=auth_callback_cursor(control.callback_input)

"""Honor exact provider ids/names before falling back to the full, honestly implemented method list."""
function auth_menu_reference!(app,control::AuthMenuControl,reference::AbstractString)
    normalized=lowercase(strip(reference))
    options=auth_menu_options(app,:login)
    matches=filter(option->lowercase(option.id)==normalized || lowercase(option.name)==normalized,options)
    control.scope=:all
    control.query=String(reference)
    auth_menu_providers!(app,control)
    if length(matches)==1
        control.direct=true
        auth_menu_provider_selected!(app,control,only(matches))
    end
    nothing
end
auth_menu_reference!(app,::Nothing,reference::AbstractString)=nothing
