"""Queue input on this session only; closed sessions cannot accept new user work."""
function queue_input!(session::Session, message; kind::Symbol=:steering)
    if isopen(session)
        queue_input!(session.runtime.pending_inputs, message; kind)
    else
        (ok=false, reason="Session is closed", id=nothing)
    end
end

set_input_queue_mode!(session::Session, kind::Symbol, mode) = isopen(session) ? set_input_queue_mode!(session.runtime.pending_inputs, kind, mode) : (ok=false, reason="Session is closed")
pending_input_snapshot(session::Session) = pending_input_snapshot(session.runtime.pending_inputs)
peek_pending_inputs(session::Session) = peek_pending_inputs(session.runtime.pending_inputs)
clear_pending_inputs!(session::Session; kwargs...) = clear_pending_inputs!(session.runtime.pending_inputs; kwargs...)

"""Append through the synchronous journal boundary before removing an input from its queue."""
function deliver_pending_inputs!(session::Session, kind::Symbol, context::ExecutionContext)
    inputs = session.runtime.pending_inputs
    lock(inputs.lock) do
        batch = pending_input_batch(inputs, kind)
        delivered = PendingInput[]
        for item in batch
            if !cancelled(context) && isopen(session)
                append_message!(session, item.message)
                queue = pending_input_queue(inputs, Val(kind))
                index = findfirst(queued -> queued.id == item.id, queue)
                isnothing(index) || deleteat!(queue, index)
                inputs.revision += UInt64(1)
                push!(delivered, item)
                emit!(context, HarnessEvent(:queued_input_delivered,
                    (id=item.id, kind=item.kind, message=item.message, operation_id=operation_id(context))))
            end
        end
        delivered
    end
end

function next_pending_kind(session::Session; follow_up::Bool=true)
    inputs = session.runtime.pending_inputs
    lock(inputs.lock) do
        !isempty(inputs.steering) ? :steering : follow_up && !isempty(inputs.follow_up) ? :follow_up : :none
    end
end

"""Track whether this request already received a batch, preventing double delivery during preparation."""
Base.@kwdef mutable struct PendingInputBoundary{S}
    session::S
    delivered::Bool = false
end

refresh_prepared_inputs!(boundary, session, context) = nothing
function refresh_prepared_inputs!(boundary::PendingInputBoundary, session::Session, context::ExecutionContext)
    if boundary.session === session && !boundary.delivered && !cancelled(context)
        delivered = deliver_pending_inputs!(session, :steering, context)
        boundary.delivered = !isempty(delivered)
    end
    nothing
end

"""Pick up input queued during compaction without delivering a second one-at-a-time batch."""
refresh_prepared_inputs!(session::Session, context::ExecutionContext) =
    refresh_prepared_inputs!(get(task_local_storage(), :JuliaForever2_pending_boundary, nothing), session, context)

"""Run native requests, delivering steering after whole actions and follow-ups only at natural stop."""
function pending_turn_loop!(session::Session, max_steps::Integer, context::ExecutionContext; continuation::Bool=false)
    outcome = nothing
    step = 0
    kind = continuation ? next_pending_kind(session) : :steering
    if continuation && kind == :none
        outcome = ExecutionResult(false, "No queued input is available.")
    end
    while step < max_steps && isnothing(outcome)
        delivered = cancelled(context) ? PendingInput[] : deliver_pending_inputs!(session, kind, context)
        boundary = PendingInputBoundary(session, !isempty(delivered))
        outcome = task_local_storage(:JuliaForever2_pending_boundary, boundary) do
            advance!(session, context)
        end
        step += 1
        if !cancelled(context) && (isnothing(outcome) || outcome.ok)
            kind = next_pending_kind(session; follow_up=!isnothing(outcome))
            if kind != :none
                outcome = nothing
            elseif isnothing(outcome)
                kind = :steering
            end
        end
    end
    finish(outcome)
end

function default_loop!(session::Session, ::Nothing, max_steps::Integer)
    pending_turn_loop!(session, max_steps, current_execution_context(); continuation=true)
end

"""Continue retained queues without inventing an empty user message or replacing the executor."""
function submit_queued_turn!(session::Session; max_steps::Integer=20, context=ExecutionContext())
    submit_managed!(session, session, context) do owned_context
        run_component_inline!(session, owned_context, default_loop!, :loop, nothing, max_steps)
    end
end
