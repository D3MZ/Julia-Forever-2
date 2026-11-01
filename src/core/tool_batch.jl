"""An ordered group of native tool calls with an optional dispatch concurrency bound."""
struct ToolBatch{C}
    calls::C
    max_parallel::Int
end

ToolBatch(calls::AbstractVector{<:ToolCall}; max_parallel::Integer=4) =
    ToolBatch(collect(calls), Int(max_parallel))

batch_aborted_result() = ExecutionResult(false, "Tool call aborted before dispatch")

"""Unknown, withdrawn, or invalid concurrency declarations are exclusive."""
function tool_batch_parallel(scope::ExtensionScope, call::ToolCall; tool_set=nothing)
    specification = lock(scope.lock) do
        entry = admitted_tool_entry(scope, call.name, tool_set)
        isnothing(entry) ? nothing : entry.spec
    end
    isnothing(specification) && return false
    worker = spawn_scoped(() -> Base.invokelatest(tool_concurrency_safe, specification, call.arguments))
    wait(worker; throw=false)
    return !istaskfailed(worker) && fetch(worker) === true
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
        scope::ExtensionScope, call::ToolCall, index::Int, context::ExecutionContext, tool_set)
    worker = spawn_scoped(() -> cancelled(context) ? batch_aborted_result() :
        invoke_tool!(scope, call.name, call.arguments; context, tool_set))
    pending[index] = worker
    spawn_scoped() do
        wait(worker; throw=false)
        put!(completed, index)
    end
    return nothing
end

"""Run independently registered tools with exclusive barriers and bounded opt-in parallelism.

Results stay in input order. Tools are exclusive unless their current registration
explicitly declares concurrency safety; started calls always drain on cancellation.
Each tool retains its own guard, schema, and plugin-lifetime handling.
"""
function invoke_tool_batch!(scope::ExtensionScope, calls::AbstractVector{<:ToolCall};
        max_parallel::Integer=4, context=current_execution_context(), tool_set=nothing)
    max_parallel >= 1 || error("max_parallel must be a positive integer")
    actions = collect(calls)
    results = Vector{ExecutionResult}(undef, length(actions))
    pending = Dict{Int,Task}()
    completed = Channel{Int}(max(1, length(actions)))
    execution = execution_context(context)
    index = 1
    while index <= length(actions)
        if cancelled(execution)
            for remaining in index:length(actions)
                results[remaining] = batch_aborted_result()
            end
            break
        end
        call = actions[index]
        if !tool_batch_parallel(scope, call; tool_set)
            while !isempty(pending)
                collect_tool_batch!(pending, completed, results)
            end
            cancelled(execution) && continue
            results[index] = invoke_tool!(scope, call.name, call.arguments; context=execution, tool_set)
            index += 1
        elseif length(pending) >= max_parallel
            collect_tool_batch!(pending, completed, results)
        else
            start_tool_batch!(pending, completed, scope, call, index, execution, tool_set)
            index += 1
        end
    end
    while !isempty(pending)
        collect_tool_batch!(pending, completed, results)
    end
    return results
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
