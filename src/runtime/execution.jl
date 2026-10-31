function default_evaluate!(session::Session, action)
    executor = session.runtime.executor
    context = current_execution_context()
    return applicable(execute!, executor, action, context) ?
        Base.invokelatest(execute!, executor, action, context) :
        Base.invokelatest(execute!, executor, session, action, context)
end

"""Preserve existing callable and four-argument providers at the compatibility boundary."""
respond(provider, messages, session, context::ExecutionContext) = provider(messages, session)

function respond_model(provider, request::ModelRequest, session::Session, context::ExecutionContext)
    return applicable(respond, provider, request, context) ?
        Base.invokelatest(respond, provider, request, context) :
        Base.invokelatest(respond, provider, request.messages, session, context)
end

apply_decision!(session::Session, answer::Answer, context) = ExecutionResult(true, answer.content)
apply_decision!(session::Session, failure::Failure, context) = ExecutionResult(false, failure.content)

function apply_decision!(session::Session, decision::ActionDecision, context)
    result = evaluate!(session, action_payload(decision.action); context)
    append_message!(session, Message(:code_result, result.text; metadata=result))
    emit!(context, HarnessEvent(:execution, result))
    return nothing
end

function default_loop!(session::Session, prompt::AbstractString, max_steps::Integer)
    context = current_execution_context()
    append_message!(session, Message(:user, prompt))
    for _ in 1:max_steps
        cancelled(context) && return stopped_result()
        messages = history_snapshot(session).messages
        response = with_component(session.kernel, :provider) do provider
            protocol = operation_protocol(session.definition, provider)
            request = model_request(protocol, messages, session)
            Base.invokelatest(respond_model, provider, request, session, context)
        end
        isnothing(response) && return ExecutionResult(false, "No provider is configured.")
        usage = response_usage(response)
        isnothing(usage) || record_usage!(session, usage)
        cancelled(context) && return stopped_result()
        reply = response_reply(response)
        decision = Base.invokelatest(agent_decision, reply)
        decision isa Failure && return apply_decision!(session, decision, context)
        append_message!(session, Base.invokelatest(decision_message, decision))
        emit!(context, HarnessEvent(:response_committed, (operation_id=operation_id(context),)))
        emit!(context, HarnessEvent(:reply, reply))
        outcome = Base.invokelatest(apply_decision!, session, decision, context)
        isnothing(outcome) || return outcome
    end
    return ExecutionResult(false, "Agent reached the step limit.")
end

function use_component(fallback, session::Session, name::Symbol, args...)
    with_component(session.kernel, name; fallback) do implementation
        Base.invokelatest(implementation, session, args...)
    end
end

function run_component_inline!(session::Session, context::ExecutionContext, fallback, name::Symbol, args...)
    owner_context = get(task_local_storage(), :JuliaForever2_owner_context, nothing)
    if !isnothing(owner_context) && owner_context !== context
        own_resource!(owner_context, context)
    end
    lock(session.runtime.execution_lock) do
        (!isopen(session) || cancelled(context)) && return stopped_result()
        task_local_storage(:JuliaForever2_context, context) do
            return execution_result(use_component(fallback, session, name, args...))
        end
    end
end

"""Supervise outer operations and execute nested operations under the same serialization lock."""
function run_component!(session::Session, context, fallback, name::Symbol, args...)
    execution = execution_context(context)
    if get(task_local_storage(), :JuliaForever2_runtime, nothing) === session.runtime
        return run_component_inline!(session, execution, fallback, name, args...)
    end
    handle = submit_managed!(session, session, execution) do owned_context
        run_component_inline!(session, owned_context, fallback, name, args...)
    end
    return fetch(handle)
end

evaluate!(session::Session, action; context=current_execution_context()) =
    run_component!(session, context, default_evaluate!, :executor, action)

run_turn!(session::Session, prompt::AbstractString; max_steps::Integer=20, context=current_execution_context()) =
    run_component!(session, context, default_loop!, :loop, prompt, max_steps)

function supervise_operation(worker::Task, context::ExecutionContext)
    wait(worker; throw=false)
    cleanup_failures = release_context_resources!(context)
    istaskfailed(worker) && return fetch(worker)
    isempty(cleanup_failures) || fetch(first(cleanup_failures))
    result = fetch(worker)
    completion = spawn_cleanup(() -> emit!(context, HarnessEvent(:completed, result)); owners=context.owners)
    fetch(completion)
    return result
end

function submit_managed!(f, owner::Session, session::Session, context::ExecutionContext)
    owners = (get(task_local_storage(), :JuliaForever2_owners, ())..., owner.runtime, session.runtime)
    owned_context = claim_context!(context, owners)
    scope = execution_task_scope(; runtime=session.runtime, context=owned_context, owner_context=owned_context, owners)
    ready = Base.Event()
    accepted = Ref(false)
    worker = spawn_scoped(scope) do
        wait(ready)
        accepted[] ? Base.invokelatest(f, owned_context) : stopped_result()
    end
    supervisor = spawn_scoped(() -> supervise_operation(worker, owned_context), scope)
    handle = TaskHandle(supervisor, session, owned_context, worker)
    lock(owner.conversation.lock) do
        if !owner.runtime.closed
            accepted[] = true
            filter!(handle -> !istaskdone(handle), owner.runtime.handles)
            filter!(isopen, owner.runtime.children)
            push!(owner.runtime.handles, handle)
            if owner !== session
                push!(owner.runtime.children, session)
                lock(session.conversation.lock) do
                    push!(session.runtime.handles, handle)
                end
            end
        end
    end
    if !accepted[]
        cancel!(owned_context)
        owner === session || close(session)
    end
    notify(ready)
    return handle
end

"""Submit a serialized turn and return its supervised task immediately."""
function submit_turn!(session::Session, prompt::AbstractString; max_steps::Integer=20, context=ExecutionContext())
    submit_managed!(session, session, context) do owned_context
        run_component_inline!(session, owned_context, default_loop!, :loop, prompt, max_steps)
    end
end

"""Submit an action and append its structured execution result to history."""
function submit_evaluation!(session::Session, action; context=ExecutionContext())
    submit_managed!(session, session, context) do owned_context
        lock(session.runtime.execution_lock) do
            (!isopen(session) || cancelled(owned_context)) && return stopped_result()
            result = run_component_inline!(session, owned_context, default_evaluate!, :executor, action)
            append_message!(session, Message(:code_result, result.text; metadata=result))
            result
        end
    end
end

function child_session(session::Session, definition::AgentDefinition, isolated)
    return Session(definition; messages=empty(session.conversation.messages))
end

function child_session(session::Session, ::Nothing, isolated::Bool)
    kernel = isolated ? fork_kernel(session.kernel) : session.kernel
    return Session(kernel; executor=fork_executor(session.runtime.executor), messages=empty(session.conversation.messages),
        definition=session.definition, owns_kernel=isolated)
end

"""Spawn a child; isolated=true snapshots composition, while an explicit definition replaces it."""
function spawn_agent!(session::Session, prompt::AbstractString; max_steps::Integer=20,
        context=child_context(current_context()), isolated::Bool=false, definition=nothing)
    child = child_session(session, definition, isolated)
    submit_managed!(session, child, context) do owned_context
        run_component_inline!(child, owned_context, default_loop!, :loop, prompt, max_steps)
    end
end

function run_child!(session::Session, prompt::AbstractString; kwargs...)
    handle = spawn_agent!(session, prompt; kwargs...)
    return (session=handle.session, result=fetch(handle))
end

function context_descends_from(context, ancestor)
    while !isnothing(context)
        context === ancestor && return true
        context = context.parent
    end
    return false
end

function executing_owned_work(session::Session)
    get(task_local_storage(), :JuliaForever2_runtime, nothing) === session.runtime && return true
    any(owner -> owner === session.runtime, get(task_local_storage(), :JuliaForever2_owners, ())) && return true
    context = current_context()
    lock(session.conversation.lock) do
        any(handle -> handle.worker === current_task() || handle.task === current_task() || context_descends_from(context, handle.context), session.runtime.handles)
    end
end

function shutdown_session!(session::Session)
    handles, children = lock(session.conversation.lock) do
        copy(session.runtime.handles), copy(session.runtime.children)
    end
    foreach(cancel!, handles)
    for handle in handles
        wait(handle; throw=false)
    end
    failures = Task[]
    for child in children
        cleanup = spawn_scoped() do
            close(child)
            wait_shutdown(child)
        end
        wait(cleanup; throw=false)
        istaskfailed(cleanup) && push!(failures, cleanup)
    end
    executor_cleanup = spawn_cleanup() do
        lock(session.runtime.execution_lock) do
            close_executor!(session.runtime.executor)
        end
    end
    wait(executor_cleanup; throw=false)
    istaskfailed(executor_cleanup) && push!(failures, executor_cleanup)
    session.runtime.executor_closed = true
    if session.runtime.owns_kernel
        kernel_cleanup = spawn_scoped(() -> close(session.kernel))
        wait(kernel_cleanup; throw=false)
        istaskfailed(kernel_cleanup) && push!(failures, kernel_cleanup)
    end
    lock(session.conversation.lock) do
        empty!(session.runtime.handles)
        empty!(session.runtime.children)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

function wait_shutdown(session::Session)
    shutdown = lock(() -> session.runtime.shutdown_task, session.runtime.shutdown_lock)
    isnothing(shutdown) || fetch(shutdown)
    return nothing
end

"""Close owned work; calls from owned workers defer their own teardown until they return."""
function Base.close(session::Session)
    shutdown = lock(session.runtime.shutdown_lock) do
        if isnothing(session.runtime.shutdown_task)
            handles = lock(session.conversation.lock) do
                session.runtime.closed = true
                copy(session.runtime.handles)
            end
            foreach(cancel!, handles)
            owners = (get(task_local_storage(), :JuliaForever2_owners, ())..., session.runtime)
            scope = execution_task_scope(; runtime=nothing, context=nothing, owner_context=nothing, owners)
            session.runtime.shutdown_task = spawn_scoped(() -> shutdown_session!(session), scope)
        end
        session.runtime.shutdown_task
    end
    executing_owned_work(session) || fetch(shutdown)
    return nothing
end
