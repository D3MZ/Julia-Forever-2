# Private terminal settings only; credentials and model-default stores have separate owners.
const TERMINAL_PREFERENCE_LOCK = ReentrantLock()
const TERMINAL_PREFERENCE_OWNERS = Dict{String,ReentrantLock}()

"""Coordinate native writers of the same settings path, including the separate theme owner."""
function terminal_preference_lock(path::AbstractString)
    lock(TERMINAL_PREFERENCE_LOCK) do
        get!(ReentrantLock, TERMINAL_PREFERENCE_OWNERS, abspath(path))
    end
end

"""Contain filesystem or effect failures without claiming a completed transaction."""
function preference_attempt(operation)
    worker = Task(operation)
    schedule(worker)
    wait(worker; throw=false)
    if istaskfailed(worker)
        errors = Base.current_exceptions(worker; backtrace=false)
        (ok=false, reason=isempty(errors) ? "Terminal preference operation failed" : sprint(showerror, first(errors).exception), value=nothing)
    else
        (ok=true, reason="", value=fetch(worker))
    end
end

"""Reject directories and symlink aliases rather than following them into another private store."""
function preference_path_allowed(path::String)
    valid = basename(path) == "terminal-settings.json" && !isdir(path)
    current = path
    while valid && dirname(current) != current
        valid = !islink(current)
        current = dirname(current)
    end
    valid
end

function preference_read(path::String)
    if !preference_path_allowed(path)
        (ok=false, reason="Terminal settings path is a directory, symlink, or unrelated store", raw=nothing, data=Dict{String,Any}())
    elseif isfile(path) && filesize(path) > 1024 * 1024
        (ok=false, reason="Terminal settings exceed the size limit; not overwritten", raw=nothing, data=Dict{String,Any}())
    else
        raw = isfile(path) ? read(path, String) : nothing
        data = isnothing(raw) ? Dict{String,Any}() : JSON.isvalidjson(raw) ? JSON.parse(raw) : nothing
        data isa AbstractDict ? (ok=true, reason="", raw, data=Dict{String,Any}(data)) :
            (ok=false, reason="Existing terminal settings are invalid JSON; not overwritten", raw, data=Dict{String,Any}())
    end
end

struct TerminalPreferencePlan
    path::String
    before::Union{Nothing,String}
    after::String
    old::Dict{String,Any}
    new::Dict{String,Any}
end

"""Prepare a validated immutable disk snapshot while retaining every unrelated preference."""
function prepare_terminal_preference(path::AbstractString, name::AbstractString, value::AbstractString; validate=(name,value)->true)
    destination = abspath(path)
    attempt = preference_attempt() do
        lock(terminal_preference_lock(destination)) do
            current = preference_read(destination)
            if !current.ok
                (ok=false, reason=current.reason, plan=nothing)
            elseif !validate(String(name), String(value))
                (ok=false, reason="Unsupported terminal setting or value", plan=nothing)
            else
                updated = copy(current.data)
                updated[String(name)] = String(value)
                (ok=true, reason="", plan=TerminalPreferencePlan(destination, current.raw, JSON.json(updated), current.data, updated))
            end
        end
    end
    attempt.ok ? attempt.value : (ok=false, reason=attempt.reason, plan=nothing)
end

"""Replace only an unchanged owned snapshot and verify the actual bytes after atomic rename."""
function preference_replace(plan::TerminalPreferencePlan, before, after; before_replace=Returns(nothing))
    current = preference_read(plan.path)
    if !current.ok || current.raw != before
        (ok=false, reason=current.ok ? "Terminal settings changed concurrently; refresh before retrying" : current.reason, state=:conflict)
    else
        directory = dirname(plan.path)
        mkpath(directory; mode=0o700)
        mktemp(directory) do temporary, io
            chmod(temporary, 0o600)
            isnothing(after) || write(io, after)
            flush(io)
            if Sys.isunix() && ccall(:fsync, Cint, (Cint,), fd(io)) != 0
                error("Failed to sync terminal preferences")
            end
            close(io)
            before_replace()
            latest = preference_read(plan.path)
            if !latest.ok || latest.raw != before
                (ok=false, reason="Terminal settings changed before commit; not overwritten", state=:conflict)
            else
                if isnothing(after)
                    isfile(plan.path) && rm(plan.path)
                else
                    Base.Filesystem.rename(temporary, plan.path)
                end
                JuliaForever2.timeline_sync_directory(plan.path)
                readback = preference_read(plan.path)
                readback.ok && readback.raw == after ? (ok=true, reason="", state=:verified) :
                    (ok=false, reason="Terminal settings readback did not match; outcome uncertain", state=:uncertain)
            end
        end
    end
end

preference_effect_ok(value) = true
preference_effect_ok(value::Bool) = value
preference_effect_ok(value::NamedTuple) = get(value, :ok, true) === true
preference_effect_reason(value) = "Runtime setting effect rejected the change"
preference_effect_reason(value::NamedTuple) = string(get(value, :reason, get(value, :text, "Runtime setting effect rejected the change")))

function preference_rollback(plan, original_reason, restore)
    disk = preference_attempt(() -> preference_replace(plan, plan.after, plan.before))
    runtime = preference_attempt(restore)
    disk_ok = disk.ok && disk.value.ok
    runtime_ok = runtime.ok && preference_effect_ok(runtime.value)
    recovered = disk_ok && runtime_ok
    (ok=false, reason=original_reason * (recovered ? "; prior setting restored" : "; rollback incomplete; reconcile before retrying"),
        state=recovered ? :rolled_back : :uncertain, disk_committed=!disk_ok, runtime_committed=!runtime_ok)
end

"""Persist and read back first, then commit the runtime effect; compensate explicit effect failures."""
function commit_terminal_preference!(plan::TerminalPreferencePlan; apply=Returns(nothing), restore=Returns(nothing), active=Returns(true), before_replace=Returns(nothing))
    attempt = preference_attempt() do
        lock(terminal_preference_lock(plan.path)) do
            if !active()
                (ok=false, reason="Terminal settings update cancelled", state=:cancelled, disk_committed=false, runtime_committed=false)
            else
                disk = preference_replace(plan, plan.before, plan.after; before_replace)
                if !disk.ok
                    (ok=false, reason=disk.reason, state=disk.state, disk_committed=disk.state == :uncertain, runtime_committed=false)
                elseif !active()
                    preference_rollback(plan, "Terminal settings update cancelled", restore)
                else
                    effect = preference_attempt(apply)
                    if effect.ok && preference_effect_ok(effect.value)
                        readback = preference_read(plan.path)
                        if readback.ok && readback.raw == plan.after
                            (ok=true, reason="", state=:verified, disk_committed=true, runtime_committed=true)
                        else
                            (ok=false, reason="Terminal settings changed during runtime application; reconcile before retrying", state=:uncertain, disk_committed=true, runtime_committed=true)
                        end
                    else
                        reason = effect.ok ? preference_effect_reason(effect.value) : effect.reason
                        preference_rollback(plan, reason, restore)
                    end
                end
            end
        end
    end
    attempt.ok ? attempt.value : (ok=false, reason=attempt.reason * "; inspect current setting before retrying", state=:uncertain, disk_committed=true, runtime_committed=false)
end
