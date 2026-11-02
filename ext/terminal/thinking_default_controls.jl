thinking_defaults_active(app::App) = app.menus.path == ["settings", "model-thinking"]

"""Persist a default and apply it only when its exact model is currently active."""
function persist_thinking_default!(app::App, provider, model, level)
    if app.busy || app.operations.closing[]
        (ok=false, reason="Finish or cancel the active operation first.")
    else
        task = Task(() -> lock(() -> apply_thinking_default!(app, string(provider, "/", model), level), app.session.runtime.execution_lock))
        schedule(task)
        wait(task; throw=false)
        if istaskfailed(task)
            errors = Base.current_exceptions(task)
            reason = isempty(errors) ? "Could not save the model default." : sprint(showerror, last(errors).exception)
            app.status = reason
            (ok=false, reason)
        else
            result = fetch(task)
            app.status = result.text
            (ok=result.ok, reason=result.ok ? "" : result.text)
        end
    end
end

"""Build the complete supported model list from the same configured catalog as the model selector."""
function open_thinking_defaults_control!(app::App)
    runtime = app.menus.theme_runtime
    if !isnothing(runtime)
        models = [ThinkingDefaultsModel(; provider=String(model.provider), id=model.id,
            levels=JuliaForever2.model_supported_thinking_levels(model)) for model in menu_model_snapshot(app)]
        app.menus.thinking_defaults_menu = thinking_defaults_menu(runtime, models;
            current=current_menu_model(app), default_model=get(app.menus.model_preferences, "defaultModel", nothing),
            global_level=get(app.menus.model_preferences, "defaultThinking", "medium"),
            overrides=get(app.menus.model_preferences, "thinkingDefaults", Dict{String,String}()),
            on_set=(provider, model, level) -> persist_thinking_default!(app, provider, model, level),
            on_remove=(provider, model) -> persist_thinking_default!(app, provider, model, nothing),
            on_cancel=summary -> close_theme_control!(app))
    end
    nothing
end

function thinking_defaults_controls_input!(app::App, event::KeyEvent, raw)
    menu = app.menus.thinking_defaults_menu
    isnothing(menu) || thinking_defaults_input!(menu,menu_packet(event,raw);selectors=native_selector_context(app))
    nothing
end

function thinking_defaults_controls_lines(app::App, width)
    menu = app.menus.thinking_defaults_menu
    isnothing(menu) ? SessionDisplayRows() : thinking_defaults_lines(menu,width;selectors=native_selector_context(app))
end


function apply_thinking_default!(app::App, key::AbstractString, level)
    previous = deepcopy(app.menus.model_preferences)
    context = ExecutionContext()
    saved = save_model_thinking_default!(app, key, level, context)
    if saved.ok && current_menu_model(app) == key
        global_level = get(app.menus.model_preferences, "defaultThinking", "medium")
        effective = isnothing(level) ? global_level : level
        parts = split(key, "/"; limit=2)
        model = JuliaForever2.provider_model(app.settings.registry, Symbol(parts[1]), parts[2])
        clamped = isnothing(model) ? effective : JuliaForever2.model_clamp_thinking_level(model, effective)
        applied = configure_terminal_model!(app, key, clamped, false, :thinking, context)
        if !applied.ok
            restored = preference_attempt(() -> save_model_preferences!(app, previous))
            JuliaForever2.ExecutionResult(false, string(applied.text, restored.ok ? "; prior default restored." : "; default rollback failed; reconcile before retrying."))
        else
            app.transcript.display_key = nothing
            applied
        end
    else
        saved
    end
end
