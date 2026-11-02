# Native prompt-cache diagnostics. Source contract: Pi MIT, licenses/pi-LICENSE.
public SessionCacheMiss, session_cache_misses

"""A cache observation keeps unavailable prices and request timing distinct from zero."""
struct SessionCacheMiss
    tokens::Int
    estimated_cost::Union{Nothing,Float64}
    idle_ms::Union{Nothing,Float64}
    model_changed::Bool
end

struct SessionCacheRequest
    tokens::Int
    model::Union{Nothing,String}
    timestamp::Union{Nothing,Float64}
    reported_cache::Bool
end

cache_timestamp(value) = nothing
cache_timestamp(::Bool) = nothing
cache_timestamp(value::Real) = isfinite(value) && value >= 0 ? Float64(value) : nothing
cache_timestamp(value::AbstractString) = timeline_valid_timestamp(value) ? 1000 * timeline_timestamp_seconds(value) : nothing

function cache_model_key(message::AbstractDict)
    provider, model = get(message,"provider",nothing), get(message,"model",nothing)
    provider isa AbstractString && model isa AbstractString ? String(provider) * "/" * String(model) : nothing
end

cache_prompt_tokens(report::UsageReport) = cache_prompt_tokens(report.input_tokens,report.cache_read_tokens,report.cache_write_tokens)
cache_prompt_tokens(input,read,written) = nothing
function cache_prompt_tokens(input::Int,read::Int,written::Int)
    valid = input>=0 && read>=0 && written>=0 && input<=typemax(Int)-read && input+read<=typemax(Int)-written
    valid ? input+read+written : nothing
end

"""Imported or catalog prices can estimate waste, but are never called confirmed charges."""
function cache_miss_estimate(message::AbstractDict,report::UsageReport,missed::Int,read_price)
    raw=usage_detail(usage_detail(message,"usage"),"cost")
    input=usage_cost(usage_detail(raw,"input"))
    written=usage_cost(usage_detail(raw,"cacheWrite"))
    read=usage_cost(usage_detail(raw,"cacheRead"))
    paid_tokens=cache_prompt_tokens(report.input_tokens,0,report.cache_write_tokens)
    paid=isnothing(input)||isnothing(written)||isnothing(paid_tokens) ? nothing : paid_tokens>0 ? (input+written)/paid_tokens : 0.0
    read_tokens=report.cache_read_tokens
    cached=isnothing(read_tokens) ? nothing : read_tokens>0 ? (isnothing(read) ? nothing : read/read_tokens) : usage_cost(read_price(message))
    estimate=isnothing(paid)||isnothing(cached) ? nothing : missed*max(0.0,paid-cached)
    isnothing(estimate) || !isfinite(estimate) ? nothing : estimate
end

function cache_request_miss(previous::SessionCacheRequest,message::AbstractDict,report::UsageReport,tokens::Int,timestamp,read_price)
    read_tokens=report.cache_read_tokens
    if isnothing(read_tokens)
        nothing
    else
        activity=read_tokens>0 || something(report.cache_write_tokens,0)>0
        missed=min(previous.tokens,tokens)-read_tokens
        if tokens<=0 || (!activity && !previous.reported_cache) || missed<=1024
            nothing
        else
            key=cache_model_key(message)
            idle=isnothing(timestamp)||isnothing(previous.timestamp) ? nothing : max(0.0,timestamp-previous.timestamp)
            changed=!isnothing(key)&&!isnothing(previous.model)&&key!=previous.model
            SessionCacheMiss(missed,cache_miss_estimate(message,report,missed,read_price),idle,changed)
        end
    end
end
cache_request_miss(::Nothing,message,report,tokens,timestamp,read_price)=nothing

"""Derive notices from one active archive branch without modifying history or making provider requests."""
function session_cache_misses(entries::AbstractVector;read_price=Returns(nothing))
    previous=nothing
    misses=Dict{String,SessionCacheMiss}()
    for entry in entries
        if entry isa AbstractDict
            kind=get(entry,"type",nothing)
            if kind in ("compaction","branch_summary")
                previous=nothing
            elseif kind=="message" && usage_detail(get(entry,"message",nothing),"role")=="assistant"
                message=entry["message"]
                report=message_usage_accounting(message).report
                tokens=cache_prompt_tokens(report)
                timestamp=cache_timestamp(get(message,"timestamp",get(entry,"timestamp",nothing)))
                if isnothing(tokens)
                    # An unknown intervening prompt cannot establish a cache-loss claim.
                    previous=nothing
                else
                    miss=cache_request_miss(previous,message,report,tokens,timestamp,read_price)
                    id=get(entry,"id",nothing)
                    isnothing(miss)||!(id isa AbstractString)||(misses[String(id)]=miss)
                    if tokens>0
                        activity=something(report.cache_read_tokens,0)>0 || something(report.cache_write_tokens,0)>0
                        sticky=!isnothing(previous)&&previous.reported_cache
                        previous=SessionCacheRequest(tokens,cache_model_key(message),timestamp,activity||sticky)
                    end
                end
            elseif kind=="usage" && get(entry,"kind",nothing)=="cache_warm"
                report=message_usage_accounting(entry).report
                tokens=cache_prompt_tokens(report)
                if !isnothing(tokens) && tokens>0
                    previous=SessionCacheRequest(tokens,cache_model_key(entry),cache_timestamp(get(entry,"timestamp",nothing)),true)
                else
                    previous=nothing
                end
            end
        end
    end
    misses
end
