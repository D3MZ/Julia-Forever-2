struct ExecutionResult{T}
    ok::Bool
    text::String
    value::T
end

ExecutionResult(ok::Bool, text::AbstractString, value=nothing) = ExecutionResult(ok, String(text), value)
execution_result(result::ExecutionResult) = result
execution_result(result::NamedTuple) = ExecutionResult(result.ok, result.text, get(result, :value, nothing))

struct Message{T}
    role::Symbol
    content::String
    kind::Symbol
    metadata::T
end

Message(role::Symbol, content::AbstractString, kind::Symbol=:text; metadata=nothing) = Message(role, String(content), kind, metadata)
message_result(message::Message) = message.metadata

struct Reply
    kind::Symbol
    content::String
end

struct ProviderResult{R,U}
    reply::R
    usage::U
end

response_reply(response) = response
response_reply(response::ProviderResult) = response.reply
response_usage(response) = nothing
response_usage(response::ProviderResult) = response.usage

struct HarnessEvent{T}
    kind::Symbol
    data::T
end

mutable struct ExecutionContext{F}
    stopped::Threads.Atomic{Bool}
    deadline::Float64
    interrupt::Base.Event
    sink::F
    timer::Union{Nothing,Timer}
    lock::ReentrantLock
    listeners::Vector{Base.Event}
    parent::Union{Nothing,ExecutionContext}
end

monotonic_seconds() = time_ns() / 1.0e9

function ExecutionContext(; timeout::Real=Inf, emit=Returns(nothing), event_sink=emit, parent=nothing)
    deadline = monotonic_seconds() + max(0.0, Float64(timeout))
    isnothing(parent) || (deadline = min(deadline, parent.deadline))
    context = ExecutionContext(Threads.Atomic{Bool}(false), deadline, Base.Event(), event_sink, nothing, ReentrantLock(), Base.Event[], parent)
    isnothing(parent) || register_cancellation!(parent, context.interrupt)
    if isfinite(deadline)
        context.timer = Timer(remaining_time(context)) do timer
            cancel!(context)
        end
    end
    return context
end

function cancel!(context::ExecutionContext)
    lock(context.lock) do
        context.stopped[] = true
        notify(context.interrupt)
        foreach(notify, context.listeners)
    end
    return nothing
end

function register_cancellation!(context::ExecutionContext, event::Base.Event)
    lock(context.lock) do
        push!(context.listeners, event)
        cancelled(context) && notify(event)
    end
    parent = context.parent
    isnothing(parent) || register_cancellation!(parent, event)
    return event
end

function unregister_cancellation!(context::ExecutionContext, event::Base.Event)
    lock(context.lock) do
        filter!(listener -> listener !== event, context.listeners)
    end
    parent = context.parent
    isnothing(parent) || unregister_cancellation!(parent, event)
    return nothing
end

cancelled(::Nothing) = false
cancelled(context::ExecutionContext) = context.stopped[] || monotonic_seconds() >= context.deadline || cancelled(context.parent)
remaining_time(context::ExecutionContext) = max(0.0, context.deadline - monotonic_seconds())
cancellation_event(context::ExecutionContext) = context.interrupt
emit!(context::ExecutionContext, event) = context.sink(event)
function Base.close(context::ExecutionContext)
    timer = context.timer
    isnothing(timer) || close(timer)
    parent = context.parent
    isnothing(parent) || unregister_cancellation!(parent, context.interrupt)
    return nothing
end
current_context() = get(task_local_storage(), :JuliaForever2_context, nothing)
execution_context(::Nothing) = ExecutionContext()
execution_context(context::ExecutionContext) = context
current_execution_context() = execution_context(current_context())
child_context(::Nothing) = ExecutionContext()
child_context(parent::ExecutionContext) = ExecutionContext(; parent, event_sink=parent.sink)
stopped_result() = ExecutionResult(false, "Execution cancelled.")

mutable struct Usage
    input_tokens::Int
    output_tokens::Int
    cost::Float64
    reported::Bool
    cost_known::Bool
    partial::Bool
end

Usage() = Usage(0, 0, 0.0, false, true, false)

struct JuliaExecutor
    scope::Module
    output::IOBuffer
end

JuliaExecutor() = JuliaExecutor(Module(gensym(:Agent)), IOBuffer())
fork_executor(executor) = deepcopy(executor)
fork_executor(::JuliaExecutor) = JuliaExecutor()
close_executor!(executor) = nothing

struct TaskHandle{S,C}
    task::Task
    session::S
    context::C
end

Base.fetch(handle::TaskHandle) = fetch(handle.task)
Base.wait(handle::TaskHandle; kwargs...) = (wait(handle.task; kwargs...); handle)
Base.istaskdone(handle::TaskHandle) = istaskdone(handle.task)
Base.istaskfailed(handle::TaskHandle) = istaskfailed(handle.task)
cancel!(handle::TaskHandle) = cancel!(handle.context)

mutable struct Session{E,H}
    kernel::Kernel
    messages::H
    executor::E
    lock::ReentrantLock
    execution_lock::ReentrantLock
    shutdown_lock::ReentrantLock
    usage::Usage
    revision::UInt
    changes::Vector{Int}
    handles::Vector{TaskHandle}
    children::Vector{Session}
    closed::Bool
    executor_closed::Bool
end

initialize_executor!(executor, session) = executor

function initialize_executor!(executor::JuliaExecutor, session::Session)
    scope, output = executor.scope, executor.output
    Core.eval(scope, :(using JuliaForever2))
    Core.eval(scope, :(const kernel = $(QuoteNode(session.kernel))))
    Core.eval(scope, :(const session = $(QuoteNode(session))))
    Core.eval(scope, :(const output = $(QuoteNode(output))))
    Core.eval(scope, :(include(path) = Base.include(@__MODULE__, path)))
    Core.eval(scope, :(print(args...) = Base.print(output, args...)))
    Core.eval(scope, :(print(io::IO, args...) = Base.print(io, args...)))
    Core.eval(scope, :(println(args...) = Base.println(output, args...)))
    Core.eval(scope, :(println(io::IO, args...) = Base.println(io, args...)))
    return executor
end

function Session(kernel::Kernel; executor=JuliaExecutor(), messages=Message[])
    session = Session(kernel, messages, executor, ReentrantLock(), ReentrantLock(), ReentrantLock(), Usage(), UInt(0), Int[], TaskHandle[], Session[], false, false)
    initialize_executor!(executor, session)
    return session
end

function Base.getproperty(session::Session, name::Symbol)
    name === :scope && return getproperty(getfield(session, :executor), :scope)
    name === :output && return getproperty(getfield(session, :executor), :output)
    return getfield(session, name)
end

function changed_history!(session::Session, index::Int)
    session.revision += UInt(1)
    push!(session.changes, index)
    return session.revision
end

function append_message!(session::Session, message)
    lock(session.lock) do
        push!(session.messages, message)
        changed_history!(session, length(session.messages))
    end
    return message
end

function clear_history!(session::Session)
    lock(session.lock) do
        empty!(session.messages)
        changed_history!(session, 1)
    end
    return nothing
end

function replace_message!(session::Session, index::Integer, message)
    lock(session.lock) do
        session.messages[index] = message
        changed_history!(session, Int(index))
    end
    return message
end

history_revision(session::Session) = lock(() -> session.revision, session.lock)

function history_snapshot(session::Session, known_revision=nothing)
    lock(session.lock) do
        known_revision == session.revision && return nothing
        first_change = isnothing(known_revision) || known_revision > session.revision ? 1 : Int(known_revision) + 1
        changed_from = first_change <= length(session.changes) ? minimum(@view session.changes[first_change:end]) : 1
        return (messages=copy(session.messages), revision=session.revision, changed_from)
    end
end

"""Execute code using backend-owned state; custom backends extend this method."""
execute!(executor, session, code, context::ExecutionContext) = executor(session, code)

function execute!(executor::JuliaExecutor, session, code::AbstractString, context::ExecutionContext)
    truncate(executor.output, 0)
    seekstart(executor.output)
    value = Base.include_string(executor.scope, code, "agent-code.jl")
    output = String(take!(executor.output))
    rendered = isnothing(value) ? "" : Base.invokelatest(repr, value)::String
    return ExecutionResult(true, output * rendered, value)
end

default_evaluate!(session::Session, code) = execute!(session.executor, session, code, current_execution_context())

"""Request a response; existing two-argument callable providers need no adapter."""
respond(provider, messages, session, context::ExecutionContext) = provider(messages, session)

function default_loop!(session::Session, prompt::AbstractString, max_steps::Integer)
    context = current_execution_context()
    append_message!(session, Message(:user, prompt))
    for _ in 1:max_steps
        cancelled(context) && return stopped_result()
        messages = history_snapshot(session).messages
        response = with_component(session.kernel, :provider) do provider
            Base.invokelatest(respond, provider, messages, session, context)
        end
        isnothing(response) && return ExecutionResult(false, "No provider is configured.")
        usage = response_usage(response)
        isnothing(usage) || record_usage!(session, usage)
        cancelled(context) && return stopped_result()
        reply = response_reply(response)
        reply.kind == :error && return ExecutionResult(false, reply.content)
        append_message!(session, Message(:assistant, reply.content, reply.kind))
        emit!(context, HarnessEvent(:reply, reply))
        reply.kind == :answer && return ExecutionResult(true, reply.content)
        reply.kind == :code || return ExecutionResult(false, "Unsupported reply kind: $(reply.kind)")
        result = evaluate!(session, reply.content; context)
        append_message!(session, Message(:code_result, result.text; metadata=result))
        emit!(context, HarnessEvent(:execution, result))
    end
    return ExecutionResult(false, "Agent reached the step limit.")
end

function use_component(fallback, session::Session, name::Symbol, args...)
    with_component(session.kernel, name; fallback) do implementation
        Base.invokelatest(implementation, session, args...)
    end
end

function evaluate!(session::Session, code; context=current_execution_context())
    lock(session.execution_lock) do
        (!isopen(session) || cancelled(context)) && return stopped_result()
        task_local_storage(:JuliaForever2_context, context) do
            result = use_component(default_evaluate!, session, :executor, code)
            return execution_result(result)
        end
    end
end

function run_turn!(session::Session, prompt::AbstractString; max_steps::Integer=20, context=current_execution_context())
    lock(session.execution_lock) do
        (!isopen(session) || cancelled(context)) && return stopped_result()
        task_local_storage(:JuliaForever2_context, context) do
            result = use_component(default_loop!, session, :loop, prompt, max_steps)
            return execution_result(result)
        end
    end
end

function submit_managed!(f, owner::Session, session::Session, context::ExecutionContext)
    ready = Base.Event()
    accepted = Ref(false)
    task = Threads.@spawn begin
        wait(ready)
        result = accepted[] ? f() : stopped_result()
        emit!(context, HarnessEvent(:completed, result))
        close(context)
        result
    end
    handle = TaskHandle(task, session, context)
    lock(owner.lock) do
        if !owner.closed
            accepted[] = true
            filter!(handle -> !istaskdone(handle), owner.handles)
            filter!(isopen, owner.children)
            push!(owner.handles, handle)
            if owner !== session
                push!(owner.children, session)
                lock(session.lock) do
                    push!(session.handles, handle)
                end
            end
        end
    end
    if !accepted[]
        cancel!(context)
        owner === session || close(session)
    end
    notify(ready)
    return handle
end

"""Submit a serialized turn and return its managed task immediately."""
function submit_turn!(session::Session, prompt::AbstractString; max_steps::Integer=20, context=ExecutionContext())
    submit_managed!(session, session, context) do
        run_turn!(session, prompt; max_steps, context)
    end
end

"""Submit code without blocking the caller and append its structured result to history."""
function submit_evaluation!(session::Session, code; context=ExecutionContext())
    submit_managed!(session, session, context) do
        lock(session.execution_lock) do
            (!isopen(session) || cancelled(context)) && return stopped_result()
            result = evaluate!(session, code; context)
            append_message!(session, Message(:code_result, result.text; metadata=result))
            result
        end
    end
end

"""Create a child inheriting the current turn's cancellation; an explicit context detaches it."""
function spawn_agent!(session::Session, prompt::AbstractString; max_steps::Integer=20, context=child_context(current_context()))
    child = Session(session.kernel; executor=fork_executor(session.executor), messages=empty(session.messages))
    submit_managed!(session, child, context) do
        run_turn!(child, prompt; max_steps, context)
    end
end

function run_child!(session::Session, prompt::AbstractString; kwargs...)
    handle = spawn_agent!(session, prompt; kwargs...)
    return (session=handle.session, result=fetch(handle))
end

"""Cancel owned jobs, wait for cooperative completion, and close executor-owned resources."""
function Base.close(session::Session)
    lock(session.shutdown_lock) do
        session.executor_closed && return nothing
        handles, children = lock(session.lock) do
            session.closed = true
            copy(session.handles), copy(session.children)
        end
        foreach(cancel!, handles)
        for handle in handles
            handle.task === current_task() || wait(handle; throw=false)
            close(handle.context)
        end
        foreach(close, children)
        lock(session.execution_lock) do
            close_executor!(session.executor)
            session.executor_closed = true
        end
        lock(session.lock) do
            empty!(session.handles)
            empty!(session.children)
        end
    end
    return nothing
end

Base.isopen(session::Session) = lock(() -> !session.closed, session.lock)
