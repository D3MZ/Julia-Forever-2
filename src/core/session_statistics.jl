"""A sum of reported values with explicit completeness rather than fabricated zero usage."""
struct ReportedSessionTotal{T<:Real}
    value::T
    reported::Int
    expected::Int
end
session_total_complete(total::ReportedSessionTotal) = total.reported == total.expected

const SessionTokenTotals = NamedTuple{(:input,:output,:cache_read,:cache_write),NTuple{4,ReportedSessionTotal{Int}}}
const SessionAccounting = NamedTuple{(:report,:provenance,:cost_source),Tuple{UsageReport,Symbol,Symbol}}
const SessionCostBreakdown = NamedTuple{(:key,:tokens,:cost,:sources),Tuple{String,SessionTokenTotals,ReportedSessionTotal{Float64},Set{Symbol}}}

"""Immutable accounting snapshot across all archival branches, including compacted history."""
struct SessionStatistics
    id::String
    path::Union{Nothing,String}
    name::Union{Nothing,String}
    messages::NamedTuple{(:total,:user,:assistant,:tool_calls,:tool_results),NTuple{5,Int}}
    tokens::SessionTokenTotals
    cost::ReportedSessionTotal{Float64}
    cost_sources::Set{Symbol}
    breakdown::Vector{SessionCostBreakdown}
end

session_stats_string(value) = nothing
session_stats_string(value::AbstractString) = String(value)
session_stats_usage_payload(entry) = nothing
function session_stats_usage_payload(entry::AbstractDict)
    kind = get(entry,"type",nothing)
    payload = kind == "message" ? get(entry,"message",nothing) : entry
    eligible = payload isa AbstractDict && (kind in ("usage","compaction","branch_summary") ||
        (kind == "message" && get(payload,"role",nothing) in ("assistant","toolResult")))
    if eligible && (get(payload,"role",nothing) == "assistant" || haskey(payload,"usage") || haskey(payload,"jf2"))
        payload
    else
        nothing
    end
end

function session_stats_model_key(entry::AbstractDict,payload::AbstractDict)
    role = get(payload,"role",nothing)
    if role == "assistant" || get(entry,"type",nothing) == "usage"
        provider = session_stats_string(get(payload,"provider",nothing))
        model = session_stats_string(get(payload,"responseModel",get(payload,"model",nothing)))
        isnothing(provider) || isnothing(model) ? "Unattributed" : provider * "/" * model
    else
        "Tools/summaries"
    end
end

session_total_add(total,value,::Type{<:Integer}) = Base.Checked.checked_add(total,value)
function session_total_add(total,value,::Type{<:Real})
    result=total+value
    isfinite(result) || error("Session usage sum overflowed")
    result
end

function session_reported_total(values::AbstractVector,::Type{T}) where {T<:Real}
    total=zero(T);reported=0
    for value in values
        if !isnothing(value)
            total=session_total_add(total,convert(T,value),T)
            reported+=1
        end
    end
    ReportedSessionTotal(total,reported,length(values))
end

function session_usage_totals(accounting::AbstractVector{<:SessionAccounting})
    tokens = (input=session_reported_total([item.report.input_tokens for item in accounting],Int),
        output=session_reported_total([item.report.output_tokens for item in accounting],Int),
        cache_read=session_reported_total([item.report.cache_read_tokens for item in accounting],Int),
        cache_write=session_reported_total([item.report.cache_write_tokens for item in accounting],Int))
    cost = session_reported_total([item.report.cost for item in accounting],Float64)
    sources = Set{Symbol}(item.cost_source for item in accounting if !isnothing(item.report.cost))
    (; tokens,cost,sources)
end

"""Read validated metering provenance once and preserve missing counters in each grouped total."""
function session_statistics(entries::AbstractVector;id::AbstractString,path=nothing,name=nothing)
    counts = zeros(Int,5)
    accounting = SessionAccounting[]
    groups = Dict{String,Vector{SessionAccounting}}()
    order = String[]
    for entry in entries
        entry isa AbstractDict || error("Session statistics require archival entry objects")
        if get(entry,"type",nothing) == "message"
            counts[1] += 1
            message = get(entry,"message",nothing)
            message isa AbstractDict || error("Session statistics encountered a malformed message")
            role = get(message,"role",nothing)
            if role == "user"
                counts[2] += 1
            elseif role == "assistant"
                counts[3] += 1
                content = get(message,"content",nothing)
                if content isa AbstractVector
                    counts[4] += count(block -> block isa AbstractDict && get(block,"type",nothing) == "toolCall",content)
                end
            elseif role == "toolResult"
                counts[5] += 1
            end
        end
        payload = session_stats_usage_payload(entry)
        if !isnothing(payload)
            item = message_usage_accounting(payload)
            push!(accounting,item)
            key = session_stats_model_key(entry,payload)
            if !haskey(groups,key)
                groups[key] = SessionAccounting[]
                push!(order,key)
            end
            push!(groups[key],item)
        end
    end
    totals = session_usage_totals(accounting)
    breakdown = SessionCostBreakdown[]
    for key in order
        grouped = session_usage_totals(groups[key])
        positive = grouped.cost.value > 0 || any(value -> value.value > 0,values(grouped.tokens))
        unknown = !session_total_complete(grouped.cost) || any(value -> !session_total_complete(value),values(grouped.tokens))
        if positive || unknown
            push!(breakdown,(;key,grouped...))
        end
    end
    sort!(breakdown;by=item -> -item.cost.value,alg=Base.Sort.MergeSort)
    SessionStatistics(String(id),session_stats_string(path),session_stats_string(name),
        (total=counts[1],user=counts[2],assistant=counts[3],tool_calls=counts[4],tool_results=counts[5]),
        totals.tokens,totals.cost,totals.sources,breakdown)
end

"""Combine known per-kind totals without hiding incomplete metering."""
function session_combined_total(totals::ReportedSessionTotal{Int}...)
    value = foldl(Base.Checked.checked_add,(total.value for total in totals);init=0)
    ReportedSessionTotal(value,sum(total.reported for total in totals),sum(total.expected for total in totals))
end
