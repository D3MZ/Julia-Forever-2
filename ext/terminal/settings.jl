function refresh_settings!(app::App)
    snapshot = provider_settings_snapshot(app.settings.directory; registry=app.settings.registry)
    app.settings.providers = ProviderDescriptor[item.descriptor for item in snapshot]
    app.settings.labels = [item.descriptor.label * (isempty(item.status) ? "" : " — " * item.status) for item in snapshot]
    app.selected = isempty(app.settings.providers) ? 1 : clamp(app.selected, 1, length(app.settings.providers))
    return app
end

function provider_selection(app::App)
    identity = provider_selection_snapshot(app.session.kernel).id
    selected = findfirst(descriptor -> descriptor.id == identity, app.settings.providers)
    return isnothing(selected) ? 1 : selected
end


function start_sign_in!(app::App, provider::Symbol; action=nothing)
    if !app.busy && !app.operations.closing[]
        descriptor = provider_descriptor(app.settings.registry, provider)
        selected = isnothing(action) ? (isnothing(descriptor) ? nothing : descriptor.auth) : action
        authenticate!(app, provider, selected)
    end
end

authenticate!(app::App, provider, ::Nothing) = nothing

function authenticate!(app::App, provider, action)
    flow = AuthFlow()
    app.settings.auth_flow = flow
    app.settings.auth_url = ""
    app.settings.auth_provider = provider
    app.busy = true
    app.page = :auth
    app.status = "Opening browser for sign-in…"
    task = Threads.@spawn begin
        announce = url -> enqueue_event!(app, TaskEvent(:auth_url, (flow, url)))
        Base.invokelatest(action, flow, provider, app.settings.directory; announce)
    end
    app.settings.auth_task = task
    notify_completion!(app, :auth_done, task, (flow, task); cleanup=() -> close(flow))
    task
end
function auth_url_received!(app::App, value)
    flow, url = value
    if app.settings.auth_flow === flow && active_auth(flow)
        app.settings.auth_url = url
        app.status = "Complete sign-in in your browser."
    end
    return nothing
end

function auth_finished!(app::App, value)
    flow, task = value
    if app.settings.auth_flow === flow
        authenticated!(app, flow, task)
    end
    nothing
end

function authenticated!(app::App, flow, task)
    app.busy = false
    app.settings.auth_flow = nothing
    app.settings.auth_task = nothing
    app.page == :auth && (app.page = :settings)
    app.settings.auth_url = ""
    result = fetch(task)
    if !active_auth(flow)
        app.status = "Sign-in cancelled."
    else
        app.status = result.reason
        if result.ok
            selected = JuliaForever2.select_provider!(app.session.kernel, app.settings.auth_provider; dir=app.settings.directory, registry=app.settings.registry)
            selected.ok || (app.status = selected.reason)
        end
    end
    refresh_settings!(app)
    return nothing
end


function select_provider!(app::App)
    if !isempty(app.settings.providers)
        select!(app, app.settings.providers[app.selected])
    end
    nothing
end

function select!(app::App, descriptor::ProviderDescriptor)
    result = JuliaForever2.select_provider!(app.session.kernel, descriptor.id; dir=app.settings.directory, registry=app.settings.registry)
    if result.ok
        app.status = descriptor.label * (isnothing(descriptor.auth) ? " selected" : " selected — sign in from settings with s")
        app.page = :chat
    else
        app.status = result.reason
    end
    nothing
end
remember_provider!(app::App, provider::Symbol) = save_provider!(app.settings.directory, provider)

settings_top(area::Rect) = max(area.y, area.y + area.height - 11)

function settings_window(app::App, area::Rect)
    top = settings_top(area)
    bottom = area.y + area.height - 3
    count = min(length(app.settings.providers), max(0, bottom - top - 4))
    first = max(1, min(app.selected - count + 1, length(app.settings.providers) - count + 1))
    return top, bottom, first, count
end


function page_view!(app::App, ::Val{:auth}, frame::Frame)
    area, buf = frame.area, frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    drawline!(buf, x + 1, y, w - 2, "◆ JULIA FOREVER", :accent)
    descriptor = provider_descriptor(app.settings.registry, app.settings.auth_provider)
    name = isnothing(descriptor) ? string(app.settings.auth_provider) : descriptor.label
    drawline!(buf, x + 1, y + 2, w - 2, "Sign in to " * name, :accent)
    drawline!(buf, x + 1, y + 4, w - 2, "Complete authorization in your browser.", :text)
    drawline!(buf, x + 1, y + 6, w - 2, "If it did not open, copy this URL:", :text_dim)
    chars = collect(app.settings.auth_url)
    for (i, part) in enumerate(Iterators.take(Iterators.partition(chars, max(1, w - 2)), max(0, h - 10)))
        drawline!(buf, x + 1, y + 6 + i, w - 2, String(collect(part)), :text)
    end
    drawline!(buf, x + 1, y + h - 1, w - 2, "esc cancel", :text_dim)
    return
end

function page_view!(app::App, ::Val{:settings}, frame::Frame)
    area, buf = frame.area, frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    top, bottom, first, count = settings_window(app, area)
    drawline!(buf, x, top, w, repeat("─", w), :border)
    top + 1 < bottom && drawline!(buf, x, top + 1, w, "> Provider", :text)
    labels = app.settings.labels
    for offset in 0:(count - 1)
        index = first + offset
        selected = app.selected == index
        drawline!(buf, x, top + 3 + offset, w, (selected ? "→ " : "  ") * labels[index], selected ? :accent : :text)
    end
    bottom - 1 > top + 1 && drawline!(buf, x, bottom - 1, w, "  ↑↓ select · Enter use · s sign in · Esc back", :text_dim)
    drawline!(buf, x, bottom, w, repeat("─", w), :border)
    drawline!(buf, x, y + h - 2, w, app.directory, :text_dim)
    draw_footer!(buf, x, y + h - 1, w, app)
    return
end

function page_input!(app::App, ::Val{:auth}, event::KeyEvent)
    flow = app.settings.auth_flow
    if event.key == :escape && !isnothing(flow)
        cancel_auth!(flow)
        app.status = "Cancelling sign-in…"
        app.page = :settings
    end
    return nothing
end

function page_input!(app::App, ::Val{:settings}, event::KeyEvent)
    if event.key == :escape
        app.page = :chat
    elseif event.key in (:up, :down) && !isempty(app.settings.providers)
        app.selected = mod1(app.selected + (event.key == :up ? -1 : 1), length(app.settings.providers))
    elseif event.key == :char && event.char == 's' && !isempty(app.settings.providers)
        descriptor = app.settings.providers[app.selected]
        isnothing(descriptor.auth) || start_sign_in!(app, descriptor.id; action=descriptor.auth)
    elseif event.key == :enter
        select_provider!(app)
    end
    return nothing
end

function page_mouse!(app::App, ::Val{:settings}, event::MouseEvent)
    area = app.area
    top, _, first, count = settings_window(app, area)
    offset = event.y - top - 3
    if 0 <= offset < count
        app.selected = first + offset
        update!(app, KeyEvent(:enter))
    end
    return nothing
end
