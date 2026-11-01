function directory_label(dir::AbstractString=pwd())
    home = homedir()
    label = dir == home ? "~" : startswith(dir, joinpath(home, "")) ? replace(dir, home => "~"; count=1) : String(dir)
    git = Sys.which("git")
    if !isnothing(git)
        branch = readchomp(pipeline(ignorestatus(`$git -C $dir symbolic-ref --quiet --short HEAD`); stderr=devnull))
        isempty(branch) || (label *= " ($branch)")
    end
    return label
end

App(kernel::Kernel=default_kernel(); kwargs...) = App(Session(kernel); kwargs...)

function App(session::Session; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    kernel = session.kernel
    input = TextInput(; label="", style=pi_style(:text), cursor_style=Tachikoma.Style(; fg=Tachikoma.ColorRGB(36, 41, 49), bg=Tachikoma.ColorRGB(255, 255, 255)))
    app = App(session, input, :chat, false, 1, false, false, TaskQueue(; capacity=typemax(Int)), "Ready", 0, Rect(),
        directory_label(), CommandSpec[], Dict{Symbol,Vector{EventHandler}}(),
        SettingsState(settings_dir, registry), UpdateState(settings_dir), TranscriptState(), OperationState())
    isnothing(component(kernel, :input)) && install!(kernel, ComponentSpec(:input, default_input!))
    isnothing(component(kernel, :view)) && install!(kernel, ComponentSpec(:view, default_view!))
    register_command!(app, CommandSpec("settings", "Choose a provider", settings_command!))
    register_command!(app, CommandSpec("components", "Inspect installed components", components_command!))
    register_command!(app, CommandSpec("julia", "Run a Julia expression", julia_command!))
    register_command!(app, CommandSpec("clear", "Clear the conversation", clear_command!))
    register_command!(app, CommandSpec("update", "Check or install upstream updates", update_command!))
    register_command!(app, CommandSpec("quit", "Exit", quit_command!))
    register_command!(app, CommandSpec("cancel", "Cancel the active operation", cancel_command!))
    register_event_handler!(app, :turn, operation_finished!)
    register_event_handler!(app, :evaluation, operation_finished!)
    register_event_handler!(app, :auth_url, auth_url_received!)
    register_event_handler!(app, :auth_done, auth_finished!)
    register_event_handler!(app, :update_checked, update_check_finished!)
    register_event_handler!(app, :update_installed, update_installed!)
    register_event_handler!(app, :response_progress, response_progress_received!)
    register_event_handler!(app, :response_committed, response_committed!)
    refresh_settings!(app)
    return app
end


function terminal_app(; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    provider = configured_provider(settings_dir; registry)
    kernel = isnothing(provider) ? Kernel() : default_kernel(provider)
    app = App(kernel; settings_dir, registry)
    if isnothing(provider)
        app.page = :settings
        app.status = "Configured provider is unavailable. Choose a provider."
    end
    return app
end

function JuliaForever2.main(; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    app = terminal_app(; settings_dir, registry)
    start_update_monitor!(app)
    Tachikoma.app(app; default_bindings=false)
    finish_shutdown!(app)
    close(app.session.kernel)
    return 0
end
