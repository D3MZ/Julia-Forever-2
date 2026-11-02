"""An immutable session identity with preserved JSON header fields."""
struct TimelineIdentity
    id::String
    cwd::String
    timestamp::String
    parent_session::Union{Nothing,String}
    fields::Dict{String,Any}
end

"""A native append-only entry graph whose active leaf is independently durable."""
Base.@kwdef mutable struct SessionTimeline
    identity::TimelineIdentity
    entries::Vector{Dict{String,Any}} = Dict{String,Any}[]
    indices::Dict{String,Int} = Dict{String,Int}()
    leaf::Union{Nothing,String} = nothing
    lock::ReentrantLock = ReentrantLock()
    path::Union{Nothing,String} = nothing
    disk_digest::Union{Nothing,String} = nothing
end

"""A private directory of collision-safe, independently resumable session timelines."""
struct TimelineStore
    directory::String
    lock::ReentrantLock
end
TimelineStore(directory::AbstractString) = TimelineStore(abspath(directory), ReentrantLock())

"""Format a UTC timestamp without depending on the process timezone or external tools."""
function timeline_timestamp(seconds::Real=time())
    milliseconds = floor(Int, seconds * 1000)
    days, within = fldmod(milliseconds, 86_400_000)
    era, day = fldmod(days + 719468, 146097)
    year = div(day - div(day, 1460) + div(day, 36524) - div(day, 146096), 365)
    doy = day - (365 * year + div(year, 4) - div(year, 100))
    month = div(5 * doy + 2, 153)
    date = doy - div(153 * month + 2, 5) + 1
    month += month < 10 ? 3 : -9
    year += era * 400 + (month <= 2 ? 1 : 0)
    hour, within = divrem(within, 3_600_000)
    minute, within = divrem(within, 60_000)
    second, millis = divrem(within, 1000)
    string(lpad(year, 4, '0'), '-', lpad(month, 2, '0'), '-', lpad(date, 2, '0'),
        'T', lpad(hour, 2, '0'), ':', lpad(minute, 2, '0'), ':',
        lpad(second, 2, '0'), '.', lpad(millis, 3, '0'), 'Z')
end

"""Copy JSON objects without retaining caller-owned nested data."""
timeline_object(data::AbstractDict) = Dict{String,Any}(String(key) => deepcopy(value) for (key, value) in data)
timeline_object(data) = error("Expected a JSON object")
timeline_nonempty(value) = value isa AbstractString && !isempty(value)
timeline_identifier(value) = timeline_nonempty(value) && !occursin(r"[\x00-\x20]", value)
timeline_session_id(value) = value isa AbstractString && occursin(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$", value)
timeline_optional_string(value) = isnothing(value) || value isa AbstractString

timeline_json_value(value, depth=0)::Bool = false
timeline_json_value(value::Nothing, depth=0)::Bool = true
timeline_json_value(value::Union{Bool,AbstractString}, depth=0)::Bool = true
timeline_json_value(value::Real, depth=0)::Bool = isfinite(value)
timeline_json_value(value::AbstractVector, depth=0)::Bool = depth < 128 && all(item -> timeline_json_value(item, depth + 1), value)
timeline_json_value(value::AbstractDict, depth=0)::Bool = depth < 128 && all(pair -> pair.first isa AbstractString && timeline_json_value(pair.second, depth + 1), value)

function timeline_valid_timestamp(value)
    matched = value isa AbstractString ? match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?Z$", value) : nothing
    if isnothing(matched)
        false
    else
        year, month, day, hour, minute, second = parse.(Int, matched.captures)
        leap = mod(year, 4) == 0 && (mod(year, 100) != 0 || mod(year, 400) == 0)
        lengths = (31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        1 <= year <= 9999 && 1 <= month <= 12 && 1 <= day <= lengths[month] &&
            0 <= hour < 24 && 0 <= minute < 60 && 0 <= second < 60
    end
end

function TimelineIdentity(header::AbstractDict)
    valid = get(header, "type", nothing) == "session" &&
        get(header, "version", nothing) == 3 &&
        timeline_session_id(get(header, "id", nothing)) &&
        timeline_nonempty(get(header, "cwd", nothing)) && isabspath(header["cwd"]) &&
        !occursin('\0', header["cwd"]) &&
        timeline_valid_timestamp(get(header, "timestamp", nothing)) &&
        timeline_json_value(header) &&
        timeline_optional_string(get(header, "parentSession", nothing))
    if !valid
        error("Invalid or unsupported session header; expected Pi JSONL version 3")
    end
    TimelineIdentity(String(header["id"]), String(header["cwd"]), String(header["timestamp"]),
        get(header, "parentSession", nothing), timeline_object(header))
end

function SessionTimeline(cwd::AbstractString; id=string(uuid4()), timestamp=timeline_timestamp(), parent_session=nothing)
    header = Dict{String,Any}("type" => "session", "version" => 3,
        "id" => String(id), "cwd" => abspath(cwd), "timestamp" => String(timestamp))
    if !isnothing(parent_session)
        header["parentSession"] = String(parent_session)
    end
    SessionTimeline(; identity=TimelineIdentity(header))
end

function timeline_header(timeline::SessionTimeline)
    identity = timeline.identity
    header = deepcopy(identity.fields)
    merge!(header, Dict("type" => "session", "version" => 3, "id" => identity.id,
        "cwd" => identity.cwd, "timestamp" => identity.timestamp))
    if isnothing(identity.parent_session)
        delete!(header, "parentSession")
    else
        header["parentSession"] = identity.parent_session
    end
    header
end
timeline_leaf(timeline::SessionTimeline) = lock(() -> timeline.leaf, timeline.lock)
timeline_entries(timeline::SessionTimeline) = lock(() -> deepcopy(timeline.entries), timeline.lock)

function timeline_entry(timeline::SessionTimeline, id::AbstractString)
    lock(timeline.lock) do
        index = get(timeline.indices, String(id), 0)
        index == 0 ? nothing : deepcopy(timeline.entries[index])
    end
end

function timeline_valid_message(message::AbstractDict)
    role = get(message, "role", nothing)
    if role == "bashExecution"
        code = get(message, "exitCode", nothing)
        get(message, "command", nothing) isa AbstractString &&
            get(message, "output", nothing) isa AbstractString &&
            get(message, "cancelled", nothing) isa Bool &&
            get(message, "truncated", nothing) isa Bool &&
            (isnothing(code) || code isa Integer && !(code isa Bool)) &&
            timeline_optional_string(get(message, "fullOutputPath", nothing)) &&
            get(message, "excludeFromContext", false) isa Bool
    else
        timeline_nonempty(role) && get(message, "content", nothing) isa Union{AbstractString,AbstractVector}
    end
end
timeline_valid_message(message) = false

function timeline_valid_payload(entry, kind)
    if kind == "message"
        timeline_valid_message(get(entry, "message", nothing))
    elseif kind == "custom"
        timeline_nonempty(get(entry, "customType", nothing))
    elseif kind == "session_info"
        timeline_optional_string(get(entry, "name", nothing))
    elseif kind == "label"
        timeline_identifier(get(entry, "targetId", nothing)) && timeline_optional_string(get(entry, "label", nothing))
    elseif kind == "compaction"
        get(entry, "summary", nothing) isa AbstractString &&
            timeline_identifier(get(entry, "firstKeptEntryId", nothing)) &&
            get(entry, "tokensBefore", nothing) isa Real && !(entry["tokensBefore"] isa Bool) &&
            isfinite(entry["tokensBefore"]) && entry["tokensBefore"] >= 0
    elseif kind == "branch_summary"
        get(entry, "summary", nothing) isa AbstractString && timeline_identifier(get(entry, "fromId", nothing))
    elseif kind == "context_edit"
        replacement = get(entry, "replacement", missing)
        timeline_identifier(get(entry, "targetId", nothing)) &&
            (isnothing(replacement) || replacement isa AbstractDict &&
                get(replacement, "content", nothing) isa Union{AbstractString,AbstractVector})
    else
        true
    end
end

"""Validate ordered graph structure before publishing any parsed or appended entries."""
function timeline_index(entries::AbstractVector)
    indices = Dict{String,Int}()
    for (index, entry) in enumerate(entries)
        if !(entry isa AbstractDict && timeline_identifier(get(entry, "id", nothing)) &&
                timeline_nonempty(get(entry, "type", nothing)) && entry["type"] != "session" &&
                haskey(entry, "parentId") && timeline_valid_timestamp(get(entry, "timestamp", nothing)) &&
                timeline_json_value(entry))
            error("Invalid session entry at position $index")
        end
        id, parent = String(entry["id"]), entry["parentId"]
        if haskey(indices, id)
            error("Duplicate session entry ID: $id")
        elseif !(isnothing(parent) || parent isa AbstractString && haskey(indices, parent))
            error("Missing, cyclic, or forward session parent: $id")
        elseif !timeline_valid_payload(entry, entry["type"])
            error("Invalid $(entry["type"]) payload: $id")
        end
        if entry["type"] in ("label", "context_edit") && !haskey(indices, entry["targetId"])
            error("Unknown session entry target: $id")
        elseif entry["type"] == "compaction" &&
                !(entry["firstKeptEntryId"] == id || haskey(indices, entry["firstKeptEntryId"]))
            error("Unknown compaction boundary: $id")
        end
        indices[id] = index
    end
    indices
end

"""Upgrade legacy Pi JSONL in a defensive copy, preserving session identity and opaque payloads."""
function timeline_migrate_rows(rows::AbstractVector)
    data = timeline_object.(rows)
    header = first(data)
    version = get(header, "version", 1)
    if !(get(header, "type", nothing) == "session" && version isa Integer &&
            !(version isa Bool) && version in (1, 2, 3))
        error("Unsupported session JSONL version")
    end
    if version == 1
        parent = nothing
        for entry in data[2:end]
            entry["id"] = string(uuid4())
            entry["parentId"] = parent
            parent = entry["id"]
            if entry["type"] == "compaction" && haskey(entry, "firstKeptEntryIndex")
                index = entry["firstKeptEntryIndex"]
                if !(index isa Integer && !(index isa Bool) && 1 <= index < length(data) &&
                        haskey(data[index + 1], "id"))
                    error("Invalid legacy compaction boundary")
                end
                entry["firstKeptEntryId"] = data[index + 1]["id"]
                delete!(entry, "firstKeptEntryIndex")
            end
        end
    end
    if version < 3
        for entry in data[2:end]
            message = get(entry, "message", nothing)
            if entry["type"] == "message" && message isa AbstractDict && get(message, "role", nothing) == "hookMessage"
                message["role"] = "custom"
            end
        end
    end
    header["version"] = 3
    data
end

function timeline_from_rows(rows::AbstractVector; leaf=missing)
    if isempty(rows)
        error("Session JSONL is empty")
    end
    rows = timeline_migrate_rows(rows)
    identity = TimelineIdentity(first(rows))
    entries = Dict{String,Any}[rows[index] for index in 2:length(rows)]
    indices = timeline_index(entries)
    selected = ismissing(leaf) ? (isempty(entries) ? nothing : String(last(entries)["id"])) : leaf
    if !(isnothing(selected) || selected isa AbstractString && haskey(indices, selected))
        error("Unknown active session leaf")
    end
    SessionTimeline(; identity, entries, indices, leaf=selected)
end

"""Parse only valid JSONL atomically, preserving unknown JSON fields and rejecting broken graphs."""
function parse_timeline_jsonl(text::AbstractString; max_bytes=64 * 1024 * 1024)
    if ncodeunits(text) > max_bytes
        error("Session import exceeds the size limit")
    end
    lines = filter(line -> !isempty(strip(line)), split(text, '\n'))
    rows = Any[]
    for (index, line) in enumerate(lines)
        value = parse_json(line)
        if !(value isa AbstractDict)
            error("Invalid JSON object at session line $index")
        end
        push!(rows, value)
    end
    timeline_from_rows(rows)
end

function timeline_path_entries(entries, indices, leaf)
    result = Dict{String,Any}[]
    current = leaf
    while !isnothing(current)
        entry = entries[indices[current]]
        push!(result, entry)
        current = entry["parentId"]
    end
    reverse!(deepcopy(result))
end

"""Read the chosen branch without changing the active leaf or dropping inactive branches."""
function timeline_branch(timeline::SessionTimeline, leaf=missing)
    lock(timeline.lock) do
        selected = ismissing(leaf) ? timeline.leaf : leaf
        if !isnothing(selected) && !haskey(timeline.indices, selected)
            error("Unknown branch entry: $selected")
        end
        timeline_path_entries(timeline.entries, timeline.indices, selected)
    end
end

function timeline_document(timeline::SessionTimeline, entries, leaf)
    Dict("format" => "JuliaForever2.timeline", "version" => 1,
        "header" => timeline_header(timeline), "entries" => entries, "leaf" => leaf)
end

timeline_digest(text) = bytes2hex(SHA.sha256(text))

"""Run owned filesystem work and release its lock even when the worker fails."""
function timeline_locked_write(action, path::AbstractString)
    lockpath = path * ".lock"
    mkdir(lockpath; mode=0o700)
    worker = Task(action)
    schedule(worker)
    wait(worker; throw=false)
    rm(lockpath)
    fetch(worker)
end

function timeline_sync_directory(path::AbstractString)
    if Sys.isunix()
        descriptor = ccall(:open, Cint, (Cstring, Cint), dirname(path), 0)
        if descriptor < 0
            error("Failed to open session directory for sync")
        end
        result = ccall(:fsync, Cint, (Cint,), descriptor)
        closed = ccall(:close, Cint, (Cint,), descriptor)
        if result != 0 || closed != 0
            error("Session data was written but directory durability could not be confirmed")
        end
    end
    nothing
end

function timeline_replace_file(path, text, expected)
    timeline_locked_write(path) do
        present = ispath(path)
        if islink(path) || (present && isnothing(expected)) ||
                (!present && !isnothing(expected)) ||
                (present && timeline_digest(read(path, String)) != expected)
            error("Session file changed or already exists: $path")
        end
        mktemp(dirname(path)) do temporary, output
            chmod(temporary, 0o600)
            write(output, text)
            flush(output)
            if Sys.isunix() && ccall(:fsync, Cint, (Cint,), fd(output)) != 0
                error("Failed to sync session data")
            end
            close(output)
            if isnothing(expected)
                hardlink(temporary, path)
            else
                Base.Filesystem.rename(temporary, path)
            end
            timeline_sync_directory(path)
        end
        timeline_digest(text)
    end
end

function timeline_commit!(timeline::SessionTimeline, entries, leaf)
    indices = timeline_index(entries)
    if !(isnothing(leaf) || haskey(indices, leaf))
        error("Unknown active session leaf")
    end
    path = timeline.path
    if !isnothing(path)
        text = JSON.json(timeline_document(timeline, entries, leaf)) * "\n"
        timeline.disk_digest = timeline_replace_file(path, text, timeline.disk_digest)
    end
    timeline.entries = entries
    timeline.indices = indices
    timeline.leaf = leaf
    timeline
end

"""Append one typed or opaque entry, persisting before changing the in-memory graph."""
function timeline_append!(timeline::SessionTimeline, payload::AbstractDict;
        id=string(uuid4()), timestamp=timeline_timestamp())
    lock(timeline.lock) do
        entry = timeline_object(payload)
        if any(key -> haskey(entry, key), ("id", "parentId", "timestamp"))
            error("Entry identity is supplied through keyword arguments")
        end
        entry["id"] = String(id)
        entry["parentId"] = timeline.leaf
        entry["timestamp"] = String(timestamp)
        entries = [timeline.entries; [entry]]
        timeline_commit!(timeline, entries, String(id))
        String(id)
    end
end

timeline_append_message!(timeline::SessionTimeline, message::AbstractDict; kwargs...) =
    timeline_append!(timeline, Dict("type" => "message", "message" => timeline_object(message)); kwargs...)
timeline_append_custom!(timeline::SessionTimeline, name::AbstractString, data; kwargs...) =
    timeline_append!(timeline, Dict("type" => "custom", "customType" => String(name), "data" => deepcopy(data)); kwargs...)
timeline_name!(timeline::SessionTimeline, name::AbstractString; kwargs...) =
    timeline_append!(timeline, Dict("type" => "session_info", "name" => strip(replace(String(name), r"[\r\n]+" => " "))); kwargs...)
timeline_label!(timeline::SessionTimeline, target::AbstractString, label; kwargs...) =
    timeline_append!(timeline, Dict("type" => "label", "targetId" => String(target), "label" => label); kwargs...)

"""Select an existing branch or the empty root without altering archived entries."""
function timeline_branch!(timeline::SessionTimeline, leaf::Union{Nothing,AbstractString})
    lock(timeline.lock) do
        timeline_commit!(timeline, timeline.entries, isnothing(leaf) ? nothing : String(leaf))
    end
end

function timeline_labels(entries)
    labels = Dict{String,Tuple{String,String}}()
    for entry in entries
        if entry["type"] == "label"
            label = get(entry, "label", nothing)
            if isnothing(label) || isempty(label)
                delete!(labels, entry["targetId"])
            else
                labels[entry["targetId"]] = (String(label), String(entry["timestamp"]))
            end
        end
    end
    labels
end

function timeline_label_order(entries)
    order = String[]
    for entry in entries
        if entry["type"] == "label"
            target, label = String(entry["targetId"]), get(entry, "label", nothing)
            if isnothing(label) || isempty(label)
                filter!(!=(target), order)
            elseif !(target in order)
                push!(order, target)
            end
        end
    end
    order
end

function timeline_label(timeline::SessionTimeline, target::AbstractString)
    labels = timeline_labels(timeline_entries(timeline))
    haskey(labels, target) ? labels[target][1] : nothing
end

function timeline_name(timeline::SessionTimeline)
    names = [get(entry, "name", nothing) for entry in timeline_entries(timeline)
        if entry["type"] == "session_info"]
    name = isempty(names) ? nothing : last(names)
    isnothing(name) || isempty(strip(name)) ? nothing : String(strip(name))
end

"""Compare valid UTC ISO strings at Pi's millisecond precision, including omitted fractions."""
function timeline_timestamp_key(value::AbstractString)
    fraction = value[20] == '.' ? rpad(value[21:end-1], 3, '0')[1:3] : "000"
    (value[1:19], fraction)
end

"""Return defensive tree nodes with resolved labels and timestamp-ordered children."""
function timeline_tree(timeline::SessionTimeline)
    entries = timeline_entries(timeline)
    labels = timeline_labels(entries)
    nodes = Dict(entry["id"] => Dict{String,Any}("entry" => entry,
        "children" => Any[]) for entry in entries)
    roots = Any[]
    for entry in entries
        node = nodes[entry["id"]]
        if haskey(labels, entry["id"])
            node["label"], node["labelTimestamp"] = labels[entry["id"]]
        end
        parent = entry["parentId"]
        push!(isnothing(parent) ? roots : nodes[parent]["children"], node)
    end
    for node in values(nodes)
        sort!(node["children"]; by=child -> timeline_timestamp_key(child["entry"]["timestamp"]), alg=Base.Sort.MergeSort)
    end
    roots
end

"""Export the active branch as interoperable version-three JSONL, retaining opaque fields."""
function timeline_export_jsonl(timeline::SessionTimeline; leaf=missing)
    lock(timeline.lock) do
        entries = timeline_branch(timeline, leaf)
        parent = nothing
        for entry in entries
            entry["parentId"] = parent
            parent = entry["id"]
        end
        join(JSON.json.([timeline_header(timeline); entries]), "\n") * "\n"
    end
end

function timeline_user_text(message)
    content = get(message, "content", "")
    timeline_text(content)
end

timeline_text(content::AbstractString) = String(content)
timeline_text(content::AbstractVector) = join([String(get(block, "text", "")) for block in content
    if block isa AbstractDict && get(block, "type", nothing) == "text"], "\n")

function timeline_copy_branch(source::SessionTimeline, leaf; id=string(uuid4()), timestamp=timeline_timestamp())
    if String(id) == source.identity.id
        error("Forked sessions require a new identity")
    end
    branch = timeline_branch(source, leaf)
    labels = timeline_labels(source.entries)
    target = SessionTimeline(source.identity.cwd; id, timestamp,
        parent_session=isnothing(source.path) ? nothing : source.path)
    entries = Dict{String,Any}[]
    replacements = Dict{String,String}()
    pending = String[]
    parent = nothing
    for entry in branch
        if entry["type"] == "label"
            push!(pending, entry["id"])
        else
            for labelid in pending
                replacements[labelid] = entry["id"]
            end
            empty!(pending)
            entry["parentId"] = parent
            if entry["type"] == "compaction"
                boundary = entry["firstKeptEntryId"]
                entry["firstKeptEntryId"] = get(replacements, boundary, boundary)
            end
            push!(entries, entry)
            parent = entry["id"]
        end
    end
    ids = Set(entry["id"] for entry in entries)
    for selected in timeline_label_order(source.entries)
        if selected in ids && haskey(labels, selected)
            label, stamp = labels[selected]
            entry = Dict{String,Any}("type" => "label", "id" => string(uuid4()),
                "parentId" => parent, "timestamp" => stamp, "targetId" => selected, "label" => label)
            push!(entries, entry)
            parent = entry["id"]
        end
    end
    timeline_commit!(target, entries, parent)
end

"""Fork immediately before a user message and return its text for the new editor."""
function timeline_fork(source::SessionTimeline, user_id::AbstractString; kwargs...)
    lock(source.lock) do
        entry = timeline_entry(source, user_id)
        if isnothing(entry) || entry["type"] != "message" || get(entry["message"], "role", nothing) != "user"
            error("Fork requires an existing user-message entry")
        end
        (timeline=timeline_copy_branch(source, entry["parentId"]; kwargs...),
            editor_text=timeline_user_text(entry["message"]))
    end
end

"""Clone the current branch at its leaf, preserving the source and generating a new identity."""
function timeline_clone(source::SessionTimeline; kwargs...)
    lock(source.lock) do
        if isnothing(source.leaf)
            error("Nothing to clone yet")
        end
        timeline_copy_branch(source, source.leaf; kwargs...)
    end
end

function timeline_store_path(store::TimelineStore, id::AbstractString)
    if !timeline_session_id(id)
        error("Invalid timeline session identifier")
    end
    joinpath(store.directory, string(String(id)::String, ".timeline.json"))
end

"""Persist a new timeline without overwriting another file or stale writer's revision."""
function save_timeline!(store::TimelineStore, timeline::SessionTimeline)
    lock(store.lock) do
        lock(timeline.lock) do
            mkpath(store.directory; mode=0o700)
            path = timeline_store_path(store, timeline.identity.id)
            expected = timeline.path == path ? timeline.disk_digest : nothing
            text = JSON.json(timeline_document(timeline, timeline.entries, timeline.leaf)) * "\n"
            digest = timeline_replace_file(path, text, expected)
            timeline.path = path
            timeline.disk_digest = digest
            path
        end
    end
end

function timeline_read_native(path::AbstractString)
    if islink(path) || !isfile(path)
        error("Timeline must be an existing regular non-symlink file")
    end
    if filesize(path) > 64 * 1024 * 1024
        error("Persisted timeline exceeds the size limit")
    end
    text = read(path, String)
    data = parse_json(text)
    if !(data isa AbstractDict && get(data, "format", nothing) == "JuliaForever2.timeline" &&
            get(data, "version", nothing) == 1 && get(data, "header", nothing) isa AbstractDict &&
            get(data, "entries", nothing) isa AbstractVector && haskey(data, "leaf"))
        error("Invalid persisted timeline document")
    end
    timeline = timeline_from_rows([data["header"]; data["entries"]]; leaf=data["leaf"])
    timeline.path = abspath(path)
    timeline.disk_digest = timeline_digest(text)
    timeline
end

"""Resume the same persisted identity, graph, working directory and active leaf."""
function load_timeline(store::TimelineStore, id::AbstractString)
    lock(store.lock) do
        timeline = timeline_read_native(timeline_store_path(store, id))
        if timeline.identity.id != id
            error("Timeline identity does not match its storage path")
        end
        timeline
    end
end

"""Remove only an unchanged, inactive native session under the same cross-writer lock as saving."""
function delete_timeline!(store::TimelineStore, id::AbstractString, expected::AbstractString; active_id=nothing)
    lock(store.lock) do
        if id == active_id
            error("Cannot delete the active session")
        end
        path = timeline_store_path(store, id)
        timeline_locked_write(path) do
            timeline = timeline_read_native(path)
            if timeline.identity.id != id || timeline.disk_digest != expected
                error("Session changed before deletion; reload the session list")
            end
            rm(path)
            timeline_sync_directory(path)
            if ispath(path) || islink(path)
                error("Session removal could not be verified")
            end
        end
        path
    end
end

"""Convert validated UTC archive timestamps to Unix seconds without timezone-dependent parsing."""
function timeline_timestamp_seconds(value::AbstractString)
    if !timeline_valid_timestamp(value)
        error("Invalid session timestamp")
    end
    year, month, day = parse(Int, value[1:4]), parse(Int, value[6:7]), parse(Int, value[9:10])
    year -= month <= 2 ? 1 : 0
    era = fld(year, 400)
    within = year - era * 400
    ordinal = fld(153 * (month + (month > 2 ? -3 : 9)) + 2, 5) + day - 1
    days = era * 146097 + within * 365 + fld(within, 4) - fld(within, 100) + ordinal - 719468
    seconds = days * 86400 + parse(Int, value[12:13]) * 3600 + parse(Int, value[15:16]) * 60 + parse(Int, value[18:19])
    fraction = value[20] == '.' ? parse(Float64, "0" * value[20:end-1]) : 0.0
    Float64(seconds) + fraction
end

"""List complete persisted session summaries without running providers or reading external paths."""
function list_timelines(store::TimelineStore; cwd=nothing)
    lock(store.lock) do
        files = isdir(store.directory) ? sort(readdir(store.directory)) : String[]
        summaries = NamedTuple[]
        for file in filter(name -> endswith(name, ".timeline.json"), files)
            id = chop(file; tail=14)
            timeline = load_timeline(store, id)
            if isnothing(cwd) || normpath(timeline.identity.cwd) == normpath(abspath(cwd))
                messages = [entry for entry in timeline.entries if entry["type"] == "message"]
                push!(summaries, (id=timeline.identity.id, name=timeline_name(timeline),
                    cwd=timeline.identity.cwd, created=timeline.identity.timestamp,
                    modified=isempty(timeline.entries) ? timeline.identity.timestamp : last(timeline.entries)["timestamp"],
                    path=timeline.path, messages=length(messages), leaf=timeline.leaf))
            end
        end
        sort!(summaries; by=item -> timeline_timestamp_key(item.modified), rev=true, alg=Base.Sort.MergeSort)
    end
end

"""Import a validated file into private storage, refusing identity collisions before any write."""
function import_timeline!(store::TimelineStore, source::AbstractString; max_bytes=64 * 1024 * 1024)
    if islink(source) || !isfile(source) || filesize(source) > max_bytes
        error("Import requires a regular session file within the size limit")
    end
    timeline = parse_timeline_jsonl(read(source, String); max_bytes)
    save_timeline!(store, timeline)
    timeline
end

"""Write a branch export with exclusive creation; existing destinations are never overwritten."""
function export_timeline!(timeline::SessionTimeline, destination::AbstractString)
    path = abspath(destination)
    if !isdir(dirname(path))
        error("Export destination directory does not exist")
    end
    timeline_replace_file(path, timeline_export_jsonl(timeline), nothing)
    path
end

"""Append a compaction record without modifying or discarding any original entries."""
function timeline_append_compaction!(timeline::SessionTimeline, summary::AbstractString,
        first_kept::Union{Nothing,AbstractString}, tokens_before::Real;
        fields=Dict{String,Any}(), id=string(uuid4()), timestamp=timeline_timestamp())
    payload = timeline_object(fields)
    merge!(payload, Dict("type" => "compaction", "summary" => String(summary),
        "firstKeptEntryId" => isnothing(first_kept) ? String(id) : String(first_kept),
        "tokensBefore" => tokens_before))
    timeline_append!(timeline, payload; id, timestamp)
end

"""Navigate and append a branch summary in one validated, durable transaction."""
function timeline_branch_summary!(timeline::SessionTimeline, leaf::Union{Nothing,AbstractString},
        summary::AbstractString; fields=Dict{String,Any}(), id=string(uuid4()), timestamp=timeline_timestamp())
    lock(timeline.lock) do
        entry = timeline_object(fields)
        merge!(entry, Dict("type" => "branch_summary", "id" => String(id), "parentId" => leaf,
            "timestamp" => String(timestamp), "summary" => String(summary),
            "fromId" => isnothing(timeline.leaf) ? "root" : timeline.leaf))
        timeline_commit!(timeline, [timeline.entries; [entry]], String(id))
        String(id)
    end
end

"""Read original message objects on the active branch without flattening their rich content."""
timeline_messages(timeline::SessionTimeline) =
    [entry["message"] for entry in timeline_branch(timeline) if entry["type"] == "message"]

"""Append a branch-local context edit without changing the archived original message."""
function timeline_append_context_edit!(timeline::SessionTimeline, target::AbstractString, replacement; fields=Dict{String,Any}(), kwargs...)
    lock(timeline.lock) do
        entry = timeline_entry(timeline, target)
        editable = !isnothing(entry) && (entry["type"] == "custom_message" ||
            entry["type"] == "message" && (get(entry["message"], "role", nothing) in ("user", "assistant", "toolResult") ||
                timeline_native_result_editable(entry["message"])))
        if !editable || !any(item -> item["id"] == target, timeline_branch(timeline))
            error("Context edit requires editable content on the active branch")
        end
        content = replacement isa AbstractDict ? get(replacement, "content", missing) : missing
        if !(isnothing(replacement) || content isa Union{AbstractString,AbstractVector})
            error("Context edit replacement must be null or contain string/array content")
        end
        role = entry["type"] == "message" ? entry["message"]["role"] : "custom"
        normalized = content isa AbstractString && role in ("assistant", "toolResult") ?
            Dict("content" => [Dict("type" => "text", "text" => String(content))]) : deepcopy(replacement)
        if !(fields isa AbstractDict) || any(key -> haskey(fields, key), ("type", "targetId", "replacement", "id", "parentId", "timestamp"))
            error("Context edit extension fields cannot replace entry identity or content")
        end
        payload = JuliaForever2.timeline_object(fields)
        merge!(payload, Dict("type" => "context_edit", "targetId" => String(target), "replacement" => normalized))
        timeline_append!(timeline, payload; kwargs...)
    end
end

"""Allow content-only edits of owned native execution results, never arbitrary foreign custom roles."""
function timeline_native_result_editable(message::AbstractDict)
    native = get(message, "jf2", nothing)
    get(message, "role", nothing) == "custom" && get(message, "customType", nothing) == "juliaforever.code_result" &&
        native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1" &&
        get(native, "role", nothing) == "code_result" && get(native, "kind", nothing) == "text"
end
