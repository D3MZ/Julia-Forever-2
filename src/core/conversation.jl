Base.@kwdef mutable struct Usage
    input_tokens::Int = 0
    output_tokens::Int = 0
    cache_read_tokens::Int = 0
    cache_write_tokens::Int = 0
    cost::Float64 = 0.0
    reported::Bool = false
    cost_known::Bool = true
    partial::Bool = false
    context_tokens::Union{Nothing,Int} = nothing
    cache_hit_rate::Union{Nothing,Float64} = nothing
end

usage_tokens(value) = nothing
usage_tokens(::Bool) = nothing
usage_tokens(value::Integer) = 0 <= value <= typemax(Int) ? Int(value) : nothing
usage_cost(value) = nothing
usage_cost(::Bool) = nothing
usage_cost(value::Real) = usage_cost(Float64(value))
usage_cost(value::Float64) = isfinite(value) && value >= 0 ? value : nothing
usage_cost(value::AbstractDict) = usage_cost(get(value, "total", nothing))

Base.@kwdef struct UsageReport
    input_tokens::Union{Nothing,Int} = nothing
    output_tokens::Union{Nothing,Int} = nothing
    cost::Union{Nothing,Float64} = nothing
    cache_read_tokens::Union{Nothing,Int} = nothing
    cache_write_tokens::Union{Nothing,Int} = nothing
end

UsageReport(input, output, cost) = UsageReport(input, output, cost, nothing, nothing)
UsageReport(report::UsageReport) = report
UsageReport(data) = UsageReport()

canonical(input, output, cost, read=nothing, write=nothing) =
    UsageReport(usage_tokens(input), usage_tokens(output), usage_cost(cost), usage_tokens(read), usage_tokens(write))
canonical(report::UsageReport) =
    canonical(report.input_tokens, report.output_tokens, report.cost, report.cache_read_tokens, report.cache_write_tokens)

usage_detail(data, field) = nothing
usage_detail(data::AbstractDict, field) = get(data, field, nothing)

"""Subtract cached prompt tokens without allowing negative totals or integer overflow."""
function uncached_usage_tokens(input::Int, read, write)
    remaining = input - min(input, something(read, 0))
    return remaining - min(remaining, something(write, 0))
end

function UsageReport(data::AbstractDict)
    details = get(data, "prompt_tokens_details", get(data, "input_tokens_details", nothing))
    read = get(data, "cacheRead", get(data, "cache_read_input_tokens",
        get(data, "cached_input_tokens", get(data, "cached_tokens", usage_detail(details, "cached_tokens")))))
    write = get(data, "cacheWrite", get(data, "cache_creation_input_tokens",
        usage_detail(details, "cache_write_tokens")))
    input = get(data, "input", get(data, "prompt_tokens", get(data, "input_tokens", nothing)))
    output = get(data, "output", get(data, "completion_tokens", get(data, "output_tokens", nothing)))
    # Prompt token totals include cached input in OpenAI/Codex schemas, unlike Pi and Anthropic.
    inclusive = !haskey(data, "input") && !haskey(data, "cache_read_input_tokens") &&
        !haskey(data, "cache_creation_input_tokens") &&
        (haskey(data, "prompt_tokens") || haskey(data, "cached_input_tokens") || !isnothing(details))
    validated = canonical(input, output, get(data, "cost", nothing), read, write)
    exclusive = inclusive && !isnothing(validated.input_tokens) ?
        uncached_usage_tokens(validated.input_tokens, validated.cache_read_tokens,
            validated.cache_write_tokens) : validated.input_tokens
    return UsageReport(exclusive, validated.output_tokens, validated.cost,
        validated.cache_read_tokens, validated.cache_write_tokens)
end
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
        conversation.usage.context_tokens = nothing
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

function accumulate_cache!(usage::Usage, report::UsageReport)
    read = something(report.cache_read_tokens, 0)
    write = something(report.cache_write_tokens, 0)
    nextread, readoverflow = Base.Checked.add_with_overflow(usage.cache_read_tokens, read)
    nextwrite, writeoverflow = Base.Checked.add_with_overflow(usage.cache_write_tokens, write)
    if readoverflow || writeoverflow
        usage.partial = true
    else
        usage.cache_read_tokens = nextread
        usage.cache_write_tokens = nextwrite
    end
    input = report.input_tokens
    if isnothing(input)
        usage.context_tokens = nothing
        usage.cache_hit_rate = nothing
    else
        prompt, overflow = Base.Checked.add_with_overflow(input, read)
        if !overflow
            prompt, overflow = Base.Checked.add_with_overflow(prompt, write)
        end
        usage.context_tokens = overflow ? nothing : prompt
        usage.cache_hit_rate = overflow || prompt == 0 ? nothing : (read / prompt) * 100
    end
    return usage
end

function record_usage!(conversation::Conversation, report::UsageReport)
    report = canonical(report)
    lock(conversation.lock) do
        accumulate!(accumulate!(conversation.usage, report.input_tokens, report.output_tokens), report.cost)
        accumulate_cache!(conversation.usage, report)
    end
    nothing
end

record_usage!(conversation::Conversation, data) = record_usage!(conversation, normalize_usage(data))

"""Return an immutable usage view independent of later conversation updates."""
function usage_snapshot(conversation::Conversation)
    lock(conversation.lock) do
        usage = conversation.usage
        return (input_tokens=usage.input_tokens, output_tokens=usage.output_tokens,
            cache_read_tokens=usage.cache_read_tokens, cache_write_tokens=usage.cache_write_tokens,
            context_tokens=usage.context_tokens, cache_hit_rate=usage.cache_hit_rate,
            cost=usage.cost, reported=usage.reported, cost_known=usage.cost_known,
            partial=usage.partial)
    end
end
