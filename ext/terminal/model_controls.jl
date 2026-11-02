"""Return one exact terminal packet without inventing unavailable modifier state."""
function menu_packet(event::KeyEvent, raw::AbstractVector{UInt8})
    if event.action == Tachikoma.key_release
        ""
    elseif !isempty(raw)
        String(copy(raw))
    elseif event.key == :char
        string(event.char)
    elseif event.key == :ctrl && 'a' <= event.char <= 'z'
        string(Char(Int(event.char) - Int('a') + 1))
    else
        get(Dict(:up => "\e[A", :down => "\e[B", :left => "\e[D", :right => "\e[C",
            :pageup => "\e[5~", :pagedown => "\e[6~", :home => "\e[H", :end_key => "\e[F",
            :delete => "\e[3~", :backspace => "\x7f", :enter => "\r", :escape => "\e",
            :ctrl_c => "\x03", :tab => "\t"), event.key, "")
    end
end

"""Filter only known credential-owning providers or explicitly selected native providers."""
function configured_model_providers(app::App; kernel::Kernel=app.session.kernel)
    active = provider_selection_snapshot(kernel).id
    ids = Symbol[]
    for descriptor in provider_descriptors(app.settings.registry)
        configured = isnothing(descriptor.auth) || (descriptor.id == active && !(descriptor.id in (:chatgpt, :openrouter)))
        if descriptor.id in (:chatgpt, :openrouter)
            configured |= !isnothing(JuliaForever2.load_credentials(app.settings.directory, descriptor.id))
            configured |= descriptor.id == :openrouter && !isempty(get(ENV, "OPENROUTER_API_KEY", ""))
        end
        configured = api_key_configured(descriptor.auth,app.settings.directory,descriptor.id,configured)
        configured && push!(ids, descriptor.id)
    end
    ids
end

model_settings_path(app::App) = joinpath(app.settings.directory, "model-settings.json")

"""Load only non-secret, bounded, validated model preferences owned by this application."""
function load_model_preferences!(app::App)
    path = model_settings_path(app)
    if isfile(path) && !islink(path) && filesize(path) <= 1024 * 1024
        text = read(path, String)
        data = JuliaForever2.parse_json(text)
        if data isa AbstractDict
            app.menus.model_preferences_digest = JuliaForever2.timeline_digest(text)
            for name in ("defaultModel", "defaultThinking", "enabledModels", "thinkingDefaults")
                value = get(data, name, nothing)
                valid = name in ("defaultModel", "defaultThinking") ? value isa String : name == "enabledModels" ?
                    value isa AbstractVector && all(item -> item isa String, value) :
                    value isa AbstractDict && all(pair -> first(pair) isa String && last(pair) isa String, value)
                if valid
                    app.menus.model_preferences[name] = deepcopy(value)
                end
            end
        end
    end
    enabled = get(app.menus.model_preferences, "enabledModels", nothing)
    app.menus.enabled_models = isnothing(enabled) ? nothing : String.(enabled)
    nothing
end

"""A successful save means both an atomic replacement and an exact server-local readback."""
function save_model_preferences!(app::App, preferences::AbstractDict)
    directory = app.settings.directory
    mkpath(directory; mode=0o700)
    path = model_settings_path(app)
    if islink(path)
        error("Refusing to replace symlinked model preferences")
    end
    text = JSON.json(preferences) * "\n"
    expected = app.menus.model_preferences_digest
    JuliaForever2.timeline_replace_file(path, text, expected)
    if read(path, String) != text
        error("Model preference readback did not match the saved value")
    end
    app.menus.model_preferences = deepcopy(preferences)
    app.menus.model_preferences_digest = JuliaForever2.timeline_digest(text)
    nothing
end

"""Take a cached model snapshot without authenticating or making an inference request."""
function menu_model_snapshot(app::App; configured=true, kernel::Kernel=app.session.kernel)
    models = provider_models(app.settings.registry)
    ids = configured ? configured_model_providers(app; kernel) : Symbol[]
    configured ? filter(model -> model.provider in ids, models) : models
end

function current_menu_model(app::App)
    with_component(app.session.kernel, :provider; fallback=:unconfigured) do provider
        identity = JuliaForever2.provider_model_identity(provider)
        isempty(identity.model_id) ? nothing : string(identity.provider_id, "/", identity.model_id)
    end
end

"""Create native selectors; cached and refreshed catalogs remain distinct actual states."""
function open_model_controls!(app::App, name::AbstractString; refresh=true,query="")
    if name == "model"
        models = menu_model_snapshot(app)
        enabled = app.menus.enabled_models
        scoped = isnothing(enabled) ? SelectorModel[] : [selector_model(model) for key in enabled for model in models if string(model.provider, "/", model.id) == key]
        menu = ModelMenu(models; scoped, current=current_menu_model(app), default=get(app.menus.model_preferences, "defaultModel", nothing),query)
        app.menus.model_menu = menu
        refresh && refresh_menu_catalogs!(app, menu)
    elseif name == "scoped-models"
        menu = ScopedModelMenu(menu_model_snapshot(app; configured=false); enabled=app.menus.enabled_models, status="Refreshing model catalogs…")
        app.menus.scoped_menu = menu
        refresh && refresh_menu_catalogs!(app, menu)
    elseif name == "thinking"
        open_thinking_control!(app)
    end
    nothing
end

"""Refresh only metadata in a copied registry; a closed selector cannot install late results."""
function refresh_menu_catalogs!(app::App, menu)
    descriptors = provider_descriptors(app.settings.registry)
    registry = ProviderRegistry(; descriptors=copy(descriptors))
    ids = configured_model_providers(app)
    store=JuliaForever2.snapshot_model_cache(app.settings.directory,descriptors)
    task = Threads.@spawn begin
        errors = String[]
        for id in ids
            descriptor = provider_descriptor(registry, id)
            if id in (:chatgpt, :openrouter, :codex) && !isnothing(descriptor) && descriptor.create isa JuliaForever2.ProviderFactory
                result = JuliaForever2.refresh_pi_model_catalog!(registry, id)
                result.ok || push!(errors, String(id))
            end
        end
        (; registry, errors, originals=descriptors,store)
    end
    notify_completion!(app, :model_catalog_done, task, (menu, task))
    nothing
end

function model_catalog_finished!(app::App, value)
    menu, task = value
    active = model_controls_active(app, menu)
    if active
        if istaskfailed(task)
            if menu isa ModelMenu
                model_menu_refresh!(menu, menu.models; reason="Metadata request failed; existing catalog retained")
            else
                scoped_models_status!(menu, "Could not refresh model catalogs; showing cached models.", :error)
            end
        else
            result = fetch(task)
            for original in result.originals
                current = provider_descriptor(app.settings.registry, original.id)
                updated = provider_descriptor(result.registry, original.id)
                if current === original && updated !== original && !isnothing(updated)
                    JuliaForever2.register_provider!(app.settings.registry, updated)
                    saved=JuliaForever2.cache_installed_catalog!(get(result,:store,nothing),updated)
                    saved.ok || push!(result.errors,String(updated.id)*" (cache not saved)")
                end
            end
            if menu isa ModelMenu
                model_menu_refresh!(menu, selector_model.(menu_model_snapshot(app)); errors=result.errors)
            else
                scoped_models_update!(menu, selector_model.(menu_model_snapshot(app; configured=false)))
                scoped_models_status!(menu, isempty(result.errors) ? "Model catalogs refreshed." : "Could not refresh model catalogs; showing cached models.", isempty(result.errors) ? :success : :error)
            end
        end
    end
    nothing
end

"""Cancellation returns to the parent list without committing a model or default."""
function close_model_controls!(app::App)
    menu = app.menus.model_menu
    isnothing(menu) || model_menu_dispose!(menu)
    if isempty(app.menus.parents)
        app.page = :chat
    else
        path, cursor, query = pop!(app.menus.parents)
        app.menus.path = path
        app.menus.cursor = cursor
        Tachikoma.set_text!(app.menus.search, query)
    end
    nothing
end

function model_controls_input!(app::App, event::KeyEvent, raw)
    packet = menu_packet(event, raw)
    name = first(app.menus.path)
    model, scoped, thinking = app.menus.model_menu, app.menus.scoped_menu, app.menus.thinking_menu
    if name == "model" && !isnothing(model)
        action = model_menu_input!(model, packet)
        if action.kind in (:select, :default)
            configuration_action!(app, selector_key(action.value); save_default=action.kind == :default)
        elseif action.kind == :cancel
            close_model_controls!(app)
        end
    elseif name == "scoped-models" && !isnothing(scoped)
        action = scoped_models_input!(scoped, packet)
        if action.kind == :change
            app.menus.enabled_models = deepcopy(action.value)
        elseif action.kind == :persist
            preferences = deepcopy(app.menus.model_preferences)
            preferences["enabledModels"] = deepcopy(action.value)
            save_scoped_preferences!(app, preferences, scoped)
        elseif action.kind == :cancel
            close_model_controls!(app)
        end
    elseif name == "thinking" && !isnothing(thinking)
        thinking_input!(thinking, packet)
    end
    nothing
end

function model_controls_lines(app::App, width)
    name = first(app.menus.path)
    model, scoped, thinking = app.menus.model_menu, app.menus.scoped_menu, app.menus.thinking_menu
    if name == "model" && !isnothing(model)
        model_menu_lines(model, width)
    elseif name == "scoped-models" && !isnothing(scoped)
        scoped_models_lines(scoped, width)
    elseif name == "thinking" && !isnothing(thinking)
        thinking_lines(thinking, width)
    else
        Vector{Tachikoma.Span}[]
    end
end

"""Prepare model state without touching the active executor, credentials, or defaults."""
function configuration_action!(app::App, key::AbstractString; thinking=nothing, save_default=false, default_kind=:model)
    if app.busy || app.operations.closing[]
        app.status = "Finish or cancel the active operation first."
        isnothing(app.menus.model_menu) || (app.menus.model_menu.closed = false)
    else
        app.menus.configuration_path = copy(app.menus.path)
        app.menus.configuration_generation = app.menus.generation
        app.menus.configuration_page = app.page
        handle = JuliaForever2.submit_managed!(app.session, app.session, ui_context(app)) do context
            lock(app.session.runtime.execution_lock) do
                configure_terminal_model!(app, key, thinking, save_default, default_kind, context)
            end
        end
        track_operation!(app, handle, :model_configuration_done, "Updating model…")
    end
    nothing
end

function configure_terminal_model!(app, key, thinking, save_default, default_kind, context)
    if save_default && default_kind == :model_thinking
        save_model_thinking_default!(app, key, thinking, context)
    else
    kernel = app.session.kernel
    lease = JuliaForever2.acquire!(kernel, :provider)
    task = Task() do
        configure_retained_model!(app, key, thinking, save_default, default_kind, context, lease)
    end
    schedule(task)
    wait(task; throw=false)
    isnothing(lease) || JuliaForever2.release!(lease)
    fetch(task)
    end
end

function configure_retained_model!(app, key, thinking, save_default, default_kind, context, lease)
    parts = configuration_model_parts(app.settings.registry,key)
    if length(parts) != 2 || any(isempty, parts)
        JuliaForever2.ExecutionResult(false, "Choose an exact provider/model identifier.")
    elseif cancelled(context)
        JuliaForever2.ExecutionResult(false, "Model change cancelled.")
    else
        kernel = app.session.kernel
        entry = isnothing(lease) ? nothing : lease.entry
        current = isnothing(lease) ? nothing : lease.value
        defaults = get(app.menus.model_preferences, "thinkingDefaults", Dict{String,Any}())
        selected_thinking = isnothing(thinking) ? get(defaults, String(key), get(app.menus.model_preferences, "defaultThinking", nothing)) : thinking
        model = JuliaForever2.provider_model(app.settings.registry, Symbol(parts[1]), parts[2])
        selected_thinking = !isnothing(model) && isnothing(thinking) && selected_thinking isa AbstractString ? JuliaForever2.model_clamp_thinking_level(model, selected_thinking) : selected_thinking
        prepared = JuliaForever2.prepare_model_configuration(current, app.settings.registry;
            provider_id=Symbol(parts[1]), model_id=parts[2], thinking_level=selected_thinking,
            directory=app.settings.directory, allow_provider_change=true)
        if !prepared.ok
            JuliaForever2.ExecutionResult(false, prepared.reason)
        else
            timeline = ensure_archive!(app.archive, app.session)
            snapshot = lock(timeline.lock) do
                (rows=[JuliaForever2.timeline_header(timeline); JuliaForever2.timeline_entries(timeline)],
                    leaf=timeline.leaf, digest=timeline.disk_digest, count=length(timeline.entries))
            end
            candidate = JuliaForever2.timeline_from_rows(snapshot.rows; leaf=snapshot.leaf)
            JuliaForever2.timeline_append!(candidate, Dict("type" => "model_change", "provider" => String(prepared.model.provider), "modelId" => prepared.model.id))
            JuliaForever2.timeline_append!(candidate, Dict("type" => "thinking_level_change", "thinkingLevel" => prepared.thinking_level))
            result = commit_model_configuration!(kernel, entry, prepared.provider, timeline, candidate, context, snapshot)
            if result.ok && save_default
                preferences = deepcopy(app.menus.model_preferences)
                model_key = string(prepared.model.provider, "/", prepared.model.id)
                if default_kind == :model
                    preferences["defaultModel"] = model_key
                end
                if default_kind == :thinking
                    preferences["defaultThinking"] = prepared.thinking_level
                elseif default_kind == :model_thinking
                    defaults = deepcopy(get(preferences, "thinkingDefaults", Dict{String,Any}()))
                    defaults[model_key] = prepared.thinking_level
                    preferences["thinkingDefaults"] = defaults
                end
                save = Task(() -> save_model_preferences!(app, preferences))
                schedule(save)
                wait(save; throw=false)
                if istaskfailed(save)
                    result = (ok=false, reason="Model changed, but saving its default failed; current selection is active.")
                else
                    fetch(save)
                end
            end
            JuliaForever2.ExecutionResult(result.ok, result.ok ? string("Model: ", prepared.model.provider, "/", prepared.model.id, " · ", prepared.thinking_level) : result.reason)
        end
    end
end

"""Reject stale generations before the durable change, then install without an intervening writer."""
function commit_model_configuration!(kernel, expected, provider, timeline, candidate, context, expected_timeline)
    pending = JuliaForever2.ComponentEntry[]
    spec = ComponentSpec(:provider, provider)
    result = lock(timeline.lock) do
        lock(kernel.lock) do
            reason = JuliaForever2.conflict(kernel, spec, expected)
            if cancelled(context)
                (ok=false, reason="Model change cancelled.")
            elseif !isempty(reason)
                (ok=false, reason)
            elseif timeline.leaf != expected_timeline.leaf || timeline.disk_digest != expected_timeline.digest || length(timeline.entries) != expected_timeline.count
                (ok=false, reason="Session changed during model preparation; no model change was applied.")
            else
                JuliaForever2.timeline_commit!(timeline, candidate.entries, candidate.leaf)
                owned_spec = retained_provider_spec(kernel, expected, provider)
                JuliaForever2.replace!(kernel, owned_spec, pending)
            end
        end
    end
    JuliaForever2.clean_entries!(kernel, pending)
    result
end

function model_configuration_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        app.operations.active = nothing
        app.busy = false
        result = session_action_result(handle)
        app.status = result.text
        result.ok && maybe_warn_anthropic_subscription!(app)
        owns_view = app.menus.configuration_page == :pi_menu && app.page == :pi_menu && app.menus.path == app.menus.configuration_path && app.menus.generation == app.menus.configuration_generation
        if result.ok && owns_view
            close_model_controls!(app)
        elseif !result.ok && owns_view && !isnothing(app.menus.model_menu)
            app.menus.model_menu.closed = false
            app.menus.model_menu.error = result.text
        end
    end
    nothing
end

"""Use the selected model's actual support map and its actually configured reasoning level."""
function open_thinking_control!(app::App)
    state = with_component(app.session.kernel, :provider; fallback=:unconfigured) do provider
        model = JuliaForever2.selected_model(provider)
        current = JuliaForever2.current_thinking_level(provider)
        (; model, current)
    end
    model = state.model
    if isnothing(model)
        app.status = "Select a model before changing its thinking level."
        app.page = :chat
    else
        key = string(model.provider, "/", model.id)
        defaults = get(app.menus.model_preferences, "thinkingDefaults", Dict{String,Any}())
        app.menus.thinking_menu = thinking_menu(something(state.current, ""), JuliaForever2.model_supported_thinking_levels(model);
            on_select=level -> configuration_action!(app, key; thinking=level),
            on_cancel=() -> close_model_controls!(app),
            on_default=level -> configuration_action!(app, key; thinking=level, save_default=true, default_kind=:thinking),
            default_level=get(app.menus.model_preferences, "defaultThinking", nothing))
    end
    nothing
end

"""Apply an actually persisted default only if that exact model is available locally."""
function restore_default_model!(app::App)
    selected = get(app.menus.model_preferences, "defaultModel", nothing)
    if selected isa AbstractString
        defaults = get(app.menus.model_preferences, "thinkingDefaults", Dict{String,Any}())
        result = configure_terminal_model!(app, selected, get(defaults, selected, nothing), false, :model, ExecutionContext())
        result.ok || (app.status = result.text)
    end
    nothing
end

model_controls_active(app::App, menu::ModelMenu) = app.page == :pi_menu && menu === app.menus.model_menu && app.menus.path == ["model"] && !menu.closed
model_controls_active(app::App, menu::ScopedModelMenu) = app.page == :pi_menu && menu === app.menus.scoped_menu && app.menus.path == ["scoped-models"]

"""Keep save failures within managed ownership and retain unsaved edits for retry."""
function save_scoped_preferences!(app::App, preferences, menu::ScopedModelMenu)
    if app.busy || app.operations.closing[]
        app.status = "Finish or cancel the active operation first."
    else
        app.menus.scoped_save_owner = menu
        handle = JuliaForever2.submit_managed!(app.session, app.session, ui_context(app)) do context
            lock(app.session.runtime.execution_lock) do
                if cancelled(context)
                    JuliaForever2.ExecutionResult(false, "Model preference save cancelled.", menu)
                else
                    save_model_preferences!(app, preferences)
                    JuliaForever2.ExecutionResult(true, "Model preferences saved.", menu)
                end
            end
        end
        track_operation!(app, handle, :model_preferences_done, "Saving model preferences…")
    end
    nothing
end

function model_preferences_finished!(app::App, handle::TaskHandle)
    if app.operations.active === handle
        app.operations.active = nothing
        app.busy = false
        result = session_action_result(handle)
        menu = app.menus.scoped_menu
        app.status = result.text
        if !isnothing(menu) && menu === app.menus.scoped_save_owner
            if result.ok && result.value === menu
                scoped_models_saved!(menu)
            elseif !result.ok
                scoped_models_status!(menu, result.text, :error)
            end
        end
    end
    nothing
end

"""Native selectors must never inherit the old metadata-menu hitboxes."""
function model_controls_mouse!(app::App, event::MouseEvent)
    area = app.area
    name = first(app.menus.path)
    menu = name == "model" ? app.menus.model_menu : name == "scoped-models" ? app.menus.scoped_menu : app.menus.thinking_menu
    result=nothing
    if !isnothing(menu)
        lines = model_controls_lines(app, area.width)
        geometry=startup_editor_geometry(app,lines)
        local_row=startup_editor_row(app,event,geometry)
        action = event.action == Tachikoma.mouse_press ? :press : event.action == Tachikoma.mouse_release ? :click : :move
        button = event.button == Tachikoma.mouse_left ? :left : :other
        if menu isa ThinkingMenu
            delta = terminal_viewport_wheel(app,event)
            action = delta != 0 ? :wheel : action == :click && isnothing(menu.pressed) ? :move : action
            result=thinking_mouse!(menu, event.x - area.x, local_row; action, button, wheel_delta=delta)
            event.action==Tachikoma.mouse_release && local_row<0 && (menu.pressed=nothing)
        else
            result=model_selector_mouse!(menu, event.x - area.x, local_row; action, button,
                width=area.width, height=length(lines))
        end
    end
    !isnothing(result) && get(result,:handled,false)
end

"""Cycle the configured available snapshot, retaining explicit scope order and unavailable IDs."""
function cycle_terminal_model!(app::App, direction::Int)
    available = menu_model_snapshot(app)
    enabled = app.menus.enabled_models
    catalog = menu_model_snapshot(app; configured=false)
    has_scope = !isnothing(enabled) && any(model -> string(model.provider, "/", model.id) in enabled, catalog)
    choices = has_scope ? [model for key in enabled for model in available if string(model.provider, "/", model.id) == key] : available
    if length(choices) <= 1
        app.status = has_scope ? "Only one model in scope" : "Only one model available"
    else
        current = current_menu_model(app)
        index = findfirst(model -> string(model.provider, "/", model.id) == current, choices)
        selected = choices[mod1(something(index, 1) + direction, length(choices))]
        configuration_action!(app, string(selected.provider, "/", selected.id))
    end
    nothing
end

function cycle_terminal_thinking!(app::App)
    state = with_component(app.session.kernel, :provider; fallback=:unconfigured) do provider
        (model=JuliaForever2.selected_model(provider), current=JuliaForever2.current_thinking_level(provider))
    end
    if isnothing(state.model) || !JuliaForever2.model_reasoning(state.model)
        app.status = "Current model does not support thinking"
    else
        levels = JuliaForever2.model_supported_thinking_levels(state.model)
        index = findfirst(==(state.current), levels)
        if !isempty(levels)
            level = levels[mod1(something(index, 0) + 1, length(levels))]
            configuration_action!(app, string(state.model.provider, "/", state.model.id); thinking=level)
        end
    end
    nothing
end

"""Keep borrowed same-provider resources alive until the replacement generation retires."""
function retained_provider_spec(kernel, expected, provider)
    if !isnothing(expected) && JuliaForever2.provider_id(expected.spec.value) == JuliaForever2.provider_id(provider)
        lease = JuliaForever2.retain!(kernel, expected)
        ComponentSpec(:provider, provider; cleanup=value -> JuliaForever2.release!(lease))
    else
        ComponentSpec(:provider, provider)
    end
end

function install_retained_provider!(kernel, provider)
    pending = JuliaForever2.ComponentEntry[]
    result = lock(kernel.lock) do
        previous = get(kernel.entries, :provider, nothing)
        ordinary = ComponentSpec(:provider, provider)
        reason = JuliaForever2.conflict(kernel, ordinary, previous)
        if isempty(reason)
            JuliaForever2.replace!(kernel, retained_provider_spec(kernel, previous, provider), pending)
        else
            (ok=false, reason)
        end
    end
    JuliaForever2.clean_entries!(kernel, pending)
    result
end

"""Change a per-model persisted default without selecting a model or altering active history."""
function save_model_thinking_default!(app::App, key::AbstractString, level, context::ExecutionContext)
    parts = configuration_model_parts(app.settings.registry,key)
    if cancelled(context)
        JuliaForever2.ExecutionResult(false, "Default update cancelled.")
    elseif length(parts) != 2 || any(isempty, parts)
        JuliaForever2.ExecutionResult(false, "Choose an exact provider/model identifier.")
    else
        model = JuliaForever2.provider_model(app.settings.registry, Symbol(parts[1]), parts[2])
        if isnothing(model) || !(isnothing(level) || level in JuliaForever2.model_supported_thinking_levels(model))
            JuliaForever2.ExecutionResult(false, "Default thinking level is not supported by the catalog model.")
        else
            preferences = deepcopy(app.menus.model_preferences)
            defaults = deepcopy(get(preferences, "thinkingDefaults", Dict{String,Any}()))
            if isnothing(level)
                delete!(defaults, String(key))
            else
                defaults[String(key)] = String(level)
            end
            preferences["thinkingDefaults"] = defaults
            save_model_preferences!(app, preferences)
            JuliaForever2.ExecutionResult(true, isnothing(level) ? "Model default override removed." : "Model default saved.")
        end
    end
end

"""Resolve stored provider/model keys using the longest registered provider id, including URL-derived ids."""
function configuration_model_parts(registry::ProviderRegistry,key::AbstractString)
    descriptors=sort(provider_descriptors(registry);by=descriptor->length(String(descriptor.id)),rev=true)
    index=findfirst(descriptor->startswith(key,String(descriptor.id)*"/"),descriptors)
    if isnothing(index)
        split(key,"/";limit=2)
    else
        provider=String(descriptors[index].id)
        [provider,String(SubString(key,nextind(key,lastindex(provider),2)))]
    end
end
