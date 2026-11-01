import JSON

"""Store resumable Julia session history and workspace without retaining runtime objects."""
struct SessionStore
    directory::String
    SessionStore(directory::AbstractString) = new(abspath(directory))
end

function session_file(store::SessionStore, name::Union{Symbol,AbstractString})
    label = String(name)
    if isempty(label) || label in (".", "..") || any(character -> character in ('/', '\\', '\0'), label)
        return nothing
    end
    return joinpath(store.directory, label * ".json")
end

function session_record(session::Session)
    return lock(session.runtime.execution_lock) do
        messages = [Dict("role" => String(message.role), "content" => message.content,
            "kind" => String(message.kind)) for message in history_snapshot(session).messages]
        return (messages, directory=working_directory(session))
    end
end

"""Atomically persist a session's messages and workspace, excluding transient execution metadata."""
function save_session!(store::SessionStore, name::Union{Symbol,AbstractString}, session::Session)
    path = session_file(store, name)
    isnothing(path) && return (ok=false, reason="Invalid session name")
    record = session_record(session)
    data = Dict("format" => "JuliaForever2.session", "version" => 1,
        "name" => String(name), "working_directory" => record.directory, "messages" => record.messages)
    serialized = JSON.json(data) * "\n"
    mkpath(store.directory; mode=0o700)
    mktemp(store.directory) do temporary, output
        chmod(temporary, 0o600)
        write(output, serialized)
        close(output)
        Base.Filesystem.rename(temporary, path)
    end
    return (ok=true, reason="")
end

function saved_session_record(store::SessionStore, name::Union{Symbol,AbstractString})
    path = session_file(store, name)
    (isnothing(path) || !isfile(path)) && return nothing
    data = JSON.parsefile(path)
    get(data, "format", nothing) == "JuliaForever2.session" || error("Invalid session format: $name")
    get(data, "version", nothing) == 1 || error("Unsupported session version: $name")
    get(data, "name", nothing) == String(name) || error("Session identity mismatch: $name")
    entries = data["messages"]
    entries isa AbstractVector || error("Invalid session messages: $name")
    messages = Message[Message(Symbol(entry["role"]), String(entry["content"]), Symbol(entry["kind"]))
        for entry in entries]
    return (messages, directory=String(data["working_directory"]))
end

"""Resume a saved session using a caller-owned Julia kernel or independent agent definition."""
function load_session(store::SessionStore, name::Union{Symbol,AbstractString},
        target::Union{Kernel,AgentDefinition}; kwargs...)
    record = saved_session_record(store, name)
    isnothing(record) && return nothing
    return Session(target; messages=record.messages, working_directory=record.directory, kwargs...)
end

"""Publish replaceable native session persistence as an ordinary Julia plugin service."""
function session_store_plugin(directory; name=:session_store, service_name=:session_store, factory=SessionStore)
    contract = Symbol(service_name)
    return PluginSpec(name, context -> provide!(context, contract, Base.invokelatest(factory, directory));
        provides=[contract])
end
