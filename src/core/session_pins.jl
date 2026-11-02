"""Julia-native durable pins for saved sessions; only the store controls metadata."""
const SessionPinEntry = NamedTuple{(:name, :id),Tuple{String,String}}

session_pin_file(store::SessionStore) = joinpath(store.directory, ".session-pins", "pinned.json")

"""Read an ordered pin registry, rejecting invalid or redirected metadata."""
function read_session_pin_entries(store::SessionStore)
    path = session_pin_file(store)
    if islink(dirname(path)) || islink(path)
        error("Refusing symbolic-link session pin metadata")
    elseif isfile(path)
        parse_session_pin_entries(path)
    else
        SessionPinEntry[]
    end
end

"""Parse validated on-disk entries without changing their original order."""
function parse_session_pin_entries(path::AbstractString)
    data = JSON.parsefile(path)
    if !(data isa AbstractDict) || get(data, "format", nothing) != "JuliaForever2.session-pins" ||
            get(data, "version", nothing) != 1 ||
            !(get(data, "sessions", nothing) isa AbstractVector)
        error("Invalid session pin metadata")
    end
    entries = SessionPinEntry[]
    seen = Set{String}()
    for row in data["sessions"]
        if !(row isa AbstractDict)
            error("Invalid session pin entry")
        end
        name = get(row, "name", nothing)
        id = get(row, "id", nothing)
        if !(name isa String && validname(name) && id isa String)
            error("Invalid session pin identity")
        end
        UUID(id)
        if name in seen
            error("Duplicate session pin identity")
        end
        push!(seen, name)
        push!(entries, (name=name, id=id))
    end
    entries
end

"""Publish an entire pin order through a private, atomic JSON-file replacement."""
function write_session_pin_entries!(store::SessionStore, entries::Vector{SessionPinEntry})
    path = session_pin_file(store)
    directory = dirname(path)
    if islink(directory) || islink(path)
        error("Refusing symbolic-link session pin metadata")
    end
    mkpath(directory; mode=0o700)
    data = Dict("format" => "JuliaForever2.session-pins", "version" => 1,
        "sessions" => [Dict("name" => entry.name, "id" => entry.id) for entry in entries])
    mktemp(directory) do temporary, output
        chmod(temporary, 0o600)
        write(output, JSON.json(data) * "\n")
        close(output)
        Base.Filesystem.rename(temporary, path)
    end
    nothing
end

"""Read the immutable saved identity, not the live agent or materialized messages."""
function saved_pin_identity(store::SessionStore, name::String)
    path = session_file(store, name)
    is_saved_profile_file(path) ?
        string(session_lineage(SessionRecord(JSON.parsefile(path), store, name)).id) : nothing
end

"""Optional pin interface; other Julia stores may implement it independently."""
pinned_sessions(store) = nothing
session_pinned(store, name) = false
pin_session!(store, name) = (ok=false, reason="Session pin service is not configured")
unpin_session!(store, name) = (ok=false, reason="Session pin service is not configured")

"""Saved pinned sessions in most-recently-pinned order, excluding archived or stale identities."""
function pinned_sessions(store::SessionStore)
    lock(store.lock) do
        names = String[]
        for entry in read_session_pin_entries(store)
            if !session_archived(store, entry.name) &&
                    saved_pin_identity(store, entry.name) == entry.id
                push!(names, entry.name)
            end
        end
        names
    end
end

session_pinned(store::SessionStore, name::Union{Symbol,AbstractString}) =
    String(name) in pinned_sessions(store)

"""Idempotently pin a saved, unarchived session without reordering an existing pin."""
function pin_session!(store::SessionStore, name::Union{Symbol,AbstractString})
    label = String(name)
    if !validname(label)
        (ok=false, reason="Invalid session name")
    else
        lock(store.lock) do
            if session_archived(store, label)
                (ok=false, reason="Session is archived: $label")
            else
                identity = saved_pin_identity(store, label)
                if isnothing(identity)
                    (ok=false, reason="Session was not saved: $label")
                else
                    entries = read_session_pin_entries(store)
                    if any(entry -> entry.name == label && entry.id == identity, entries)
                        (ok=true, reason="")
                    else
                        updated = SessionPinEntry[(name=label, id=identity)]
                        append!(updated, (entry for entry in entries if entry.name != label))
                        write_session_pin_entries!(store, updated)
                        (ok=true, reason="")
                    end
                end
            end
        end
    end
end

"""Idempotently unpin by saved name; a deleted session requires no restoration."""
function unpin_session!(store::SessionStore, name::Union{Symbol,AbstractString})
    label = String(name)
    if !validname(label)
        (ok=false, reason="Invalid session name")
    else
        lock(store.lock) do
            entries = read_session_pin_entries(store)
            remaining = SessionPinEntry[entry for entry in entries if entry.name != label]
            if length(remaining) != length(entries)
                write_session_pin_entries!(store, remaining)
            end
            (ok=true, reason="")
        end
    end
end
