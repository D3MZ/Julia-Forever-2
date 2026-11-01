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
    validname(label) ? joinpath(store.directory, string(label, ".json")) : nothing
end
function session_record(session::Session)
    return lock(session.runtime.execution_lock) do
        messages = [Dict("role" => String(message.role), "content" => message.content,
            "kind" => String(message.kind)) for message in history_snapshot(session).messages]
        return (messages=messages, directory=working_directory(session), lineage=session_lineage(session))
    end
end

"""Atomically persist a session's messages and workspace, excluding transient execution metadata."""
save_session!(store::SessionStore, name::Union{Symbol,AbstractString}, session::Session) = persist!(store, name, session, session_file(store, name))
persist!(store::SessionStore, name, session::Session, ::Nothing) = (ok=false, reason="Invalid session name")

function persist!(store::SessionStore, name, session::Session, path::AbstractString)
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
    !isnothing(path) && isfile(path) ? session_record(SessionRecord(JSON.parsefile(path), store, String(name))) : nothing
end

struct SessionRecord{D}
    data::D
    directory::String
    name::String

    function SessionRecord(data::D, store::SessionStore, name::String) where {D}
        validate(SessionRecord, data, name)
        new{D}(data, store.directory, name)
    end
end

function validate(::Type{SessionRecord}, data, name::String)
    if get(data, "format", nothing) != "JuliaForever2.session"
        error("Invalid session format: $name")
    elseif !(get(data, "version", nothing) in (1, 2))
        error("Unsupported session version: $name")
    elseif get(data, "name", nothing) != name
        error("Session identity mismatch: $name")
    elseif !(data["messages"] isa AbstractVector)
        error("Invalid session messages: $name")
    end
    nothing
end

function session_record(record::SessionRecord)
    messages = Message[Message(Symbol(entry["role"]), String(entry["content"]), Symbol(entry["kind"])) for entry in record.data["messages"]]
    (messages, directory=String(record.data["working_directory"]), lineage=session_lineage(record))
end

function session_lineage(record::SessionRecord)
    if record.data["version"] == 1
        id = uuid5(UUID("075b3f8b-fd8a-400f-9aeb-7c9970270ab2"), joinpath(record.directory, record.name))
        (id=id, parent_id=nothing, root_id=id)
    else
        identity = record.data["lineage"]
        ancestor = get(identity, "parent_id", nothing)
        (id=UUID(String(identity["id"])), parent_id=isnothing(ancestor) ? nothing : UUID(String(ancestor)), root_id=UUID(String(identity["root_id"])))
    end
end
function validated_session_lineage(record::SessionRecord)
    # Preserve session_record's field validation without retaining Message objects.
    for entry in record.data["messages"]
        Symbol(entry["role"])
        String(entry["content"])
        Symbol(entry["kind"])
    end
    String(record.data["working_directory"])
    return session_lineage(record)
end

"""Read persisted ancestry without materializing the session's message history."""
function session_lineage(store::SessionStore, name::Union{Symbol,AbstractString})
    path = session_file(store, name)
    isnothing(path) || !isfile(path) ? nothing :
        validated_session_lineage(SessionRecord(JSON.parsefile(path), store, String(name)))
end

"""Return stored descendants of a session identity in deterministic session-name order."""
function session_descendants(store::SessionStore, ancestor::UUID; include_self=false)
    relationships = Dict{UUID,Tuple{String,Union{Nothing,UUID}}}()
    for name in session_names(store)
        lineage = session_lineage(store, name)
        if !isnothing(lineage)
            relationships[lineage.id] = (name, lineage.parent_id)
        end
    end
    reachable = Set{UUID}([ancestor])
    names = descendants!(relationships, reachable)
    if include_self && haskey(relationships, ancestor)
        push!(names, relationships[ancestor][1])
    end
    sort!(names)
end

function descendants!(relationships, reachable)
    names = String[]
    changed = true
    passes = 0
    while changed && passes < 8
        changed = false
        for (id, (name, parent)) in relationships
            if !(id in reachable) && !isnothing(parent) && parent in reachable
                push!(reachable, id)
                push!(names, name)
                changed = true
            end
        end
        passes += 1
    end
    if changed
        descend!(names, reachable, relationships)
    end
    names
end

function descend!(names, reachable, relationships)
    children = Dict{UUID,Vector{Tuple{UUID,String}}}()
    for (id, (name, parent)) in relationships
        if !isnothing(parent)
            push!(get!(Vector{Tuple{UUID,String}}, children, parent), (id, name))
        end
    end
    queue = collect(reachable)
    index = 1
    while index <= length(queue)
        for (id, name) in get(children, queue[index], ())
            if !(id in reachable)
                push!(reachable, id)
                push!(queue, id)
                push!(names, name)
            end
        end
        index += 1
    end
    names
end
session_descendants(store::SessionStore, ancestor::Session; kwargs...) = session_descendants(store, session_lineage(ancestor).id; kwargs...)

function session_descendants(store::SessionStore, name::Union{Symbol,AbstractString}; kwargs...)
    lineage = session_lineage(store, name)
    return isnothing(lineage) ? String[] : session_descendants(store, lineage.id; kwargs...)
end

"""Resume a saved session using a caller-owned Julia kernel or independent agent definition."""
function load_session(store::SessionStore, name::Union{Symbol,AbstractString}, target::Union{Kernel,AgentDefinition}; kwargs...)
    record = saved_session_record(store, name)
    isnothing(record) ? nothing : Session(target, record; kwargs...)
end

Session(target::Union{Kernel,AgentDefinition}, record::NamedTuple; kwargs...) = Session(target; messages=record.messages, working_directory=record.directory, id=record.lineage.id, parent_id=record.lineage.parent_id, root_id=record.lineage.root_id, kwargs...)
"""Publish replaceable native session persistence as an ordinary Julia plugin service."""
function session_store_plugin(directory; name=:session_store, service_name=:session_store, factory=SessionStore)
    contract = Symbol(service_name)
    return PluginSpec(name, context -> provide!(context, contract, Base.invokelatest(factory, directory));
        provides=[contract])
end
