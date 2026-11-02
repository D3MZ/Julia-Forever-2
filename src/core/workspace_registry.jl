"""A native, durable registry of user-selected working directories and their display order."""
mutable struct WorkspaceRegistry
    directory::String
    lock::ReentrantLock

    WorkspaceRegistry(directory::AbstractString) = new(abspath(directory), ReentrantLock())
end

WorkspaceRegistry(store::SessionStore) = WorkspaceRegistry(store.directory)
workspace_registry_directory(registry::WorkspaceRegistry) = joinpath(registry.directory, ".workspaces")
workspace_registry_file(registry::WorkspaceRegistry) = joinpath(workspace_registry_directory(registry), "registry.json")

"""Serialize registry reads and writes across Julia processes using an operating-system file lock."""
function with_workspace_registry(operation, registry::WorkspaceRegistry; mutation=false)
    lock(registry.lock) do
        directory = workspace_registry_directory(registry)
        islink(registry.directory) && error("Refusing a symbolic-link workspace store")
        islink(directory) && error("Refusing a symbolic-link workspace registry")
        mkpath(directory; mode=0o700)
        lockpath = joinpath(directory, "registry.lock")
        if islink(lockpath) || (ispath(lockpath) && !isfile(lockpath))
            error("Unsafe workspace registry lock file")
        end
        open(lockpath, "a+") do stream
            chmod(lockpath, 0o600)
            if Sys.isunix()
                ccall(:flock, Cint, (Cint, Cint), Base.fd(stream), 2) == 0 ||
                    error("Cannot acquire workspace registry lock")
            elseif mutation
                error("Cross-process workspace registry writes are not supported on this platform")
            end
            operation()
        end
    end
end

empty_workspace_state() = Dict{String,Any}(
    "format" => "JuliaForever2.workspaces", "version" => 1, "revision" => 0,
    "items" => Any[], "events" => Any[])

"""Validate the entire catalog before exposing it or writing an updated revision."""
function validate_workspace_state(state)
    if !(state isa AbstractDict) ||
            get(state, "format", nothing) != "JuliaForever2.workspaces" ||
            !metadata_version(get(state, "version", nothing), (1,)) ||
            !(get(state, "revision", nothing) isa Integer && metadata_number(state["revision"])) ||
            state["revision"] < 0 ||
            !(get(state, "items", nothing) isa AbstractVector) ||
            !(get(state, "events", nothing) isa AbstractVector)
        error("Invalid native workspace registry")
    end
    identities = Set{String}()
    directories = Set{String}()
    titles = Set{String}()
    for item in state["items"]
        if !(item isa AbstractDict) || !(get(item, "id", nothing) isa String) ||
                !(get(item, "path", nothing) isa String) ||
                !(get(item, "title", nothing) isa String) ||
                !(get(item, "sessionOrder", nothing) isa AbstractVector) ||
                !metadata_number(get(item, "createdAt", nothing)) ||
                !metadata_number(get(item, "updatedAt", nothing))
            error("Invalid native workspace entry")
        end
        UUID(item["id"])
        if !isabspath(item["path"]) || isempty(strip(item["title"])) ||
                item["id"] in identities || item["path"] in directories ||
                item["title"] in titles
            error("Duplicate or invalid native workspace entry")
        end
        push!(identities, item["id"])
        push!(directories, item["path"])
        push!(titles, item["title"])
        order = item["sessionOrder"]
        if !all(id -> id isa String, order) || length(unique(order)) != length(order)
            error("Invalid workspace session order")
        end
        foreach(id -> UUID(id), order)
    end
    previous_revision = nothing
    for event in state["events"]
        if !(event isa AbstractDict) ||
                !(get(event, "revision", nothing) isa Integer && metadata_number(event["revision"])) ||
                !(get(event, "type", nothing) isa String) ||
                event["revision"] < 1 || event["revision"] > state["revision"] ||
                (!isnothing(previous_revision) && event["revision"] != previous_revision + 1)
            error("Invalid native workspace change")
        end
        previous_revision = event["revision"]
    end
    if !isnothing(previous_revision) && previous_revision != state["revision"]
        error("Native workspace journal is incomplete")
    end
    nothing
end

function read_workspace_state(registry::WorkspaceRegistry)
    path = workspace_registry_file(registry)
    if islink(path) || (ispath(path) && !isfile(path))
        error("Unsafe native workspace metadata")
    end
    state = isfile(path) ? JSON.parsefile(path) : empty_workspace_state()
    validate_workspace_state(state)
    state
end

"""Atomically publish one revision; process locking prevents lost updates."""
function write_workspace_state!(registry::WorkspaceRegistry, state)
    validate_workspace_state(state)
    path = workspace_registry_file(registry)
    islink(path) && error("Refusing symbolic-link workspace metadata")
    mktemp(dirname(path)) do temporary, output
        chmod(temporary, 0o600)
        write(output, JSON.json(state) * "\n")
        flush(output)
        close(output)
        Base.Filesystem.rename(temporary, path)
    end
    nothing
end

workspace_failure(reason) = (ok=false, reason=String(reason), changed=false,
    value=nothing, event=nothing)
workspace_success(value, event=nothing) = (ok=true, reason="", changed=!isnothing(event),
    value=value, event=event)

"""Apply a transaction with a bounded replay journal and monotonically increasing revision."""
function workspace_mutate!(mutation, registry::WorkspaceRegistry)
    with_workspace_registry(registry; mutation=true) do
        state = read_workspace_state(registry)
        items = Dict{String,Any}[item for item in state["items"]]
        state["items"] = items
        result = mutation(items)
        if result.changed
            change = result.event
            if isnothing(change)
                error("Changed workspace requires an event")
            else
                state["revision"] += 1
                event = Dict{String,Any}(change)
                event["revision"] = state["revision"]
                push!(state["events"], event)
                if length(state["events"]) > 256
                    state["events"] = state["events"][(end - 255):end]
                end
                write_workspace_state!(registry, state)
            end
        end
        result
    end
end

workspace_find(items, id::AbstractString) =
    findfirst(item -> item["id"] == id, items)

"""Read a detached catalog from disk rather than trusting a process-local cache."""
function workspace_snapshot(registry::WorkspaceRegistry)
    with_workspace_registry(registry) do
        state = read_workspace_state(registry)
        Dict("revision" => state["revision"], "workspaces" => deepcopy(state["items"]))
    end
end

"""Reconnectable snapshot-or-increment feed. A stale cursor receives a full replacement."""
function workspace_changes(registry::WorkspaceRegistry; since=nothing)
    with_workspace_registry(registry) do
        state = read_workspace_state(registry)
        revision = state["revision"]
        events = state["events"]
        earliest = isempty(events) ? revision : first(events)["revision"] - 1
        if isnothing(since) || since < earliest || since > revision
            Dict("type" => "reset", "revision" => revision,
                "workspaces" => deepcopy(state["items"]), "events" => Any[])
        else
            Dict("type" => "delta", "revision" => revision,
                "events" => deepcopy([event for event in events if event["revision"] > since]))
        end
    end
end

"""Fallback for third-party registries that implement only immediate change snapshots."""
workspace_wait_changes(registry; since=nothing, wait_ms=0) = workspace_changes(registry; since)

"""Wait for a workspace revision without holding registry locks between observations."""
function workspace_wait_changes(registry::WorkspaceRegistry; since=nothing, wait_ms::Integer=0)
    result = workspace_changes(registry; since)
    duration = min(max(wait_ms, 0), 10_000)
    if !isnothing(since) && duration > 0 &&
            result["type"] == "delta" && isempty(result["events"])
        deadline = time_ns() + UInt64(duration) * UInt64(1_000_000)
        while result["type"] == "delta" && isempty(result["events"])
            current = time_ns()
            if current >= deadline
                break
            end
            sleep(min(0.25, Float64(deadline - current) / 1_000_000_000))
            result = workspace_changes(registry; since)
        end
    end
    result
end

workspace_title(title) = title isa AbstractString &&
    !isempty(strip(title)) && !occursin('\0', title) ? String(strip(title)) : nothing

"""Register an existing absolute directory; repeated creation preserves its UUID and order."""
function register_workspace!(registry::WorkspaceRegistry, path::AbstractString; title=nothing)
    if isabspath(path) && isdir(path)
        directory = realpath(path)
        register_workspace_label!(registry, directory,
            workspace_title(isnothing(title) ? basename(directory) : title))
    else
        workspace_failure("Workspace requires an existing absolute directory")
    end
end

register_workspace_label!(registry::WorkspaceRegistry, directory::AbstractString, ::Nothing) = workspace_failure("Workspace title must not be blank")

function register_workspace_label!(registry::WorkspaceRegistry, directory::AbstractString, label::String)
    workspace_mutate!(registry) do items::Vector{Dict{String,Any}}
        existing = findfirst(item -> item["path"] == directory, items)
        if !isnothing(existing)
            workspace_success(Dict("workspace" => deepcopy(items[existing]), "created" => false))
        elseif any(item -> item["title"] == label, items)
            workspace_failure("Workspace title is already registered: $label")
        else
            now = time()
            row = Dict{String,Any}("id" => string(uuid4()), "path" => directory,
                "title" => label, "sessionOrder" => String[],
                "createdAt" => now, "updatedAt" => now)
            push!(items, row)
            workspace_success(Dict("workspace" => deepcopy(row), "created" => true),
                Dict("type" => "upsert", "workspace" => deepcopy(row)))
        end
    end
end

"""Rename only the registry entry; sessions and filesystem contents are unaffected."""
rename_workspace_label!(registry::WorkspaceRegistry, id::AbstractString, ::Nothing) = workspace_failure("Workspace title must not be blank")

function rename_workspace_label!(registry::WorkspaceRegistry, id::AbstractString, label::String)
    workspace_mutate!(registry) do items::Vector{Dict{String,Any}}
        index = workspace_find(items, id)
        if isnothing(index)
            workspace_failure("Unknown workspace")
        elseif any(row -> row["title"] == label && row["id"] != id, items)
            workspace_failure("Workspace title is already registered: $label")
        else
            row = items[index]
            if row["title"] == label
                workspace_success(Dict("workspace" => deepcopy(row)))
            else
                row["title"] = label
                row["updatedAt"] = time()
                workspace_success(Dict("workspace" => deepcopy(row)),
                    Dict("type" => "upsert", "workspace" => deepcopy(row)))
            end
        end
    end
end

function rename_workspace!(registry::WorkspaceRegistry, id::AbstractString, title)
    rename_workspace_label!(registry, id, workspace_title(title))
end

"""Remove a registration without deleting the directory or any saved session."""
function delete_workspace!(registry::WorkspaceRegistry, id::AbstractString)
    workspace_mutate!(registry) do items::Vector{Dict{String,Any}}
        index = workspace_find(items, id)
        if isnothing(index)
            workspace_failure("Unknown workspace")
        else
            deleteat!(items, index)
            workspace_success(Dict("deleted" => true),
                Dict("type" => "remove", "workspaceId" => String(id)))
        end
    end
end

"""Move a registered workspace before an anchor, or append it at the end."""
function move_workspace!(registry::WorkspaceRegistry, id::AbstractString, before=nothing)
    workspace_mutate!(registry) do items::Vector{Dict{String,Any}}
        index = workspace_find(items, id)
        anchor = isnothing(before) ? nothing : workspace_find(items, String(before))
        if isnothing(index) || (!isnothing(before) && isnothing(anchor))
            workspace_failure("Unknown workspace or ordering anchor")
        else
            old = [row["id"] for row in items]
            moved = splice!(items, index)
            target = isnothing(before) ? length(items) + 1 : before == id ?
                min(index, length(items) + 1) : workspace_find(items, String(before))
            Base.insert!(items, target, moved)
            ids = [row["id"] for row in items]
            workspace_success(Dict("workspaceIds" => ids),
                ids == old ? nothing : Dict("type" => "order", "workspaceIds" => ids))
        end
    end
end

"""Persist per-workspace session order, constrained to observed UUID memberships."""
function move_workspace_session!(registry::WorkspaceRegistry, id::AbstractString,
        session_id::AbstractString, before, members::Vector{String})
    workspace_mutate!(registry) do items::Vector{Dict{String,Any}}
        index = workspace_find(items, id)
        if isnothing(index)
            workspace_failure("Unknown workspace")
        elseif !(session_id in members) ||
                (!isnothing(before) && !(String(before) in members))
            workspace_failure("Session or anchor is not a member of this workspace")
        else
            row = items[index]
            previous = String.(row["sessionOrder"])
            ordered = String[member for member in previous if member in members]
            append!(ordered, (member for member in members if !(member in ordered)))
            before_move = copy(ordered)
            deleteat!(ordered, findfirst(==(session_id), ordered))
            destination = isnothing(before) ? length(ordered) + 1 :
                findfirst(==(String(before)), ordered)
            if isnothing(destination)
                destination = findfirst(==(session_id), before_move)
                Base.insert!(ordered, min(destination, length(ordered) + 1), String(session_id))
            else
                Base.insert!(ordered, destination, String(session_id))
            end
            if ordered == previous
                workspace_success(Dict("workspace" => deepcopy(row)))
            else
                row["sessionOrder"] = ordered
                row["updatedAt"] = time()
                workspace_success(Dict("workspace" => deepcopy(row)),
                    Dict("type" => "upsert", "workspace" => deepcopy(row)))
            end
        end
    end
end

"""Merge explicit workspace registration order with session directories and manual UUID order."""
function registered_workspace_groups(registry::WorkspaceRegistry, summaries::AbstractVector)
    unregistered = session_workspace_groups(summaries)
    groups = Dict{String,Dict{String,Any}}()
    for group in unregistered
        path = String(group["workingDirectory"])
        canonical = isdir(path) ? realpath(path) : path
        group["workingDirectory"] = canonical
        if haskey(groups, canonical)
            append!(groups[canonical]["sessions"], group["sessions"])
            groups[canonical]["sessionCount"] = length(groups[canonical]["sessions"])
        else
            groups[canonical] = group
        end
    end
    ordered = Dict{String,Any}[]
    for workspace in workspace_snapshot(registry)["workspaces"]
        path = String(workspace["path"])
        group = pop!(groups, path, Dict{String,Any}(
            "workingDirectory" => path, "sessions" => Dict{String,Any}[],
            "sessionCount" => 0))
        sessions = group["sessions"]
        manual = String.(workspace["sessionOrder"])
        position = Dict(id => index for (index, id) in enumerate(manual))
        sort!(sessions; by=row -> (get(position, String(row["id"]), typemax(Int)),
            String(row["session"]), String(row["id"])))
        group["registered"] = true
        group["workspaceId"] = workspace["id"]
        group["title"] = workspace["title"]
        push!(ordered, group)
    end
    for path in sort!(collect(keys(groups)))
        group = groups[path]
        group["registered"] = false
        push!(ordered, group)
    end
    ordered
end

"""Publish a registry implementation as an ordinary replaceable Julia plugin service."""
function workspace_registry_plugin(directory; name=:workspace_registry,
        service_name=:workspace_registry, factory=WorkspaceRegistry)
    contract = Symbol(service_name)
    setup = context -> provide!(context, contract, Base.invokelatest(factory, directory))
    PluginSpec(name, setup; provides=[contract])
end
