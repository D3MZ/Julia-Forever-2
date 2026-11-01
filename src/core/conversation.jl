mutable struct Usage
    input_tokens::Int
    output_tokens::Int
    cost::Float64
    reported::Bool
    cost_known::Bool
    partial::Bool
end

Usage() = Usage(0, 0, 0.0, false, true, false)

struct UsageReport
    input_tokens::Union{Nothing,Int}
    output_tokens::Union{Nothing,Int}
    cost::Union{Nothing,Float64}
end
UsageReport() = UsageReport(nothing, nothing, nothing)
UsageReport(report::UsageReport) = report
UsageReport(data::AbstractDict) = normalize_usage(data)
UsageReport(::Nothing) = UsageReport()
usage_tokens(value::Integer) = value isa Bool || value < 0 || value > typemax(Int) ? nothing : Int(value)
usage_tokens(value) = nothing
function usage_cost(value::Real)
    value isa Bool && return nothing
    normalized = Float64(value)
    return isfinite(normalized) && normalized >= 0 ? normalized : nothing
end
usage_cost(value) = nothing
normalize_usage(data) = UsageReport()
normalize_usage(data::UsageReport) = data
normalize_usage(data::AbstractDict) = UsageReport(usage_tokens(get(data, "prompt_tokens", get(data, "input_tokens", nothing))), usage_tokens(get(data, "completion_tokens", get(data, "output_tokens", nothing))), usage_cost(get(data, "cost", nothing)))


mutable struct Conversation{H}
    messages::H
    lock::ReentrantLock
    usage::Usage
    revision::UInt
    changes::Vector{Int}
end

Conversation(messages=Message[]) = Conversation(messages, ReentrantLock(), Usage(), UInt(0), Int[])

function changed_history!(conversation::Conversation, index::Int)
    conversation.revision += UInt(1)
    push!(conversation.changes, index)
    return conversation.revision
end

function append_message!(conversation::Conversation, message)
    lock(conversation.lock) do
        push!(conversation.messages, message)
        changed_history!(conversation, length(conversation.messages))
    end
    return message
end

function clear_history!(conversation::Conversation)
    lock(conversation.lock) do
        empty!(conversation.messages)
        changed_history!(conversation, 1)
    end
    return nothing
end

function replace_message!(conversation::Conversation, index::Integer, message)
    lock(conversation.lock) do
        conversation.messages[index] = message
        changed_history!(conversation, Int(index))
    end
    return message
end

history_revision(conversation::Conversation) = lock(() -> conversation.revision, conversation.lock)

function history_snapshot(conversation::Conversation, known_revision=nothing)
    lock(conversation.lock) do
        known_revision == conversation.revision && return nothing
        first_change = isnothing(known_revision) || known_revision > conversation.revision ? 1 : Int(known_revision) + 1
        changed_from = first_change <= length(conversation.changes) ? minimum(@view conversation.changes[first_change:end]) : 1
        return (messages=copy(conversation.messages), revision=conversation.revision, changed_from)
    end
end

function record_usage!(conversation::Conversation, report::UsageReport)
    report = UsageReport(usage_tokens(report.input_tokens), usage_tokens(report.output_tokens), usage_cost(report.cost))
    lock(conversation.lock) do
        usage = conversation.usage
        if !isnothing(report.input_tokens) && !isnothing(report.output_tokens)
            input, input_overflow = Base.Checked.add_with_overflow(usage.input_tokens, report.input_tokens)
            output, output_overflow = Base.Checked.add_with_overflow(usage.output_tokens, report.output_tokens)
            if input_overflow || output_overflow
                usage.partial = true
            else
                usage.input_tokens = input
                usage.output_tokens = output
                usage.reported = true
            end
        else
            usage.partial = true
        end
        if isnothing(report.cost)
            usage.cost_known = false
        else
            next_cost = usage.cost + report.cost
            if isfinite(next_cost)
                usage.cost = next_cost
            else
                usage.cost_known = false
            end
        end
    end
    return nothing
end
record_usage!(conversation::Conversation, data) = record_usage!(conversation, normalize_usage(data))

"""Return an immutable usage view independent of later conversation updates."""
function usage_snapshot(conversation::Conversation)
    lock(conversation.lock) do
        usage = conversation.usage
        return (input_tokens=usage.input_tokens, output_tokens=usage.output_tokens,
            cost=usage.cost, reported=usage.reported, cost_known=usage.cost_known,
            partial=usage.partial)
    end
end
