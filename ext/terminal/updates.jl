"""Check upstream without blocking the terminal event loop."""
function start_update_check!(app::App; root::AbstractString=installation_root())
    if !app.updates.checking && !app.operations.closing[]
        app.updates.checking = true
        app.status = "Checking for updates..."
        task = Threads.@spawn check_for_updates(root)
        notify_completion!(app, :update_checked, task, task)
    end
    return nothing
end

"""Install the revision already discovered by the updater."""
function start_update_install!(app::App; installer=apply_update!)
    check = app.updates.latest
    if !isnothing(check) && update_available(check) && !app.updates.installing && !app.operations.closing[]
        app.updates.installing = true
        app.status = "Installing update..."
        task = Threads.@spawn installer(check)
        notify_completion!(app, :update_installed, task, task)
    end
    return nothing
end

"""Publish an update notification, or automatically install when opted in."""
function update_checked!(app::App, check::UpdateCheck; installer=apply_update!)
    app.updates.checking = false
    app.updates.latest = check
    if update_available(check)
        if app.updates.automatic || app.updates.requested_install
            start_update_install!(app; installer)
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

function update_check_finished!(app::App, value)
    check = value isa Task ? fetch(value) : value
    update_checked!(app, check)
    return nothing
end

function update_installed!(app::App, task::Task)
    result = fetch(task)
    app.updates.installing = false
    if result == :installed
        app.updates.latest = nothing
        app.status = "Update installed. Restart to use it."
    elseif result == :compile_failed
        app.status = "Update downloaded but Julia precompilation did not complete."
    elseif result == :merge_failed
        app.status = "Git could not fast-forward the installation."
    else
        app.status = "Already up to date."
    end
    return nothing
end

"""Toggle whether updates are installed automatically after detection."""
function toggle_auto_updates!(app::App; installer=apply_update!)
    app.updates.automatic = set_auto_updates!(app.settings.directory, !app.updates.automatic)
    app.status = app.updates.automatic ? "Automatic updates enabled." : "Automatic updates disabled."
    if app.updates.automatic
        start_update_install!(app; installer)
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

"""Check on startup and hourly while the terminal is running."""
function start_update_monitor!(app::App; root::AbstractString=installation_root(), interval_seconds::Real=3600)
    if ispath(joinpath(root, ".git"))
        app.updates.monitor = Threads.@spawn begin
            while !app.operations.closing[]
                check = check_for_updates(root)
                enqueue_event!(app, TaskEvent(:update_checked, check))
                timedwait(() -> app.operations.closing[], interval_seconds; pollint=0.5)
            end
        end
    end
    return app.updates.monitor
end
