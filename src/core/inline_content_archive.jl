function inline_original_budget!(budget, original::TimelineMessageMetadata, depth::Int)
    inline_json_budget!(budget, original.source_entry_id, depth + 1)
    inline_json_budget!(budget, original.projected, depth + 1)
    inline_json_budget!(budget, original.llm_message, depth + 1)
    nothing
end
function inline_original_snapshot(original::TimelineMessageMetadata)
    TimelineMessageMetadata(original.source_entry_id, timeline_object(original.projected), timeline_object(original.llm_message))
end
inline_timeline_origin(metadata) = nothing
inline_timeline_origin(metadata::TimelineMessageMetadata) = metadata
inline_timeline_origin(metadata::ProviderMessageMetadata) = inline_timeline_origin(metadata.original)
inline_timeline_origin(metadata::InlineContentMetadata) = inline_timeline_origin(metadata.original)

"""Store rich content once, in the archival content field, not duplicated inside opaque metadata."""
function timeline_archived_metadata(metadata::InlineContentMetadata)
    Dict{String,Any}("format" => "inline_content_v1", "original" => timeline_archived_metadata(metadata.original))
end
function inline_archive_metadata_present(data)
    depth = 0
    while data isa AbstractDict
        depth += 1
        depth <= MODEL_IMAGE_MAX_DEPTH || error("Archived inline provenance exceeds its depth limit")
        format = get(data, "format", nothing)
        format == "inline_content_v1" && return true
        format == "provider_context" || return false
        data = get(data, "original", nothing)
    end
    false
end
function inline_has_provider_context(metadata)
    depth = 0
    while metadata isa InlineContentMetadata
        depth += 1
        depth <= MODEL_IMAGE_MAX_DEPTH || error("Inline provenance exceeds its depth limit")
        metadata = metadata.original
    end
    metadata isa ProviderMessageMetadata
end
function restore_inline_archive_metadata(data::AbstractDict, blocks::Tuple)
    inline_require_json(data)
    format = get(data, "format", nothing)
    if format == "inline_content_v1"
        length(data) == 2 && haskey(data, "original") || error("Invalid archived inline metadata")
        InlineContentMetadata(blocks, timeline_restored_metadata(data["original"]))
    elseif format == "provider_context"
        length(data) == 3 && haskey(data, "original") && get(data, "context", nothing) isa AbstractDict || error("Invalid archived provider provenance")
        ProviderMessageMetadata(restore_inline_archive_metadata(data["original"], blocks), timeline_object(data["context"]))
    else
        error("Archived inline content requires explicit provenance")
    end
end

function timeline_inline_native_message(message::AbstractDict, source_id::AbstractString, original::AbstractDict)
    native = get(original, "jf2", nothing)
    native_owned = native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
    archived_metadata = native_owned ? get(native, "metadata", nothing) : nothing
    content = get(message, "content", nothing)
    marked = inline_archive_metadata_present(archived_metadata)
    contains_image = content isa AbstractVector && any(block -> block isa AbstractDict && get(block, "type", nothing) == "image", content)
    marked || contains_image || return nothing
    blocks = parse_inline_content(content)
    blocks isa InlineContentFailure && error("Unsupported or invalid rich archival blocks")
    if native_owned
        marked || error("Native rich archival content lacks a validated inline metadata marker")
        role, kind = get(native, "role", nothing), get(native, "kind", nothing)
        compatible = role == "user" && get(original, "role", nothing) == "user" ||
            role == "code_result" && get(original, "role", nothing) == "custom" && get(original, "customType", nothing) == "juliaforever.code_result"
        compatible && kind == "text" || error("Invalid native inline archival role")
        metadata = restore_inline_archive_metadata(archived_metadata, blocks)
        Message(Symbol(role), inline_text_content(blocks), :text; metadata)
    else
        get(message, "role", nothing) == "user" && get(original, "role", nothing) == "user" ||
            error("Rich archival role needs an explicit tool or assistant adapter")
        inline_require_json(original)
        inline_require_json(message)
        provenance = TimelineMessageMetadata(String(source_id), timeline_object(original), timeline_object(message))
        inline_message(:user, blocks; original=provenance)
    end
end

function timeline_archive_inline_message(message::Message; timestamp, provider_message, provider, model, api)
    inline_message_valid(message) || error("Invalid native inline archival message")
    all(isnothing, (provider_message, provider, model, api)) || error("User and tool inline messages cannot claim assistant provider identity")
    blocks = message_inline_content(message)
    origin = inline_timeline_origin(message.metadata)
    if !isnothing(origin)
        inline_has_provider_context(message.metadata) && error("Imported inline provenance cannot acquire an unarchived provider context")
        original_blocks = parse_inline_content(get(origin.llm_message, "content", nothing))
        original_blocks isa Tuple && original_blocks == blocks && message.role == :user ||
            error("Edited rich projected messages require an explicit archival edit")
        return timeline_object(origin.projected)
    end
    role = message.role == :code_result ? "custom" : "user"
    native = Dict{String,Any}("format" => "JuliaForever2.message.v1", "role" => String(message.role),
        "kind" => String(message.kind), "metadata" => timeline_archived_metadata(message.metadata))
    result = Dict{String,Any}("role" => role, "content" => inline_canonical_content(blocks), "timestamp" => timestamp, "jf2" => native)
    if role == "custom"
        result["customType"] = "juliaforever.code_result"
        result["display"] = true
    end
    result
end

stored_session_version(message::Message{<:InlineContentMetadata}) = 4
stored_session_version(message::Message{<:ProviderMessageMetadata}) = isnothing(message_inline_content(message)) ? 2 : 4

"""Retain typed content in legacy native saves without changing ordinary historical entries."""
function stored_inline_session_message(message::Message)
    inline_message_valid(message) || error("Invalid rich saved session message")
    origin = inline_timeline_origin(message.metadata)
    inline = Dict{String,Any}("format" => "JuliaForever2.inline-message.v1",
        "message" => timeline_archive_message(message), "sourceEntryId" => isnothing(origin) ? nothing : origin.source_entry_id)
    entry = Dict{String,Any}("role" => String(message.role), "content" => message.content, "kind" => String(message.kind), "inline" => inline)
    inline_require_json(entry)
end
stored_session_message(message::Message{<:InlineContentMetadata}) = stored_inline_session_message(message)
function stored_session_message(message::Message{<:ProviderMessageMetadata})
    isnothing(message_inline_content(message)) ?
        Dict("role" => String(message.role), "content" => message.content, "kind" => String(message.kind)) : stored_inline_session_message(message)
end

function restored_inline_session_message(entry::AbstractDict, version::Int)
    inline_require_json(entry)
    inline = get(entry, "inline", nothing)
    version == 4 && inline isa AbstractDict && length(inline) == 3 &&
        get(inline, "format", nothing) == "JuliaForever2.inline-message.v1" || error("Invalid rich saved session record")
    payload = get(inline, "message", nothing)
    payload isa AbstractDict || error("Rich saved session payload is missing")
    source_id = get(inline, "sourceEntryId", nothing)
    isnothing(source_id) || source_id isa String && timeline_identifier(source_id) || error("Invalid rich saved source identity")
    native = get(payload, "jf2", nothing)
    owned = native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
    owned || source_id isa String || error("Imported rich saved message requires its actual source identity")
    restored = timeline_native_message(timeline_llm_message(payload), something(source_id, ""), payload)
    inline_message_valid(restored) && String(restored.role) == get(entry, "role", nothing) &&
        restored.content == get(entry, "content", nothing) && String(restored.kind) == get(entry, "kind", nothing) ||
        error("Rich saved message role or content does not match its archival payload")
    restored
end
