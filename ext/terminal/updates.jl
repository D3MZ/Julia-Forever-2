"""Check upstream without blocking the terminal event loop."""
function start_update_check!(app::App; root::AbstractString=installation_root(), checker=check_for_updates)
    if !app.updates.checking && !app.operations.closing[]
        Threads.atomic_add!(app.updates.manual_generation, UInt64(1))
        app.updates.checking = true
        app.status = "Checking for updates..."
        task = Threads.@spawn checker(root)
        notify_completion!(app, :update_checked, task, task)
    end
    return nothing
end

"""Install the revision already discovered by the updater."""
function start_update_install!(app::App; installer=apply_update!, automatic=false)
    check = app.updates.latest
    if !isnothing(check) && update_available(check) && !app.updates.installing && !app.operations.closing[]
        generation = app.updates.permission_generation[]
        app.updates.installing = true
        app.status = "Installing update..."
        task = Threads.@spawn run_update_install!(app, check, installer, automatic, generation)
        notify_completion!(app, :update_installed, task, task)
    end
    return nothing
end

"""Distinguish an unstarted installation from any installer-returned value."""
struct UpdateAdmissionCancelled end

"""Recheck automatic permission at worker admission without claiming atomic revocation."""
function run_update_install!(app::App, check::UpdateCheck, installer, automatic::Bool, generation::UInt64)
    admitted = !app.operations.closing[] && (!automatic ||
        (app.updates.monitor_enabled[] && app.updates.permission_generation[] == generation))
    admitted ? installer(check) : UpdateAdmissionCancelled()
end

"""Publish an update notification, or automatically install when opted in."""
function update_checked!(app::App, check::UpdateCheck; installer=apply_update!)
    if app.updates.checking
        Threads.atomic_add!(app.updates.manual_generation, UInt64(1))
    end
    app.updates.checking = false
    app.updates.latest = check
    if update_available(check)
        if app.updates.automatic || app.updates.requested_install
            start_update_install!(app; installer, automatic=!app.updates.requested_install)
        else
            app.status = "Update available (" * first(check.latest, 7) * "). /update install"
        end
    elseif check.state == :current
        app.busy || (app.status = "Up to date")
    elseif check.state == :unsupported
        app.status = "Updates require a Git installation with a tracked upstream."
    elseif check.state == :diverged
        app.status = "Installation diverged from upstream; fast-forward unavailable."
    else
        app.status = "Unable to fetch updates from upstream."
    end
    app.updates.requested_install = false
    return nothing
end

"""Reject queued background checks after permission or manual authority changes."""
function update_checked!(app::App, result::BackgroundUpdateResult; installer=apply_update!)
    state = app.updates
    current = state.automatic && !app.operations.closing[] && !state.checking && !state.requested_install &&
        state.permission_generation[] == result.permission && state.manual_generation[] == result.manual &&
        state.background_sequence[] == result.sequence && state.accepted_background < result.sequence
    if current
        state.accepted_background = result.sequence
        update_checked!(app, result.check; installer)
    end
    nothing
end

update_check_finished!(app::App, task::Task) = update_checked!(app, fetch(task))
update_check_finished!(app::App, check::UpdateCheck) = update_checked!(app, check)
update_check_finished!(app::App, result::BackgroundUpdateResult) = update_checked!(app, result)

function update_installed!(app::App, task::Task)
    result = fetch(task)
    app.updates.installing = false
    if result === :installed
        app.updates.latest = nothing
        app.status = "Update installed. Restart to use it."
    elseif result === :compile_failed
        app.status = "Checkout advanced, but Julia precompilation failed. Resolve it before restarting."
    elseif result === :merge_failed
        app.status = "Git could not safely fast-forward the installation."
    elseif result === :dirty
        app.status = "Local changes prevent an update; preserve them before retrying."
    elseif result === :changed
        app.status = "The installation changed after the update check; check again."
    elseif result isa UpdateAdmissionCancelled
        app.status = "Update installation was not admitted."
    elseif result === :current
        app.status = "Already up to date."
    else
        app.status = "Update outcome is unknown. Verify the installation before restarting."
    end
    return nothing
end

"""Toggle whether updates are installed automatically after detection."""
function toggle_auto_updates!(app::App; installer=apply_update!)
    app.updates.automatic = set_auto_updates!(app.settings.directory, !app.updates.automatic)
    Threads.atomic_add!(app.updates.permission_generation, UInt64(1))
    app.updates.monitor_enabled[] = app.updates.automatic
    app.status = app.updates.automatic ? "Automatic updates enabled." : "Automatic updates disabled."
    if app.updates.automatic
        start_update_install!(app; installer, automatic=true)
    end
    return nothing
end

function update_command!(app::App, arguments)
    action = strip(arguments)
    if action == "install"
        app.updates.requested_install = true
        start_update_check!(app)
    elseif isempty(action) || action == "check"
        start_update_check!(app)
    else
        app.status = "Usage: /update [check|install]"
    end
    return nothing
end

"""Check in the background only while automatic updates are explicitly enabled."""
function start_update_monitor!(app::App; root::AbstractString=installation_root(), interval_seconds::Real=3600,
        checker=check_for_updates)
    monitor = app.updates.monitor
    if ispath(joinpath(root, ".git")) && (isnothing(monitor) || istaskdone(monitor))
        app.updates.monitor = Threads.@spawn begin
            while !app.operations.closing[]
                enabled = app.updates.monitor_enabled[]
                if enabled
                    permission = app.updates.permission_generation[]
                    manual = app.updates.manual_generation[]
                    sequence = Threads.atomic_add!(app.updates.background_sequence, UInt64(1)) + UInt64(1)
                    check = checker(root)
                    result = BackgroundUpdateResult(permission, manual, sequence, check)
                    app.updates.monitor_enabled[] && !app.operations.closing[] && enqueue_event!(app, TaskEvent(:update_checked, result))
                end
                timedwait(() -> app.operations.closing[] || app.updates.monitor_enabled[] != enabled, interval_seconds; pollint=0.5)
            end
        end
    end
    return app.updates.monitor
end
