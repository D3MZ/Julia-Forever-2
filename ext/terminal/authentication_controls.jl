"""Release revision and declared-kind selections together without changing stored credentials."""
function clear_logout_controls!(app::App)
    empty!(app.menus.logout_revisions)
    empty!(app.menus.logout_kinds)
    nothing
end

"""Snapshot only app-owned credential revisions; a menu entry never grants provider access."""
function open_logout_controls!(app::App)
    clear_logout_controls!(app)
    unavailable = false
    for descriptor in provider_descriptors(app.settings.registry)
        probe = Task(() -> JuliaForever2.CredentialStorage.credential_revision(app.settings.directory, descriptor.id))
        schedule(probe)
        wait(probe; throw=false)
        if istaskfailed(probe)
            unavailable = true
        else
            revision = fetch(probe)
            if !isnothing(revision)
                id=String(descriptor.id)
                app.menus.logout_revisions[id]=revision
                app.menus.logout_kinds[id]=auth_menu_stored_kind(descriptor)
            end
        end
    end
    if unavailable
        app.status = "Some credential storage is unsafe or unavailable; those entries cannot be removed."
    elseif isempty(app.menus.logout_revisions)
        app.status = "No stored credentials to remove."
    end
    nothing
end

"""Rebuild credential-owning backends without retaining a removed key or account catalog."""
logout_backend(provider, directory::AbstractString; stored::Bool) =
    error("This provider does not implement safe credential-cache invalidation.")
logout_backend(provider::JuliaForever2.OpenRouterProvider, directory::AbstractString; stored::Bool) =
    JuliaForever2.OpenRouterProvider(stored ? JuliaForever2.openrouter_key(directory) : get(ENV, "OPENROUTER_API_KEY", ""),
        provider.model, provider.transport; policy=provider.policy, reasoning=provider.reasoning)
logout_backend(provider::JuliaForever2.OpenAIProvider, directory::AbstractString; stored::Bool) =
    JuliaForever2.OpenAIProvider(provider.dir, provider.transport, provider.auth_transport; model=provider.model,
        policy=provider.policy, catalog_ttl=provider.catalog_ttl, reasoning=provider.reasoning,
        reasoning_summary=provider.reasoning_summary)
logout_backend(provider::JuliaForever2.ConfiguredModelProvider, directory::AbstractString; stored::Bool) =
    JuliaForever2.ConfiguredModelProvider(logout_backend(provider.backend, directory; stored), provider.model, provider.thinking_level)

"""Replace the active backend only after checking the supported native credential owner."""
function refresh_logout_backend!(app::App, provider, id::Symbol; stored::Bool)
    if JuliaForever2.provider_model_identity(provider).provider_id == id
        replacement = logout_backend(provider, app.settings.directory; stored)
        result = JuliaForever2.install!(app.session.kernel, JuliaForever2.ComponentSpec(:provider, replacement))
        result.ok || error("Could not invalidate the active provider credential cache: " * result.reason)
    end
    nothing
end

"""Remove selected local access under the session owner and existing credential write claim."""
function logout_owned_credentials!(app::App, id::Symbol, expected::String, context)
    directory = app.settings.directory
    lock(app.session.runtime.execution_lock) do
        lock(JuliaForever2.auth_lock(directory, id)) do
            current = JuliaForever2.CredentialStorage.credential_revision(directory, id)
            if cancelled(context) || app.operations.closing[]
                JuliaForever2.ExecutionResult(false, "Credential removal cancelled.")
            elseif current != expected
                JuliaForever2.ExecutionResult(false, "Credentials changed; reopen logout before removing them.")
            else
                provider = JuliaForever2.component(app.session.kernel, :provider)
                # Disable cached local access before the destructive operation. Failure must not leave an old key usable.
                refresh_logout_backend!(app, provider, id; stored=false)
                result = JuliaForever2.CredentialStorage.delete_credentials!(directory, id;
                    expected, active=() -> !cancelled(context) && !app.operations.closing[])
                result.removed || refresh_logout_backend!(app, provider, id; stored=true)
                text = result.removed ? "Stored credentials removed. Environment credentials and remote grants were not changed." : result.reason
                JuliaForever2.ExecutionResult(result.ok, text)
            end
        end
    end
end

function start_logout!(app::App, selected::AbstractString)
    expected = get(app.menus.logout_revisions, String(selected), nothing)
    if app.busy || app.operations.closing[]
        app.status = "Finish or cancel the active operation first."
    elseif isnothing(expected)
        app.status = "No selected stored credential; reopen logout."
    else
        id = Symbol(selected)
        handle = JuliaForever2.submit_managed!(app.session, app.session, ui_context(app)) do context
            logout_owned_credentials!(app, id, expected, context)
        end
        track_operation!(app, handle, :logout_done, "Removing stored credentials…")
    end
    nothing
end

"""Contain optional provider status failures without exposing callback errors or changing removal outcomes."""
function refresh_logout_settings!(app::App)
    refresh=Task(()->refresh_settings!(app))
    schedule(refresh)
    wait(refresh;throw=false)
    if istaskfailed(refresh)
        frontend_notice!(app,"Provider settings could not be refreshed. Reopen settings to retry.";kind=:warning)
    end
    nothing
end

"""Settle the verified removal outcome before refreshing optional provider status."""
function logout_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        clear_logout_controls!(app)
        app.operations.active = nothing
        app.operations.active_kind = :none
        app.busy = false
        result = session_action_result(handle)
        control=app.menus.auth_menu_control
        control isa AuthMenuControl && auth_menu_logout_finish!(app,control)
        app.menus.generation += UInt(1)
        app.page = :chat
        app.status = result.text
        refresh_logout_settings!(app)
    end
    nothing
end
