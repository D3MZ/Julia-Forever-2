"""An ordered group of native tool calls with an optional dispatch concurrency bound."""
struct ToolBatch{C}
    calls::C
    max_parallel::Int

    ToolBatch(calls::C, max_parallel::Int) where {C} = max_parallel >= 1 ? new{C}(calls, max_parallel) : error("max_parallel must be a positive integer")
end

ToolBatch(calls::AbstractVector{<:ToolCall}; max_parallel::Integer=4) = ToolBatch(collect(calls), Int(max_parallel))

batch_aborted_result() = ExecutionResult(false, "Tool call aborted before dispatch")

"""Unknown, withdrawn, or invalid concurrency declarations are exclusive."""
tool_batch_parallel(scope::ExtensionScope, call::ToolCall) = parallel(tool(scope, call.name), call)
parallel(::Nothing, call::ToolCall) = false

function parallel(specification::ToolSpec, call::ToolCall)
    worker = spawn_scoped(() -> Base.invokelatest(tool_concurrency_safe, specification, call.arguments))
    wait(worker; throw=false)
    !istaskfailed(worker) && fetch(worker) === true
end
"""Collect a completed dispatch without letting a failed worker strand the batch."""
function collect_tool_batch!(pending::Dict{Int,Task}, completed::Channel{Int}, results)
    index = take!(completed)
    worker = pop!(pending, index)
    wait(worker; throw=false)
    results[index] = istaskfailed(worker) ?
        ExecutionResult(false, sprint(showerror, TaskFailedException(worker))) : fetch(worker)
    return nothing
end

"""Start a call and always report its settlement, including an unexpected worker failure."""
function start_tool_batch!(pending::Dict{Int,Task}, completed::Channel{Int},
        scope::ExtensionScope, call::ToolCall, index::Int, context::ExecutionContext)
    worker = spawn_scoped(() -> cancelled(context) ? batch_aborted_result() :
        invoke_tool!(scope, call.name, call.arguments; context))
    pending[index] = worker
    spawn_scoped() do
        wait(worker; throw=false)
        put!(completed, index)
    end
    return nothing
end

"""Own the pending jobs and ordered results of one bounded tool batch."""
mutable struct BatchExecution{C,L,E}
    scope::ExtensionScope
    calls::C
    limit::L
    context::E
    results::Vector{ExecutionResult}
    pending::Dict{Int,Task}
    completed::Channel{Int}
    index::Int

    BatchExecution(scope::ExtensionScope, calls::C, limit::L, context::E) where {C,L<:Integer,E} = limit >= 1 ? new{C,L,E}(scope, calls, limit, context, Vector{ExecutionResult}(undef, length(calls)), Dict{Int,Task}(), Channel{Int}(max(1, length(calls))), 1) : error("max_parallel must be a positive integer")
end

"""Run independently registered tools with exclusive barriers and bounded opt-in parallelism.

Results stay in input order. Tools are exclusive unless their current registration
explicitly declares concurrency safety; started calls always drain on cancellation.
Each tool retains its own guard, schema, and plugin-lifetime handling.
"""
invoke_tool_batch!(scope::ExtensionScope, calls::AbstractVector{<:ToolCall}; max_parallel::Integer=4, context=current_execution_context()) = execute!(BatchExecution(scope, collect(calls), max_parallel, execution_context(context)))

function execute!(batch::BatchExecution)
    while batch.index <= length(batch.calls) && !cancelled(batch.context)
        advance!(batch)
    end
    for index in batch.index:length(batch.calls)
        batch.results[index] = batch_aborted_result()
    end
    drain!(batch)
    batch.results
end

function advance!(batch::BatchExecution)
    call = batch.calls[batch.index]
    if !tool_batch_parallel(batch.scope, call)
        drain!(batch)
        if !cancelled(batch.context)
            batch.results[batch.index] = invoke_tool!(batch.scope, call.name, call.arguments; context=batch.context)
            batch.index += 1
        end
    elseif length(batch.pending) >= batch.limit
        collect_tool_batch!(batch.pending, batch.completed, batch.results)
    else
        start_tool_batch!(batch.pending, batch.completed, batch.scope, call, batch.index, batch.context)
        batch.index += 1
    end
    batch
end

function JSONRPCTransport.drain!(batch::BatchExecution)
    while !isempty(batch.pending)
        collect_tool_batch!(batch.pending, batch.completed, batch.results)
    end
    batch
end
"""Expose a whole batch as an executable action without requiring a provider adapter."""
function execute!(executor::ToolExecutor, batch::ToolBatch, context::ExecutionContext)
    results = invoke_tool_batch!(executor.scope, batch.calls; max_parallel=batch.max_parallel, context)
    for (call, result) in zip(batch.calls, results)
        emit!(context, HarnessEvent(:tool_result, (name=call.name, result)))
    end
    return ExecutionResult(all(result -> result.ok, results),
        join((result.text for result in results), "\n"), results)
end

action_kind(::ToolBatch) = :tool_batch
action_content(batch::ToolBatch) = "tool batch ($(length(batch.calls)) calls)"
agent_decision(batch::ToolBatch) = ActionDecision(batch)
