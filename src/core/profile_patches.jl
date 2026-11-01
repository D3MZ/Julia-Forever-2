import JSON

entry_patch_truthy(value) = true
entry_patch_truthy(::Nothing) = false
entry_patch_truthy(::Missing) = false
entry_patch_truthy(value::Bool) = value
entry_patch_truthy(value::Real) = !iszero(value) && !isnan(value)
entry_patch_truthy(value::AbstractString) = !isempty(value)

entry_patch_copy(value) = value
entry_patch_copy(values::AbstractVector) = Any[entry_patch_copy(value) for value in values]
entry_patch_copy(values::AbstractDict) = Dict{String,Any}(String(key) => entry_patch_copy(value) for (key, value) in values)

entry_patch_equal(left, right) = left === right
entry_patch_equal(left::AbstractString, right::AbstractString) = left == right
entry_patch_equal(left::Real, right::Real) = left isa Bool || right isa Bool ? left === right : left == right

function index_patch_entries!(index, entries)
    for entry in entries
        identity = get(entry, "id", nothing)
        entry_patch_truthy(identity) && (index[identity] = entry)
        configuration = get(entry, "config", nothing)
        if entry_patch_truthy(get(entry, "group", nothing)) && configuration isa AbstractVector
            index_patch_entries!(index, configuration)
        end
    end
    return index
end

function insert_patch_entries!(entries, index, identity, inserted, warn)
    if entry_patch_truthy(identity)
        target = get(index, identity, nothing)
        if isnothing(target)
            warn("patch insert: entry %C not found", identity)
            return nothing
        end
        if !entry_patch_truthy(get(target, "group", nothing))
            warn("patch insert: entry %C is not a group", identity)
            return nothing
        end
        get(target, "config", nothing) isa AbstractVector || (target["config"] = Any[])
        append!(target["config"], inserted)
    else
        append!(entries, inserted)
    end
    index_patch_entries!(index, inserted)
    return nothing
end

function override_patch_entry!(index, patch, identity, warn)
    if !entry_patch_truthy(identity)
        warn("patch: id is required for non-insert patches")
        return nothing
    end
    target = get(index, identity, nothing)
    if isnothing(target)
        warn("patch: entry %C not found", identity)
        return nothing
    end
    name = get(patch, "name", nothing)
    expected_name = get(target, "name", missing)
    if entry_patch_truthy(name) && !entry_patch_equal(name, expected_name)
        warn("patch: name mismatch for %C (expected %C, got %C), skipping", identity, expected_name, name)
        return nothing
    end
    for (key, value) in patch
        key in ("id", "insert", "name") || (target[key] = value)
    end
    return nothing
end

"""Apply ordered entry patches with explicit skipped-patch diagnostics."""
function apply_entry_patches(entries::AbstractVector, patches; warn=Returns(nothing))
    if isnothing(patches) || ismissing(patches) || isempty(patches)
        return copy(entries)
    end
    result = entry_patch_copy(entries)
    index = index_patch_entries!(Dict{Any,Any}(), result)
    for patch in patches
        identity = get(patch, "id", nothing)
        inserted = get(patch, "insert", nothing)
        if entry_patch_truthy(inserted)
            insert_patch_entries!(result, index, identity, inserted, warn)
        else
            override_patch_entry!(index, patch, identity, warn)
        end
    end
    return result
end

entry_patch_warning_value(::Missing) = "undefined"
entry_patch_warning_value(value) = JSON.json(value)

function format_entry_patch_warning(message, arguments)
    position = Ref(0)
    return replace(message, "%C" => placeholder -> begin
        position[] += 1
        entry_patch_warning_value(arguments[position[]])
    end)
end

"""Compose ordered entry patch layers without mutating the input."""
function compose_entry_layers(layers; warn=Returns(nothing))
    patches = entry_patch_copy(Any[patch for layer in layers for patch in layer])
    diagnostics = (message, arguments...) -> warn(format_entry_patch_warning(message, arguments))
    return apply_entry_patches(Any[], patches; warn=diagnostics)
end
