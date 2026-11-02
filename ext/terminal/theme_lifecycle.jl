# The terminal host owns calls into this controller; timer and file workers only enqueue events.
public ThemeLifecycle, theme_lifecycle_start!, theme_lifecycle_input!, theme_lifecycle_poll!
public theme_lifecycle_selection!, theme_lifecycle_close!, theme_lifecycle_ready, theme_lifecycle_rebind!

Base.@kwdef mutable struct ThemeLifecycle{O,S,C}
    runtime::ThemeRuntime
    output::O
    schedule::S = native_theme_timer
    cancel::C = native_theme_cancel
    queries::Union{Nothing,TerminalColorQueries} = nothing
    watcher::Union{Nothing,ThemeFileWatch} = nothing
    last_colors::Union{Nothing,TerminalColors} = nothing
    reported_scheme::Union{Nothing,Symbol} = nothing
    colorfgbg::String = get(ENV,"COLORFGBG","")
    latest_query::UInt64 = UInt64(0)
    started::Bool = false
    closed::Bool = false
    auto_sync::Bool = false
    in_memory::Bool = false
    dirty::Bool = false
    last_error::String = ""
end

"""Write a real terminal control request, returning an explicit failure instead of a pretend update."""
function theme_lifecycle_write!(lifecycle::ThemeLifecycle,bytes::AbstractString)
    write(lifecycle.output,bytes)
    flush(lifecycle.output)
    nothing
end

"""Refresh system/automatic ownership, preserving direct palettes and valid fixed-theme previews."""
function theme_lifecycle_reapply!(lifecycle::ThemeLifecycle)
    runtime = lifecycle.runtime
    catalog = runtime.catalog
    old_name = runtime.owner_name
    name = theme_resolve_setting(runtime.committed,catalog.appearance)
    selected = something(name,"system")
    if !lifecycle.in_memory && (selected=="system" || selected!=old_name)
        loaded = theme_load(catalog,selected)
        if loaded.ok
            runtime.active = loaded.theme
            runtime.requested = runtime.committed
            runtime.owner_name = selected
            runtime.last_error = ""
            theme_sync_native!(runtime)
            lifecycle.dirty = true
            watcher = lifecycle.watcher
            if !isnothing(watcher)
                theme_file_watch!(watcher)
            end
        else
            lifecycle.last_error = loaded.reason
            runtime.active = theme_system_palette(catalog)
            runtime.requested = runtime.committed
            runtime.owner_name = "system"
            runtime.last_error = loaded.reason
            theme_sync_native!(runtime)
            lifecycle.dirty = true
            watcher = lifecycle.watcher
            if !isnothing(watcher)
                theme_file_watch!(watcher)
            end
        end
    end
    nothing
end

"""Merge partial replies with previous values; unchanged timeouts do not rebuild the UI."""
function theme_lifecycle_colors!(lifecycle::ThemeLifecycle,colors::TerminalColors)
    if !lifecycle.closed
        previous = lifecycle.last_colors
        old = isnothing(previous) ? TerminalColors() : previous
        next = TerminalColors(;foreground=isnothing(colors.foreground) ? old.foreground : colors.foreground,
            background=isnothing(colors.background) ? old.background : colors.background,
            palette=isempty(colors.palette) ? copy(old.palette) : copy(colors.palette))
        if isnothing(previous) || next!=previous
            lifecycle.last_colors = next
            catalog = lifecycle.runtime.catalog
            catalog.foreground = next.foreground
            catalog.background = next.background
            catalog.palette = copy(next.palette)
            catalog.pending = false
            catalog.appearance = theme_detect_appearance(;background=catalog.background,foreground=catalog.foreground,
                reported=lifecycle.reported_scheme,colorfgbg=lifecycle.colorfgbg)
            theme_lifecycle_reapply!(lifecycle)
            lifecycle.dirty = true
        end
    end
    nothing
end

"""Enable terminal scheme notifications only for system or automatic-pair selections."""
function theme_lifecycle_notifications!(lifecycle::ThemeLifecycle,enabled::Bool)
    if lifecycle.auto_sync!=enabled
        sent = theme_lifecycle_attempt(() -> theme_lifecycle_write!(lifecycle,enabled ? "\e[?2031h" : "\e[?2031l"))
        if sent.ok
            lifecycle.auto_sync = enabled
        else
            lifecycle.last_error = sent.reason
        end
    end
    nothing
end

"""Start the live query and custom-theme watcher once, before rendering a color-dependent header."""
function theme_lifecycle_start!(lifecycle::ThemeLifecycle)
    if !lifecycle.started && !lifecycle.closed
        lifecycle.started = true
        lifecycle.runtime.catalog.pending = true
        queries = TerminalColorQueries(;write=bytes -> theme_lifecycle_write!(lifecycle,bytes),
            deliver=(_,_,colors) -> theme_lifecycle_colors!(lifecycle,colors),schedule=lifecycle.schedule,cancel=lifecycle.cancel)
        lifecycle.queries = queries
        lifecycle.watcher = ThemeFileWatch(;runtime=lifecycle.runtime,schedule=lifecycle.schedule,cancel=lifecycle.cancel)
        theme_lifecycle_selection!(lifecycle;query=false)
        theme_lifecycle_reapply!(lifecycle)
        lifecycle.latest_query = terminal_color_query!(queries)
    end
    lifecycle
end

"""Call after a real selection commits or a direct palette is installed; previews keep their own watcher."""
function theme_lifecycle_selection!(lifecycle::ThemeLifecycle;query::Bool=true,in_memory::Bool=false,preview::Bool=false)
    if lifecycle.started && !lifecycle.closed
        runtime = lifecycle.runtime
        if !preview
            lifecycle.in_memory = in_memory
            name = theme_resolve_setting(runtime.committed,runtime.catalog.appearance)
            automatic = !isnothing(theme_auto_setting(runtime.committed)) || something(name,"system")=="system"
            theme_lifecycle_notifications!(lifecycle,!in_memory && automatic)
        end
        watcher = lifecycle.watcher
        if !isnothing(watcher)
            theme_file_watch!(watcher)
        end
        queries = lifecycle.queries
        if query && !preview && !isnothing(queries)
            lifecycle.latest_query = terminal_color_query!(queries)
        end
    end
    nothing
end

"""Consume complete terminal control sequences before ordinary keys, preserving all unrelated input."""
function theme_lifecycle_input!(lifecycle::ThemeLifecycle,data::AbstractString)
    consumed = false
    if lifecycle.started && !lifecycle.closed
        queries = lifecycle.queries
        consumed = !isnothing(queries) && terminal_color_input!(queries,data)
        if !consumed
            scheme = terminal_color_scheme(data)
            if !isnothing(scheme)
                consumed = true
                if lifecycle.auto_sync
                    lifecycle.reported_scheme = scheme
                    catalog = lifecycle.runtime.catalog
                    previous = catalog.appearance
                    catalog.appearance = theme_detect_appearance(;background=catalog.background,foreground=catalog.foreground,
                        reported=scheme,colorfgbg=lifecycle.colorfgbg)
                    if catalog.appearance!=previous
                        theme_lifecycle_reapply!(lifecycle)
                    end
                    if !isnothing(queries)
                        lifecycle.latest_query = terminal_color_query!(queries)
                    end
                end
            end
        end
    end
    consumed
end

"""Poll queued timers/file events on the UI thread and report whether a redraw is genuinely needed."""
function theme_lifecycle_poll!(lifecycle::ThemeLifecycle)
    if lifecycle.started && !lifecycle.closed
        queries = lifecycle.queries
        if !isnothing(queries)
            terminal_color_poll!(queries)
            if !isempty(queries.last_error)
                lifecycle.last_error = queries.last_error
            end
        end
        watcher = lifecycle.watcher
        if !isnothing(watcher)
            lifecycle.dirty = theme_file_poll!(watcher) || lifecycle.dirty
        end
    end
    changed = lifecycle.dirty
    lifecycle.dirty = false
    changed
end

"""Readiness means the current query applied initial colors or timed out, never that colors were invented."""
function theme_lifecycle_ready(lifecycle::ThemeLifecycle)
    queries = lifecycle.queries
    lifecycle.closed || lifecycle.started && !isnothing(queries) && terminal_color_settled(queries,lifecycle.latest_query)
end

"""Re-enable an existing subscription after the host restarts its terminal, without duplicating callbacks."""
function theme_lifecycle_rebind!(lifecycle::ThemeLifecycle)
    if lifecycle.started && !lifecycle.closed && lifecycle.auto_sync
        sent = theme_lifecycle_attempt(() -> theme_lifecycle_write!(lifecycle,"\e[?2031h"))
        lifecycle.last_error = sent.reason
    end
    nothing
end

"""Disable notifications, close every file handle/timer, and reject queued or late work after teardown."""
function theme_lifecycle_close!(lifecycle::ThemeLifecycle)
    if !lifecycle.closed
        theme_lifecycle_notifications!(lifecycle,false)
        lifecycle.closed = true
        lifecycle.dirty = false
        queries = lifecycle.queries
        if !isnothing(queries)
            terminal_color_close!(queries)
        end
        watcher = lifecycle.watcher
        if !isnothing(watcher)
            theme_file_close!(watcher)
        end
    end
    nothing
end
