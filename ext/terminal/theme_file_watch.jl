# Watch the directory, not the inode: atomic editor replacement must keep the subscription alive.
using FileWatching
public ThemeFileWatch, theme_file_watch!, theme_file_poll!, theme_file_close!, theme_file_event!

const THEME_FILE_DEBOUNCE_SECONDS = 0.1

Base.@kwdef mutable struct ThemeFileWatch{S,C}
    runtime::ThemeRuntime
    schedule::S = native_theme_timer
    cancel::C = native_theme_cancel
    monitor::Union{Nothing,FileWatching.FolderMonitor} = nothing
    worker::Union{Nothing,Task} = nothing
    timer::Any = nothing
    generation::UInt64 = UInt64(0)
    revision::UInt64 = UInt64(0)
    name::String = ""
    path::String = ""
    lock::ReentrantLock = ReentrantLock()
    events::Vector{Tuple{Symbol,UInt64,UInt64,String}} = Tuple{Symbol,UInt64,UInt64,String}[]
    last_error::String = ""
    reloads::Int = 0
    observed_events::UInt64 = UInt64(0)
end

"""Cancel debounce and close the real directory handle before replacing or disposing a watcher."""
function theme_file_close!(watcher::ThemeFileWatch)
    watcher.generation += 1
    watcher.revision += 1
    watcher.cancel(watcher.timer)
    watcher.timer = nothing
    monitor = watcher.monitor
    if !isnothing(monitor)
        close(monitor)
    end
    watcher.monitor = nothing
    worker = watcher.worker
    if !isnothing(worker)
        wait(worker;throw=false)
    end
    watcher.worker = nothing
    lock(watcher.lock) do
        empty!(watcher.events)
    end
    watcher.name = ""
    watcher.path = ""
    nothing
end

"""Debounce at the actual file event, queuing only reload work and never mutating UI state."""
function theme_file_event!(watcher::ThemeFileWatch,filename::AbstractString,generation::UInt64=watcher.generation)
    lock(watcher.lock) do
        if generation==watcher.generation
            watcher.observed_events += 1
            if !isempty(watcher.name) && (isempty(filename) || filename==watcher.name*".json")
                watcher.revision += 1
                watcher.cancel(watcher.timer)
                token = watcher.revision
                watcher.timer = watcher.schedule(THEME_FILE_DEBOUNCE_SECONDS,() -> lock(watcher.lock) do
                    push!(watcher.events,(:reload,generation,token,""))
                end)
            end
        end
    end
    nothing
end

"""Subscribe only to the selected, successfully loaded custom theme's real parent directory."""
function theme_file_watch!(watcher::ThemeFileWatch)
    theme_file_close!(watcher)
    watcher.last_error = ""
    runtime = watcher.runtime
    name = theme_resolve_setting(runtime.requested,runtime.catalog.appearance)
    source = runtime.active.source
    path = isnothing(name) ? "" : joinpath(runtime.catalog.directory,name*".json")
    eligible = !isnothing(name) && !(name in ("dark","light","system")) && !isempty(runtime.catalog.directory) &&
        !isnothing(source) && abspath(source)==abspath(path) && isfile(path) && !islink(path) &&
        isdir(runtime.catalog.directory) && !islink(runtime.catalog.directory)
    if eligible
        opened = theme_lifecycle_attempt(() -> FileWatching.FolderMonitor(runtime.catalog.directory))
        watcher.last_error = opened.reason
        if opened.ok
            monitor = opened.value::FileWatching.FolderMonitor
            watcher.monitor = monitor
            watcher.name = name
            watcher.path = path
            generation = watcher.generation
            watcher.worker = @async while isopen(monitor)
                event = wait(monitor)
                theme_file_event!(watcher,first(event),generation)
            end
        end
    end
    (watching=!isnothing(watcher.monitor),reason=watcher.last_error)
end

"""Ignore stale reloads and keep the last valid palette when the file is missing or temporarily invalid."""
function theme_file_reload!(watcher::ThemeFileWatch,generation::UInt64,revision::UInt64)
    runtime = watcher.runtime
    expected = theme_resolve_setting(runtime.requested,runtime.catalog.appearance)
    current = generation==watcher.generation && revision==watcher.revision && expected==watcher.name &&
        !isempty(watcher.path) && runtime.active.source==watcher.path
    reloaded = false
    if current
        attempted = theme_lifecycle_attempt(() -> theme_read_path(watcher.path;mode=runtime.catalog.mode,bold=runtime.catalog.bold))
        result = attempted.ok ? attempted.value : ThemeLoadResult(;reason=attempted.reason)
        watcher.last_error = result.reason
        if result.ok && generation==watcher.generation && revision==watcher.revision
            runtime.catalog.registered[watcher.name] = result.theme
            runtime.active = result.theme
            theme_sync_native!(runtime)
            watcher.reloads += 1
            reloaded = true
        end
    end
    reloaded
end

"""Drain file events and debounce exactly 100 ms after the latest matching change."""
function theme_file_poll!(watcher::ThemeFileWatch)
    events = lock(watcher.lock) do
        values = copy(watcher.events)
        empty!(watcher.events)
        values
    end
    changed = false
    for (kind,generation,revision,filename) in events
        if generation==watcher.generation
            if kind==:reload && revision==watcher.revision
                watcher.timer = nothing
                changed = theme_file_reload!(watcher,generation,revision) || changed
            end
        end
    end
    worker = watcher.worker
    if !isnothing(worker) && istaskdone(worker) && istaskfailed(worker) && !isnothing(watcher.monitor)
        watcher.last_error = sprint(showerror,TaskFailedException(worker))
        theme_file_close!(watcher)
    end
    changed
end
