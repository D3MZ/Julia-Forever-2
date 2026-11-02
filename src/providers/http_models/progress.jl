"""Coalesce semantic previews without executing tools or exposing the adapter's raw response JSON."""
Base.@kwdef mutable struct HTTPModelProgress{P}
    policy::P
    interval::Float64=1/30
    last_update::Float64=-Inf
end
function model_preview_text(state::ModelStreamState)
    sprint() do io
        for (index,block) in enumerate(state.message["content"])
            if get(block,"type",nothing)=="text"
                buffer=get(state.text_buffers,index,nothing)
                if isnothing(buffer)
                    print(io,get(block,"text",""))
                else
                    saved=position(buffer)
                    seekstart(buffer)
                    write(io,read(buffer))
                    seek(buffer,saved)
                end
            end
        end
    end
end
function publish_model_progress!(progress::HTTPModelProgress,state::ModelStreamState;force::Bool=false)
    now=monotonic_seconds()
    if isempty(state.error) && !cancelled(state.context) && (force || now-progress.last_update>=progress.interval)
        text=model_preview_text(state)
        if !isempty(text)
            emit_protocol_progress!(progress.policy,text,state.context)
            progress.last_update=now
        end
    end
    nothing
end
"""Interrupted streams keep observed input facts but cannot claim final output totals or complete cost."""
function model_completion_usage(state::ModelStreamState)
    observed=model_reported_usage(state)
    if !isempty(state.error) || get(state.message,"stopReason",nothing) in ("error","aborted")
        UsageReport(observed.input_tokens,nothing,nothing,observed.cache_read_tokens,observed.cache_write_tokens)
    else
        observed
    end
end
function model_completion_provenance(state::ModelStreamState,report::UsageReport)
    provenance=model_usage_provenance(report)
    if !isempty(state.error) || get(state.message,"stopReason",nothing) in ("error","aborted")
        provenance["completionState"]="partial-or-unavailable"
        provenance["observedTotalsFinal"]=false
    end
    provenance
end
