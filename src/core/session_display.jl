"""One original transcript contribution with stable source identity and intact rich payload."""
struct TimelineDisplayItem
    source_entry_id::String
    timestamp::String
    kind::Symbol
    payload::Dict{String,Any}
end

"""A raw-entry display selection independent of context edits and model-role conversion."""
struct TimelineDisplayProjection
    entries::Vector{Dict{String,Any}}
    items::Vector{TimelineDisplayItem}
    mode::Symbol
end

"""A display decision that keeps hidden/unsupported content inspectable rather than discarding it."""
struct TimelineDisplayRecord
    item::TimelineDisplayItem
    presentation::Symbol
    visible::Bool
    related_tool_id::Union{Nothing,String}
end

"""One rendered tool call and its actual matching result, distinct from ordinary transcript messages."""
Base.@kwdef mutable struct TimelineDisplayTool
    source_entry_id::String
    call::Dict{String,Any}
    result::Union{Nothing,Dict{String,Any}} = nothing
    result_entry_id::Union{Nothing,String} = nothing
end

"""Mark display-only native messages so they cannot accidentally become model input."""
struct TimelineDisplayMetadata
    record::TimelineDisplayRecord
end
wire_metadata(::TimelineDisplayMetadata) = error("Display-only messages must not be sent as model context")

function timeline_display_items(entries::AbstractVector{<:AbstractDict})
    result = TimelineDisplayItem[]
    for entry in entries
        kind = entry["type"]
        id, timestamp = String(entry["id"]), String(entry["timestamp"])
        if kind == "custom" || kind == "usage" && get(entry, "kind", nothing) == "cache_warm"
            push!(result, TimelineDisplayItem(id, timestamp, Symbol(kind), deepcopy(entry)))
        else
            messages = timeline_context_entry_messages(entry)
            for message in messages
                push!(result, TimelineDisplayItem(id, timestamp, :message, message))
            end
            if kind in ("compaction", "branch_summary") &&
                    !isnothing(get(entry, "usage", nothing)) && !isempty(messages)
                push!(result, TimelineDisplayItem(id, timestamp, :compaction_cost,
                    Dict{String,Any}("type" => "compaction_cost", "kind" => kind, "usage" => deepcopy(entry["usage"]))))
            end
        end
    end
    result
end

"""Select Pi's raw compaction-aware display entries, or an explicitly requested full active branch."""
function timeline_display_projection(entries::AbstractVector; leaf=missing, mode::Symbol=:pi)
    if !(mode in (:pi, :archive))
        error("Display mode must be :pi or :archive")
    end
    archive = timeline_object.(entries)
    indices = timeline_context_index(archive)
    selected = ismissing(leaf) ? (isempty(archive) ? nothing : last(archive)["id"]) : leaf
    if !(isnothing(selected) || selected isa AbstractString && haskey(indices, selected))
        error("Unknown display leaf")
    end
    path = timeline_path_entries(archive, indices, selected)
    entries = mode == :pi ? timeline_context_entries(path) : path
    TimelineDisplayProjection(deepcopy(entries), timeline_display_items(entries), mode)
end
function timeline_display_projection(timeline::SessionTimeline; leaf=missing, mode::Symbol=:pi)
    lock(timeline.lock) do
        timeline_display_projection(timeline.entries; leaf=ismissing(leaf) ? timeline.leaf : leaf, mode)
    end
end

timeline_display_text(content::AbstractString) = String(content)
timeline_display_text(content::AbstractVector) = join([String(block["text"]) for block in content
    if block isa AbstractDict && get(block, "type", nothing) == "text" && get(block, "text", nothing) isa AbstractString], "")
timeline_display_text(content) = ""

function timeline_display_presentation(message::AbstractDict)
    role = get(message, "role", "unknown")
    native = get(message, "jf2", nothing)
    if native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
        own_role, kind = get(native, "role", nothing), get(native, "kind", nothing)
        if role == "custom" && own_role == "code_result" && get(message, "customType", nothing) == "juliaforever.code_result"
            :native_code_result
        elseif role == "assistant" && own_role == "assistant" && kind == "code"
            :native_code
        else
            Symbol(role)
        end
    else
        Symbol(role)
    end
end

function timeline_display_tools!(tools::Vector{TimelineDisplayTool}, pending::Dict{String,Int},
        item::TimelineDisplayItem, message::AbstractDict, retry_attempt::Integer)
    content = get(message, "content", Any[])
    if content isa AbstractVector
        for block in content
            if block isa AbstractDict && get(block, "type", nothing) == "toolCall"
                call = timeline_object(block)
                if !timeline_nonempty(get(call, "id", nothing))
                    error("Display tool call requires its actual identifier")
                end
                tool = TimelineDisplayTool(; source_entry_id=item.source_entry_id, call)
                stop = get(message, "stopReason", nothing)
                if stop in ("aborted", "error")
                    text = stop == "error" ? get(message, "errorMessage", "Error") :
                        retry_attempt > 0 ? "Aborted after $(retry_attempt) retry attempt$(retry_attempt > 1 ? "s" : "")" : "Operation aborted"
                    tool.result = Dict{String,Any}("content" => [Dict("type" => "text", "text" => text)], "isError" => true)
                else
                    pending[String(call["id"])] = length(tools) + 1
                end
                push!(tools, tool)
            end
        end
    end
    nothing
end

"""Resolve visibility and inline tools using an explicit caller-supplied custom visibility predicate."""
function timeline_display_records(projection::TimelineDisplayProjection; show_usage::Bool=false,
        custom_entry_visible=Returns(false), retry_attempt::Integer=0)
    records = TimelineDisplayRecord[]
    tools = TimelineDisplayTool[]
    pending = Dict{String,Int}()
    for source_item in projection.items
        item = TimelineDisplayItem(source_item.source_entry_id, source_item.timestamp, source_item.kind, deepcopy(source_item.payload))
        message = item.payload
        related = nothing
        visible = false
        presentation = item.kind
        if item.kind == :custom
            visible = custom_entry_visible(deepcopy(message)) === true
        elseif item.kind in (:usage, :compaction_cost)
            visible = show_usage
        else
            role = get(message, "role", "unknown")
            presentation = timeline_display_presentation(message)
            if role == "assistant"
                visible = true
                timeline_display_tools!(tools, pending, item, message, retry_attempt)
            elseif role == "user"
                visible = !isempty(timeline_display_text(get(message, "content", nothing)))
            elseif role == "custom"
                visible = get(message, "display", false) === true
            elseif role in ("bashExecution", "branchSummary", "compactionSummary")
                visible = true
            elseif role == "toolResult"
                id = get(message, "toolCallId", nothing)
                if id isa AbstractString && haskey(pending, id)
                    tool = tools[pending[id]]
                    tool.result = deepcopy(message)
                    tool.result_entry_id = item.source_entry_id
                    delete!(pending, id)
                    related = String(id)
                    visible = true
                end
            elseif role != "system"
                presentation = :unsupported
                visible = true
            end
        end
        push!(records, TimelineDisplayRecord(item, presentation, visible, related))
    end
    (records=records, tools=tools)
end
function timeline_display_records(timeline; leaf=missing, mode::Symbol=:pi, kwargs...)
    timeline_display_records(timeline_display_projection(timeline; leaf, mode); kwargs...)
end

"""Convert only presentations supported by the existing native text/code renderer."""
function timeline_display_native_message(record::TimelineDisplayRecord)
    payload = record.item.payload
    kind = record.presentation
    if kind in (:user, :assistant, :native_code, :native_code_result)
        content = get(payload, "content", nothing)
        text_only = content isa AbstractString || content isa AbstractVector &&
            all(block -> block isa AbstractDict && get(block, "type", nothing) == "text" &&
                get(block, "text", nothing) isa AbstractString, content)
        if !text_only
            error("Display needs a rich content renderer; original blocks remain in the display record")
        end
        role = kind == :native_code_result ? :code_result : kind == :user ? :user : :assistant
        message_kind = kind == :native_code ? :code : :text
        Message(role, timeline_display_text(content), message_kind; metadata=TimelineDisplayMetadata(deepcopy(record)))
    else
        error("Display presentation requires its real native renderer: $(kind)")
    end
end

"""Build display-only native text messages through a replaceable, non-silent presentation mapper."""
function timeline_display_messages(projection::TimelineDisplayProjection; mapper=timeline_display_native_message, kwargs...)
    view = timeline_display_records(projection; kwargs...)
    messages = Message[]
    for record in view.records
        if record.visible
            message = mapper(record)
            if !(message isa Message)
                error("Display mapper must return a native Message")
            end
            push!(messages, message)
        end
    end
    messages
end
function timeline_display_messages(timeline; leaf=missing, mode::Symbol=:pi, kwargs...)
    timeline_display_messages(timeline_display_projection(timeline; leaf, mode); kwargs...)
end

"""An explicit native-only visible content edit, separate from the immutable raw transcript payload."""
struct TimelineDisplayOverlay
    source_entry_id::String
    edit_entry_id::String
    content::Union{String,Vector}
end

function timeline_native_display_target(entry::AbstractDict)
    message = get(entry, "message", nothing)
    native = message isa AbstractDict ? get(message, "jf2", nothing) : nothing
    valid = native isa AbstractDict && get(native, "format", nothing) == "JuliaForever2.message.v1"
    if valid
        role, kind = get(native, "role", nothing), get(native, "kind", nothing)
        valid = role in ("user", "assistant") && get(message, "role", nothing) == role && kind in ("text", "code") ||
            role == "code_result" && kind == "text" && get(message, "role", nothing) == "custom" &&
            get(message, "customType", nothing) == "juliaforever.code_result"
    end
    valid
end

"""Read only explicit native display-edit overlays while ordinary Pi context edits remain model-only."""
function timeline_display_overlays(projection::TimelineDisplayProjection)
    entries = Dict(entry["id"] => entry for entry in projection.entries)
    overlays = Dict{String,TimelineDisplayOverlay}()
    for edit in projection.entries
        marker = get(edit, "jf2", nothing)
        marked = edit["type"] == "context_edit" && marker isa AbstractDict &&
            get(marker, "format", nothing) == "JuliaForever2.context-edit.v1" && get(marker, "display", false) === true
        if marked
            id = edit["targetId"]
            if haskey(entries, id)
                target = entries[id]
                replacement = edit["replacement"]
                content = replacement isa AbstractDict ? get(replacement, "content", nothing) : nothing
                if !timeline_native_display_target(target) || !(content isa Union{AbstractString,AbstractVector}) ||
                        any(key -> key != "content", keys(replacement))
                    error("Visible display edit requires a native target and a content-only replacement")
                end
                copy = content isa AbstractString ? String(content) : deepcopy(content)
                overlays[id] = TimelineDisplayOverlay(id, edit["id"], copy)
            end
        end
    end
    overlays
end
