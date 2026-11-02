"""A selected archived entry and its independently copied model-visible contribution."""
struct TimelineProjectedEntry
    source_entry::Dict{String,Any}
    messages::Vector{Dict{String,Any}}
end

"""An archive-preserving active context with provenance and branch-local model settings."""
struct TimelineContextProjection
    entries::Vector{TimelineProjectedEntry}
    messages::Vector{Dict{String,Any}}
    thinking_level::String
    model::Union{Nothing,Dict{String,Any}}
end

"""Preserve rich context provenance locally without sending archive bookkeeping as prompt text."""
struct TimelineMessageMetadata
    source_entry_id::String
    projected::Dict{String,Any}
    llm_message::Dict{String,Any}
end
wire_metadata(::TimelineMessageMetadata) = nothing

function timeline_epoch_milliseconds(timestamp::AbstractString)
    if !timeline_valid_timestamp(timestamp)
        error("Invalid context timestamp")
    end
    year, month, day = parse.(Int, (timestamp[1:4], timestamp[6:7], timestamp[9:10]))
    year -= month <= 2 ? 1 : 0
    era, within = fldmod(year, 400)
    adjusted = month + (month > 2 ? -3 : 9)
    ordinal = div(153 * adjusted + 2, 5) + day - 1
    days = era * 146097 + within * 365 + div(within, 4) - div(within, 100) + ordinal - 719468
    hour, minute, second = parse.(Int, (timestamp[12:13], timestamp[15:16], timestamp[18:19]))
    millis = parse(Int, last(timeline_timestamp_key(timestamp)))
    days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + millis
end

"""Require a defensive copy only when legacy null content needs validation repair."""
function timeline_context_requires_repair(entry)
    message = get(entry, "type", nothing) == "message" ? get(entry, "message", nothing) : nothing
    message isa AbstractDict && isnothing(get(message, "content", nothing)) &&
        get(message, "role", nothing) in ("system", "user", "assistant", "toolResult")
end

function timeline_context_index(entries)
    repair = any(timeline_context_requires_repair, entries)
    checked = repair ? deepcopy(entries) : entries
    if repair
        for entry in checked
            if get(entry, "type", nothing) == "message"
                message = get(entry, "message", nothing)
                if message isa AbstractDict && isnothing(get(message, "content", nothing))
                    role = get(message, "role", nothing)
                    if role in ("system", "user", "assistant", "toolResult")
                        message["content"] = role == "system" ? "" : Any[]
                    end
                end
            end
        end
    end
    timeline_index(checked)
end

function timeline_context_settings(path)
    thinking = "off"
    model = nothing
    for entry in path
        kind = entry["type"]
        if kind == "thinking_level_change"
            thinking = String(entry["thinkingLevel"])
        elseif kind == "model_change"
            model = Dict{String,Any}("provider" => entry["provider"], "modelId" => entry["modelId"])
        elseif kind == "message" && entry["message"]["role"] == "assistant"
            message = entry["message"]
            model = Dict{String,Any}()
            for (source, destination) in (("provider", "provider"), ("model", "modelId"))
                if haskey(message, source)
                    model[destination] = deepcopy(message[source])
                end
            end
        end
    end
    (thinking_level=thinking, model=model)
end

function timeline_context_entries(path::AbstractVector{<:AbstractDict})
    boundary = findlast(entry -> entry["type"] == "compaction", path)
    if isnothing(boundary)
        path
    else
        checkpoint = path[boundary]
        first_kept = findfirst(entry -> entry["id"] == checkpoint["firstKeptEntryId"], path[1:boundary-1])
        retained = isnothing(first_kept) ? Dict{String,Any}[] :
            [entry for entry in path[first_kept:boundary-1]
                if !(entry["type"] == "message" && entry["message"]["role"] == "system")]
        [checkpoint; retained; path[boundary+1:end]]
    end
end

function timeline_context_entry_messages(entry::AbstractDict)
    kind = entry["type"]
    messages = Dict{String,Any}[]
    if kind == "message"
        message = timeline_object(entry["message"])
        role = message["role"]
        if isnothing(get(message, "content", nothing)) && role in ("system", "user", "assistant", "toolResult")
            message["content"] = role == "system" ? "" : Any[]
        end
        push!(messages, message)
    elseif kind == "custom_message"
        content = get(entry, "content", nothing)
        message = Dict{String,Any}("role" => "custom", "customType" => entry["customType"],
            "content" => isnothing(content) ? Any[] : deepcopy(content), "display" => entry["display"],
            "timestamp" => timeline_epoch_milliseconds(entry["timestamp"]))
        if haskey(entry, "details")
            message["details"] = deepcopy(entry["details"])
        end
        push!(messages, message)
    elseif kind == "branch_summary" && !isempty(entry["summary"])
        push!(messages, Dict{String,Any}("role" => "branchSummary", "summary" => entry["summary"],
            "fromId" => entry["fromId"], "timestamp" => timeline_epoch_milliseconds(entry["timestamp"])))
    elseif kind == "compaction"
        if !isnothing(get(entry, "systemMessage", nothing))
            push!(messages, timeline_object(entry["systemMessage"]))
        end
        summary = Dict{String,Any}("role" => "compactionSummary", "summary" => entry["summary"],
            "tokensBefore" => entry["tokensBefore"], "timestamp" => timeline_epoch_milliseconds(entry["timestamp"]))
        native = get(entry, "jf2", nothing)
        if native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.compaction.v1" &&
                get(native, "contextSummaryFormat", nothing) == "native-plain"
            summary["jf2"] = deepcopy(native)
        end
        push!(messages, summary)
    end
    messages
end

function timeline_apply_context_edit(messages, ::Nothing)
    messages
end
function timeline_apply_context_edit(messages, edit::AbstractDict)
    replacement = edit["replacement"]
    if isnothing(replacement)
        Dict{String,Any}[]
    else
        for message in messages
            if message["role"] in ("user", "assistant", "toolResult", "custom")
                content = deepcopy(replacement["content"])
                message["content"] = content isa AbstractString && message["role"] in ("assistant", "toolResult") ?
                    [Dict("type" => "text", "text" => String(content))] : content
            end
        end
        messages
    end
end

"""Project a validated graph without rewriting raw entries, including legacy null-content repair."""
function timeline_projection(entries::AbstractVector; leaf=missing)
    archive = timeline_object.(entries)
    indices = timeline_context_index(archive)
    selected = ismissing(leaf) ? (isempty(archive) ? nothing : last(archive)["id"]) : leaf
    if !(isnothing(selected) || selected isa AbstractString && haskey(indices, selected))
        error("Unknown context leaf")
    end
    path = timeline_path_entries(archive, indices, selected)
    settings = timeline_context_settings(path)
    effective = timeline_context_entries(path)
    edits = Dict(entry["targetId"] => entry for entry in effective if entry["type"] == "context_edit")
    projected = TimelineProjectedEntry[]
    messages = Dict{String,Any}[]
    for (index, entry) in enumerate(effective)
        contribution = entry["type"] == "compaction" && index > 1 ? Dict{String,Any}[] :
            timeline_apply_context_edit(timeline_context_entry_messages(entry), get(edits, entry["id"], nothing))
        push!(projected, TimelineProjectedEntry(deepcopy(entry), deepcopy(contribution)))
        append!(messages, contribution)
    end
    TimelineContextProjection(projected, messages, settings.thinking_level, settings.model)
end

"""Project the timeline's durable selected branch from one atomic archive snapshot."""
function timeline_projection(timeline::SessionTimeline; leaf=missing)
    lock(timeline.lock) do
        timeline_projection(timeline.entries; leaf=ismissing(leaf) ? timeline.leaf : leaf)
    end
end

timeline_context(projection::TimelineContextProjection) =
    (messages=deepcopy(projection.messages), thinking_level=projection.thinking_level, model=deepcopy(projection.model))
timeline_context(timeline; kwargs...) = timeline_context(timeline_projection(timeline; kwargs...))

function timeline_bash_text(message)
    text = "Ran `" * message["command"] * "`\n"
    output = message["output"]
    text *= isempty(output) ? "(no output)" : "```\n" * output * "\n```"
    code = get(message, "exitCode", nothing)
    if message["cancelled"]
        text *= "\n\n(command cancelled)"
    elseif !isnothing(code) && code != 0
        text *= "\n\nCommand exited with code " * string(code)
    end
    path = get(message, "fullOutputPath", nothing)
    if message["truncated"] && path isa AbstractString && !isempty(path)
        text *= "\n\n[Output truncated. Full output: " * path * "]"
    end
    text
end

"""Convert coding-agent-only roles into provider-neutral rich messages without losing blocks."""
function timeline_llm_message(message::AbstractDict)
    role = get(message, "role", nothing)
    if role in ("system", "user", "assistant", "toolResult")
        timeline_object(message)
    elseif role == "bashExecution" && get(message, "excludeFromContext", false)
        nothing
    elseif role in ("bashExecution", "custom", "branchSummary", "compactionSummary")
        content = if role == "custom"
            raw = message["content"]
            raw isa AbstractString ? [Dict("type" => "text", "text" => String(raw))] : deepcopy(raw)
        else
            text = if role == "bashExecution"
                timeline_bash_text(message)
            elseif role == "compactionSummary" && native_plain_compaction(message)
                String(message["summary"])
            elseif role == "branchSummary"
                "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n" * message["summary"] * "</summary>"
            else
                "The conversation history before this point was compacted into the following summary:\n\n<summary>\n" * message["summary"] * "\n</summary>"
            end
            [Dict("type" => "text", "text" => text)]
        end
        converted = Dict{String,Any}("role" => "user", "content" => content)
        if haskey(message, "timestamp")
            converted["timestamp"] = message["timestamp"]
        end
        converted
    else
        error("Unsupported context message role: $(role)")
    end
end

function timeline_llm_messages(projection::TimelineContextProjection)
    result = Dict{String,Any}[]
    for message in projection.messages
        converted = timeline_llm_message(message)
        if !isnothing(converted)
            push!(result, converted)
        end
    end
    result
end
timeline_llm_messages(timeline; kwargs...) = timeline_llm_messages(timeline_projection(timeline; kwargs...))

function timeline_native_text(content::AbstractString)
    String(content)
end
function timeline_native_text(content::AbstractVector)
    if !all(block -> block isa AbstractDict && get(block, "type", nothing) == "text" &&
            get(block, "text", nothing) isa AbstractString &&
            all(key -> key in ("type", "text"), keys(block)), content)
        error("Native text transport requires an explicit rich-block adapter for image, thinking, toolCall, signed text or unknown content")
    end
    join([String(block["text"]) for block in content], "")
end
timeline_native_text(content) = error("Unsupported native context content")

function timeline_restored_metadata(data::Nothing)
    nothing
end
function timeline_restored_metadata(data::AbstractDict)
    format = get(data, "format", nothing)
    if format == "execution_result"
        ExecutionResult(data["ok"], data["text"], get(data, "value", nothing))
    elseif format == "provider_context"
        ProviderMessageMetadata(timeline_restored_metadata(get(data,"original",nothing)),timeline_object(data["context"]))
    elseif format == "json"
        deepcopy(data["value"])
    else
        error("Unsupported persisted native message metadata")
    end
end

"""Map text-safe context into native Messages; rich blocks and native tool calls need an adapter."""
function timeline_native_message(message::AbstractDict, source_id::AbstractString, original::AbstractDict=message)
    native = get(original, "jf2", nothing)
    if native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
        native_role, native_kind = get(native, "role", nothing), get(native, "kind", nothing)
        compatible = native_role == "code_result" ?
            get(original, "role", nothing) == "custom" && get(original, "customType", nothing) == "juliaforever.code_result" :
            native_role in ("system", "user", "assistant") && native_role == get(original, "role", nothing)
        if !compatible || !timeline_nonempty(native_kind)
            error("Invalid native role/kind metadata in archived message")
        end
        Message(Symbol(native["role"]), timeline_native_text(message["content"]), Symbol(native["kind"]);
            metadata=timeline_restored_metadata(get(native, "metadata", nothing)))
    elseif message["role"] in ("system", "user", "assistant")
        Message(Symbol(message["role"]), timeline_native_text(message["content"]);
            metadata=TimelineMessageMetadata(String(source_id), timeline_object(original), timeline_object(message)))
    else
        error("Native transport needs an explicit role/tool adapter for $(message["role"])")
    end
end

"""Rebuild native request messages through an explicit replaceable role/block conversion hook."""
function timeline_runtime_mapping(projection::TimelineContextProjection; mapper=timeline_native_message)
    result = Message[]
    entry_ids = String[]
    for entry in projection.entries, original in entry.messages
        converted = timeline_llm_message(original)
        if !isnothing(converted)
            message = mapper(converted, String(entry.source_entry["id"]), deepcopy(original))
            if !(message isa Message)
                error("Timeline runtime mapper must return a native Message")
            end
            push!(result, message)
            push!(entry_ids, String(entry.source_entry["id"]))
        end
    end
    (messages=result, entry_ids=entry_ids)
end
timeline_runtime_mapping(timeline; leaf=missing, mapper=timeline_native_message) =
    timeline_runtime_mapping(timeline_projection(timeline; leaf); mapper)
timeline_runtime_messages(timeline; kwargs...) = timeline_runtime_mapping(timeline; kwargs...).messages
timeline_runtime_entry_ids(timeline; kwargs...) = timeline_runtime_mapping(timeline; kwargs...).entry_ids

function timeline_archived_metadata(::Nothing)
    nothing
end
function timeline_archived_metadata(result::ExecutionResult)
    record = Dict{String,Any}("format" => "execution_result", "ok" => result.ok, "text" => result.text)
    if timeline_json_value(result.value)
        record["value"] = deepcopy(result.value)
    else
        record["transientValueType"] = string(typeof(result.value))
    end
    record
end
function timeline_archived_metadata(metadata::ProviderMessageMetadata)
    Dict{String,Any}("format"=>"provider_context","original"=>timeline_archived_metadata(metadata.original),"context"=>deepcopy(metadata.context))
end
function timeline_archived_metadata(metadata)
    if !timeline_json_value(metadata)
        error("Native message metadata needs a JSON-safe archival adapter")
    end
    Dict{String,Any}("format" => "json", "value" => deepcopy(metadata))
end

"""Archive native roles/kinds separately from Pi roles, without inventing tool call identities."""
function timeline_archive_message(message::Message; timestamp=floor(Int, time() * 1000),
        provider_message=nothing, provider=nothing, model=nothing, api=nothing)
    if message.metadata isa TimelineMessageMetadata
        previous = message.metadata
        if get(previous.projected, "role", nothing) in ("branchSummary", "compactionSummary")
            error("Synthetic context messages must retain their original summary entry, not become appended messages")
        end
        if message.role != Symbol(previous.llm_message["role"]) || message.kind != :text ||
                message.content != timeline_native_text(previous.llm_message["content"]) ||
                any(!isnothing, (provider_message, provider, model, api))
            error("Edited projected messages require an explicit context-edit/archive adapter")
        end
        timeline_object(previous.projected)
    else
        native = Dict{String,Any}("format" => "JuliaForever2.message.v1", "role" => String(message.role),
            "kind" => String(message.kind), "metadata" => timeline_archived_metadata(message.metadata))
        role = message.role == :code_result ? "custom" : String(message.role)
        if !(role in ("system", "user", "assistant", "custom"))
            error("Native role needs an explicit archival adapter: $(message.role)")
        end
        if !isnothing(provider_message)
            if message.role != :assistant || !(provider_message isa AbstractDict &&
                    get(provider_message, "role", nothing) == "assistant" && timeline_json_value(provider_message))
                error("Provider archive payload must be a JSON-safe assistant message")
            end
            native["providerMessage"] = timeline_object(provider_message)
        end
        content = role == "assistant" ? [Dict("type" => "text", "text" => message.content)] : message.content
        result = Dict{String,Any}("role" => role, "content" => content, "timestamp" => timestamp, "jf2" => native)
        if !isnothing(provider_message)
            for key in ("provider", "model", "api", "usage", "stopReason", "responseId", "responseModel", "providerThinkingLevel")
                if haskey(provider_message, key)
                    result[key] = deepcopy(provider_message[key])
                end
            end
        end
        for (key, value) in (("provider", provider), ("model", model), ("api", api))
            if !isnothing(value)
                if role != "assistant" || !(value isa Union{AbstractString,Symbol}) || isempty(String(value)) ||
                        haskey(result, key) && result[key] != String(value)
                    error("Missing, conflicting or invalid assistant provider/model identity")
                end
                result[key] = String(value)
            end
        end
        if role == "custom"
            result["customType"] = "juliaforever.code_result"
            result["display"] = true
        end
        result
    end
end

"""Preserve pre-existing native compacted context during migration, without altering Pi summaries."""
function native_plain_compaction(message)
    native = get(message, "jf2", nothing)
    native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.compaction.v1" &&
        get(native, "contextSummaryFormat", nothing) == "native-plain"
end

provider_message_context(metadata::TimelineMessageMetadata)=metadata.projected
