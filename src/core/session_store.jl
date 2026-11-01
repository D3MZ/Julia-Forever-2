import JSON

"""Store resumable Julia session history and workspace without retaining runtime objects."""
mutable struct SessionStore
    directory::String
    lock::ReentrantLock
    revision::UInt64
    SessionStore(directory::AbstractString) = new(abspath(directory), ReentrantLock(), UInt64(0))
end

function session_file(store::SessionStore, name::Union{Symbol,AbstractString})
    label = String(name)::String
    if isempty(label) || label in (".", "..") || any(character -> character in ('/', '\\', '\0'), label)
        return nothing
    end
    return joinpath(store.directory, string(label, ".json"))
end

function session_record(session::Session)
    return lock(session.runtime.execution_lock) do
        messages = [Dict("role" => String(message.role), "content" => message.content,
            "kind" => String(message.kind)) for message in history_snapshot(session).messages]
        return (messages=messages, directory=working_directory(session), lineage=session_lineage(session))
    end
end

"""Atomically persist a session's messages and workspace, excluding transient execution metadata."""
function save_session!(store::SessionStore, name::Union{Symbol,AbstractString}, session::Session)
    path = session_file(store, name)
    isnothing(path) && return (ok=false, reason="Invalid session name")
    record = session_record(session)
    lineage = record.lineage
    data = Dict("format" => "JuliaForever2.session", "version" => 2, "name" => String(name),
        "working_directory" => record.directory, "messages" => record.messages,
        "lineage" => Dict("id" => string(lineage.id),
            "parent_id" => isnothing(lineage.parent_id) ? nothing : string(lineage.parent_id),
            "root_id" => string(lineage.root_id)))
    serialized = JSON.json(data) * "\n"
    lock(store.lock) do
        mkpath(store.directory; mode=0o700)
        mktemp(store.directory) do temporary, output
            chmod(temporary, 0o600)
            write(output, serialized)
            close(output)
            Base.Filesystem.rename(temporary, path)
        end
        store.revision += UInt64(1)
    end
    return (ok=true, reason="")
end

function saved_session_record(store::SessionStore, name::Union{Symbol,AbstractString})
    path = session_file(store, name)
    (isnothing(path) || !isfile(path)) && return nothing
    data = JSON.parsefile(path)
    get(data, "format", nothing) == "JuliaForever2.session" || error("Invalid session format: $name")
    version = get(data, "version", nothing)
    version in (1, 2) || error("Unsupported session version: $name")
    get(data, "name", nothing) == String(name) || error("Session identity mismatch: $name")
    entries = data["messages"]
    entries isa AbstractVector || error("Invalid session messages: $name")
    messages = Message[Message(Symbol(entry["role"]), String(entry["content"]), Symbol(entry["kind"]))
        for entry in entries]
    lineage = if version == 1
        id = uuid5(UUID("075b3f8b-fd8a-400f-9aeb-7c9970270ab2"), joinpath(store.directory, String(name)))
        (id=id, parent_id=nothing, root_id=id)
    else
        identity = data["lineage"]
        id = UUID(String(identity["id"]))
        ancestor = get(identity, "parent_id", nothing)
        (id=id, parent_id=isnothing(ancestor) ? nothing : UUID(String(ancestor)),
            root_id=UUID(String(identity["root_id"])))
    end
    return (messages=messages, directory=String(data["working_directory"]), lineage)
end

"""Read a saved session's persistent identity without restoring its execution environment."""
function session_lineage(store::SessionStore, name::Union{Symbol,AbstractString})
    record = saved_session_record(store, name)
    return isnothing(record) ? nothing : record.lineage
end

"""Return stored descendants of a session identity in deterministic session-name order."""
function session_descendants(store::SessionStore, ancestor::UUID; include_self=false)
    relationships = Dict{UUID,Tuple{String,Union{Nothing,UUID}}}()
    for name in session_names(store)
        lineage = session_lineage(store, name)
        isnothing(lineage) || (relationships[lineage.id] = (name, lineage.parent_id))
    end
    reachable = Set{UUID}([ancestor])
    names = String[]
    changed = true
    passes = 0
    while changed
        changed = false
        for (id, (name, parent)) in relationships
            if !(id in reachable) && !isnothing(parent) && parent in reachable
                push!(reachable, id)
                push!(names, name)
                changed = true
            end
        end
        passes += 1
        if changed && passes == 8
            # Long parent chains otherwise require repeatedly scanning every session.
            # Keep the inexpensive scan for the common shallow lineage trees.
            children = Dict{UUID,Vector{Tuple{UUID,String}}}()
            for (id, (name, parent)) in relationships
                isnothing(parent) && continue
                push!(get!(Vector{Tuple{UUID,String}}, children, parent), (id, name))
            end
            queue = collect(reachable)
            next = 1
            while next <= length(queue)
                parent = queue[next]
                next += 1
                descendants = get(children, parent, nothing)
                isnothing(descendants) && continue
                for (id, name) in descendants
                    id in reachable && continue
                    push!(reachable, id)
                    push!(queue, id)
                    push!(names, name)
                end
            end
            break
        end
    end
    if include_self && haskey(relationships, ancestor)
        push!(names, relationships[ancestor][1])
    end
    return sort!(names)
end

session_descendants(store::SessionStore, ancestor::Session; kwargs...) =
    session_descendants(store, session_lineage(ancestor).id; kwargs...)

function session_descendants(store::SessionStore, name::Union{Symbol,AbstractString}; kwargs...)
    lineage = session_lineage(store, name)
    return isnothing(lineage) ? String[] : session_descendants(store, lineage.id; kwargs...)
end

"""Resume a saved session using a caller-owned Julia kernel or independent agent definition."""
function load_session(store::SessionStore, name::Union{Symbol,AbstractString},
        target::Union{Kernel,AgentDefinition}; kwargs...)
    record = saved_session_record(store, name)
    isnothing(record) && return nothing
    return Session(target; messages=record.messages, working_directory=record.directory,
        id=record.lineage.id, parent_id=record.lineage.parent_id, root_id=record.lineage.root_id, kwargs...)
end

"""Publish replaceable native session persistence as an ordinary Julia plugin service."""
function session_store_plugin(directory; name=:session_store, service_name=:session_store, factory=SessionStore)
    contract = Symbol(service_name)
    return PluginSpec(name, context -> provide!(context, contract, Base.invokelatest(factory, directory));
        provides=[contract])
end
