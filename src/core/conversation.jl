mutable struct Usage
    input_tokens::Int
    output_tokens::Int
    cost::Float64
    reported::Bool
    cost_known::Bool
    partial::Bool
end

Usage() = Usage(0, 0, 0.0, false, true, false)

usage_tokens(value) = nothing
usage_tokens(::Bool) = nothing
usage_tokens(value::Integer) = 0 <= value <= typemax(Int) ? Int(value) : nothing
usage_cost(value) = nothing
usage_cost(::Bool) = nothing
usage_cost(value::Real) = usage_cost(Float64(value))
usage_cost(value::Float64) = isfinite(value) && value >= 0 ? value : nothing

struct UsageReport
    input_tokens::Union{Nothing,Int}
    output_tokens::Union{Nothing,Int}
    cost::Union{Nothing,Float64}
end

UsageReport() = UsageReport(nothing, nothing, nothing)
UsageReport(report::UsageReport) = report
UsageReport(data) = UsageReport()
canonical(input, output, cost) = UsageReport(usage_tokens(input), usage_tokens(output), usage_cost(cost))
canonical(report::UsageReport) = canonical(report.input_tokens, report.output_tokens, report.cost)
UsageReport(data::AbstractDict) = canonical(get(data, "prompt_tokens", get(data, "input_tokens", nothing)), get(data, "completion_tokens", get(data, "output_tokens", nothing)), get(data, "cost", nothing))
normalize_usage(data) = UsageReport(data)


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

function snapshot(conversation::Conversation, known_revision)
    first_change = isnothing(known_revision) || known_revision > conversation.revision ? 1 : Int(known_revision) + 1
    changed_from = first_change <= length(conversation.changes) ? minimum(@view conversation.changes[first_change:end]) : 1
    (messages=copy(conversation.messages), revision=conversation.revision, changed_from)
end

function history_snapshot(conversation::Conversation, known_revision=nothing)
    lock(conversation.lock) do
        known_revision == conversation.revision ? nothing : snapshot(conversation, known_revision)
    end
end

function accumulate!(usage::Usage, input::Int, output::Int)
    nextinput, inputoverflow = Base.Checked.add_with_overflow(usage.input_tokens, input)
    nextoutput, outputoverflow = Base.Checked.add_with_overflow(usage.output_tokens, output)
    if inputoverflow || outputoverflow
        usage.partial = true
    else
        usage.input_tokens = nextinput
        usage.output_tokens = nextoutput
        usage.reported = true
    end
    usage
end

accumulate!(usage::Usage, input, output) = (usage.partial = true; usage)
accumulate!(usage::Usage, ::Nothing) = (usage.cost_known = false; usage)

function accumulate!(usage::Usage, cost::Float64)
    total = usage.cost + cost
    if isfinite(total)
        usage.cost = total
    else
        usage.cost_known = false
    end
    usage
end

function record_usage!(conversation::Conversation, report::UsageReport)
    report = canonical(report)
    lock(conversation.lock) do
        accumulate!(accumulate!(conversation.usage, report.input_tokens, report.output_tokens), report.cost)
    end
    nothing
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
