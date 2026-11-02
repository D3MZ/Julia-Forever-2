"""One user-owned pending message, not yet present in durable conversation history."""
struct PendingInput
    id::UInt64
    kind::Symbol
    message::Message
end

"""Session-local queues with independently selectable batch sizes and one delivery owner."""
Base.@kwdef mutable struct PendingInputs
    lock::ReentrantLock = ReentrantLock()
    steering::Vector{PendingInput} = PendingInput[]
    follow_up::Vector{PendingInput} = PendingInput[]
    steering_mode::Symbol = :one_at_a_time
    follow_up_mode::Symbol = :one_at_a_time
    next_id::UInt64 = UInt64(1)
    revision::UInt64 = UInt64(0)
    closed::Bool = false
end

pending_input_kind(kind::Symbol) = kind in (:steering, :follow_up)
pending_input_queue(inputs::PendingInputs, ::Val{:steering}) = inputs.steering
pending_input_queue(inputs::PendingInputs, ::Val{:follow_up}) = inputs.follow_up
pending_input_mode(inputs::PendingInputs, ::Val{:steering}) = inputs.steering_mode
pending_input_mode(inputs::PendingInputs, ::Val{:follow_up}) = inputs.follow_up_mode
pending_mode_value(value) = nothing
pending_mode_value(value::AbstractString) = value == "all" ? :all : value == "one-at-a-time" ? :one_at_a_time : nothing
pending_mode_value(value::Symbol) = value in (:all, :one_at_a_time) ? value : nothing
pending_mode_label(value::Symbol) = value == :all ? "all" : "one-at-a-time"

function set_input_queue_mode!(inputs::PendingInputs, kind::Symbol, value)
    mode = pending_mode_value(value)
    if !pending_input_kind(kind) || isnothing(mode)
        (ok=false, reason="Unsupported pending-input queue or mode")
    else
        lock(inputs.lock) do
            if inputs.closed
                (ok=false, reason="Session input queues are closed")
            else
                if kind == :steering
                    inputs.steering_mode = mode
                else
                    inputs.follow_up_mode = mode
                end
                inputs.revision += UInt64(1)
                (ok=true, reason="")
            end
        end
    end
end

function queue_input!(inputs::PendingInputs, message::Message; kind::Symbol=:steering)
    if !pending_input_kind(kind) || message.role != :user || isempty(strip(message.content))
        (ok=false, reason="Pending input must be a nonempty user message with a supported queue", id=nothing)
    else
        lock(inputs.lock) do
            if inputs.closed
                (ok=false, reason="Session input queues are closed", id=nothing)
            else
                item = PendingInput(inputs.next_id, kind, message)
                inputs.next_id += UInt64(1)
                inputs.revision += UInt64(1)
                push!(pending_input_queue(inputs, Val(kind)), item)
                (ok=true, reason="", id=item.id)
            end
        end
    end
end

queue_input!(inputs::PendingInputs, text::AbstractString; kwargs...) = queue_input!(inputs, Message(:user, text); kwargs...)

"""Snapshot complete pending queues without exposing their mutable vectors."""
function pending_input_snapshot(inputs::PendingInputs)
    lock(inputs.lock) do
        (steering=copy(inputs.steering), follow_up=copy(inputs.follow_up),
            steering_mode=pending_mode_label(inputs.steering_mode), follow_up_mode=pending_mode_label(inputs.follow_up_mode), revision=inputs.revision)
    end
end

function pending_input_batch(inputs::PendingInputs, kind::Symbol)
    queue = pending_input_queue(inputs, Val(kind))
    count = pending_input_mode(inputs, Val(kind)) == :all ? length(queue) : min(length(queue), 1)
    queue[1:count]
end

"""Preview the next complete batch with steering taking priority over follow-ups."""
function peek_pending_inputs(inputs::PendingInputs)
    lock(inputs.lock) do
        pending_input_batch(inputs, isempty(inputs.steering) ? :follow_up : :steering)
    end
end

function clear_pending_inputs!(inputs::PendingInputs; kind::Symbol=:all)
    if kind == :all || pending_input_kind(kind)
        lock(inputs.lock) do
            removed = kind == :all ? vcat(inputs.steering, inputs.follow_up) : copy(pending_input_queue(inputs, Val(kind)))
            kind in (:all, :steering) && empty!(inputs.steering)
            kind in (:all, :follow_up) && empty!(inputs.follow_up)
            inputs.revision += UInt64(1)
            (ok=true, reason="", removed)
        end
    else
        (ok=false, reason="Unsupported pending-input queue", removed=PendingInput[])
    end
end

"""Close admission atomically with enqueue, retaining undelivered input for explicit recovery."""
function close_pending_inputs!(inputs::PendingInputs)
    lock(inputs.lock) do
        inputs.closed = true
    end
    nothing
end
