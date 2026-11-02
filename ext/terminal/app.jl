"""Format a factual workspace label, optionally using a branch already resolved before a transition."""
function directory_label(dir::AbstractString=pwd(); branch=startup_host_branch(dir))
    home = homedir()
    label = dir == home ? "~" : startswith(dir, joinpath(home, "")) ? replace(dir, home => "~"; count=1) : String(dir)
    isnothing(branch) || isempty(branch) || (label *= " ($branch)")
    label
end


App(kernel::Kernel=default_kernel(); kwargs...) = App(Session(kernel); kwargs...)

function App(session::Session; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY, theme_fallback::AbstractString="system")
    kernel = session.kernel
    registry = registry === DEFAULT_PROVIDER_REGISTRY ? ProviderRegistry(; descriptors=provider_descriptors(registry)) : registry
    JuliaForever2.restore_model_catalogs!(registry,JuliaForever2.FileModelStore(settings_dir))
    input = TextInput(; label="", style=pi_style(:text), cursor_style=Tachikoma.Style(; fg=Tachikoma.ColorRGB(36, 41, 49), bg=Tachikoma.ColorRGB(255, 255, 255)))
    app = App(session, input, :chat, false, 1, false, false, TaskQueue(; capacity=typemax(Int)), "Ready", 0, Rect(),
        directory_label(), CommandSpec[], Dict{Symbol,Vector{EventHandler}}(),
        SettingsState(settings_dir, registry), TranscriptState(), OperationState(), MenusState(), TerminalArchive(settings_dir))
    isnothing(component(kernel, :input)) && install!(kernel, ComponentSpec(:input, default_input!))
    isnothing(component(kernel, :view)) && install!(kernel, ComponentSpec(:view, default_view!))
    app.settings.workspace = working_directory(session)
    app.directory = directory_label(app.settings.workspace)
    register_default_commands!(app)
    lock(session.runtime.execution_lock) do
        lock(session.conversation.lock) do
            initialize_archive!(app.archive, app.session)
            JuliaForever2.bind_history_journal!(app.session, app.archive)
        end
    end
    register_event_handler!(app, :changelog_done, changelog_finished!)
    register_event_handler!(app, :bug_report_done, bug_report_finished!)
    register_event_handler!(app, :session_action_done, session_action_finished!)
    register_event_handler!(app, :logout_done, logout_finished!)
    register_event_handler!(app, :tree_callback, tree_callback_finished!)
    register_event_handler!(app, :selector_callback, selector_callback_finished!)
    register_event_handler!(app, :resume_progress, resume_progress_finished!)
    register_event_handler!(app, :resume_load_done, resume_load_finished!)
    register_event_handler!(app, :resume_mutation_done, resume_mutation_finished!)
    register_event_handler!(app, :model_catalog_done, model_catalog_finished!)
    register_event_handler!(app, :model_command_catalog_done, model_command_catalog_finished!)
    register_event_handler!(app, :model_configuration_done, model_configuration_finished!)
    register_event_handler!(app, :model_preferences_done, model_preferences_finished!)
    register_event_handler!(app, :queued_input_delivered, pending_input_delivered!)
    register_event_handler!(app, :completion_ready, chat_completion_ready!)
    register_event_handler!(app, :user_shell_stream, user_shell_stream_received!)
    register_event_handler!(app, :user_shell_done, user_shell_done!)
    register_event_handler!(app, :terminal_selection_expired, terminal_selection_expired!)
    register_event_handler!(app, :terminal_scrollbar_expired, terminal_scrollbar_expired!)
    register_event_handler!(app, :turn, operation_finished!)
    register_event_handler!(app, :evaluation, operation_finished!)
    register_event_handler!(app, :compaction_done, operation_finished!)
    register_event_handler!(app, :auth_url, auth_url_received!)
    register_event_handler!(app, :auth_done, auth_finished!)
    register_event_handler!(app, :response_progress, response_progress_received!)
    register_event_handler!(app, :response_committed, response_committed!)
    refresh_settings!(app)
    load_menu_preferences!(app)
    load_model_preferences!(app)
    initialize_theme_controls!(app; fallback=theme_fallback)
    initialize_startup_host!(app)
    initialize_notice_settings!(app)
    chat_completion_state!(app)
    return app
end


function terminal_app(; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    provider = configured_provider(settings_dir; registry)
    kernel = isnothing(provider) ? Kernel() : default_kernel(provider)
    app = App(Session(kernel; owns_kernel=true); settings_dir, registry)
    restore_default_model!(app)
    maybe_warn_anthropic_subscription!(app)
    if isnothing(provider) && (isnothing(app.menus.project_trust) || !app.menus.project_trust.pending)
        app.page = :settings
        app.status = "Configured provider is unavailable. Choose a provider."
    end
    return app
end

function JuliaForever2.main(; settings_dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    app = terminal_app(; settings_dir, registry)
    capture_was_enabled = Tachikoma.raw_capture_enabled()
    capture_was_enabled || Tachikoma.enable_raw_capture!()
    terminal_task = Task(() -> Tachikoma.app(app; default_bindings=false))
    schedule(terminal_task)
    wait(terminal_task; throw=false)
    capture_was_enabled || Tachikoma.disable_raw_capture!()
    finish_shutdown!(app)
    close(app.session.kernel)
    if istaskfailed(terminal_task)
        errors = Base.current_exceptions(terminal_task)
        error(isempty(errors) ? "Terminal application failed" : sprint(showerror, last(errors).exception))
    end
    return 0
end

"""Attach the actual terminal sink for clipboard, color queries and graphics capability checks."""
function Tachikoma.init!(app::App, terminal::Tachikoma.Terminal)
    app.settings.terminal = terminal
    initialize_terminal_presentation!(app,terminal)
    initialize_terminal_theme!(app, terminal)
    maybe_warn_anthropic_subscription!(app)
    nothing
end
