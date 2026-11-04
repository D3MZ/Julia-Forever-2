"""Check upstream without blocking the terminal event loop."""
function start_update_check!(app::App; root::AbstractString=installation_root(), checker=check_for_updates)
    if !app.updates.checking && !app.operations.closing[]
        Threads.atomic_add!(app.updates.manual_generation, UInt64(1))
        app.updates.checking = true
        app.status = "Checking for updates..."
        task = Threads.@spawn checker(root)
        app.updates.check_task = task
        app.updates.check_tasks[task] = nothing
        notify_completion!(app, :update_checked, task, ManualUpdateCompletion(task))
    end
    return nothing
end

"""Install the revision already discovered by the updater."""
function start_update_install!(app::App; installer=apply_update!, automatic=false)
    check = app.updates.latest
    if !isnothing(check) && update_available(check) && !app.updates.installing && !app.operations.closing[]
        generation = app.updates.permission_generation[]
        latest_generation = app.updates.latest_generation
        app.updates.installing = true
        app.status = "Installing update..."
        task = Threads.@spawn run_update_install!(app, check, installer, automatic, generation)
        app.updates.install_task = task
        app.updates.install_tasks[task] = latest_generation
        notify_completion!(app, :update_installed, task, InstallUpdateCompletion(task, latest_generation))
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
    app.updates.check_task = nothing
    app.updates.checking = false
    app.updates.latest_generation += UInt64(1)
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

"""Report only the failed check of the currently authorized background monitor."""
function update_checked!(app::App, result::BackgroundMonitorFailure)
    state = app.updates
    current = state.monitor === result.task && state.automatic && state.monitor_enabled[] && !app.operations.closing[] &&
        !state.checking && !state.requested_install && state.permission_generation[] == result.permission &&
        state.manual_generation[] == result.manual && state.background_sequence[] == result.sequence &&
        state.accepted_background < result.sequence
    if current
        state.accepted_background = result.sequence
        app.status = "Automatic update monitor stopped after a check failure."
    end
    nothing
end

function update_check_finished!(app::App, task::Task)
    if haskey(app.updates.check_tasks, task)
        update_check_finished!(app, ManualUpdateCompletion(task))
    else
        update_checked!(app, fetch(task))
    end
    nothing
end
update_check_finished!(app::App, check::UpdateCheck) = update_checked!(app, check)
update_check_finished!(app::App, result::BackgroundUpdateResult) = update_checked!(app, result)
update_check_finished!(app::App, result::BackgroundMonitorFailure) = update_checked!(app, result)

function update_check_finished!(app::App, completion::ManualUpdateCompletion)
    task = completion.task
    if app.updates.check_task === task && istaskdone(task)
        app.updates.check_task = nothing
        if istaskfailed(task)
            failed_update_check!(app)
        else
            checked = fetch(task)
            checked isa UpdateCheck ? update_checked!(app, checked) : failed_update_check!(app)
        end
    end
    nothing
end

function failed_update_check!(app::App)
    if app.updates.checking
        Threads.atomic_add!(app.updates.manual_generation, UInt64(1))
    end
    app.updates.checking = false
    app.updates.requested_install = false
    app.status = "Update check failed. Retry after checking the installation."
    nothing
end

function update_installed!(app::App, task::Task)
    generation = get(app.updates.install_tasks, task, nothing)
    if isnothing(generation)
        publish_update_install!(app, fetch(task), nothing)
    else
        update_installed!(app, InstallUpdateCompletion(task, generation))
    end
    nothing
end

function update_installed!(app::App, completion::InstallUpdateCompletion)
    task = completion.task
    if app.updates.install_task === task && istaskdone(task)
        app.updates.install_task = nothing
        if istaskfailed(task)
            app.updates.installing = false
            app.status = "Update task failed. Verify the installation before restarting."
        else
            publish_update_install!(app, fetch(task), completion.latest_generation)
        end
    end
    nothing
end

function publish_update_install!(app::App, result, generation::Union{Nothing,UInt64})
    app.updates.installing = false
    current = isnothing(generation) || generation == app.updates.latest_generation
    if result === :installed
        if current
            app.updates.latest = nothing
            app.status = "Update installed. Restart to use it."
        else
            app.status = "Update installed. Another check completed; verify the installation before restarting."
        end
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
        app.status = current ? "Already up to date." : "The installer reported no update. Another check completed; verify the installation."
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
        permission = Threads.Atomic{UInt64}(0)
        manual = Threads.Atomic{UInt64}(0)
        sequence = Threads.Atomic{UInt64}(0)
        checking = Threads.Atomic{Bool}(false)
        task = Threads.@spawn begin
            while !app.operations.closing[]
                enabled = app.updates.monitor_enabled[]
                if enabled
                    permission[] = app.updates.permission_generation[]
                    manual[] = app.updates.manual_generation[]
                    sequence[] = Threads.atomic_add!(app.updates.background_sequence, UInt64(1)) + UInt64(1)
                    checking[] = true
                    check = checker(root)
                    checking[] = false
                    result = BackgroundUpdateResult(permission[], manual[], sequence[], check)
                    app.updates.monitor_enabled[] && !app.operations.closing[] && enqueue_event!(app, TaskEvent(:update_checked, result))
                end
                timedwait(() -> app.operations.closing[] || app.updates.monitor_enabled[] != enabled, interval_seconds; pollint=0.5)
            end
        end
        app.updates.monitor = task
        Threads.@spawn begin
            wait(task; throw=false)
            if istaskfailed(task) && checking[]
                failure = BackgroundMonitorFailure(task, permission[], manual[], sequence[])
                enqueue_event!(app, TaskEvent(:update_checked, failure))
            end
            nothing
        end
    end
    return app.updates.monitor
end
