struct TaskHandle{S,C}
    task::Task
    session::S
    context::C
    worker::Task
end

TaskHandle(task::Task, session, context) = TaskHandle(task, session, context, task)
Base.fetch(handle::TaskHandle) = fetch(handle.task)
Base.wait(handle::TaskHandle; kwargs...) = (wait(handle.task; kwargs...); handle)
Base.istaskdone(handle::TaskHandle) = istaskdone(handle.task)
Base.istaskfailed(handle::TaskHandle) = istaskfailed(handle.task)
cancel!(handle::TaskHandle) = cancel!(handle.context)

mutable struct SessionRuntime{E}
    executor::E
    execution_lock::ReentrantLock
    shutdown_lock::ReentrantLock
    handles::Vector{TaskHandle}
    children::Vector{AbstractSession}
    closed::Bool
    executor_closed::Bool
    owns_kernel::Bool
    shutdown_task::Union{Nothing,Task}
    working_directory::String
end

SessionRuntime(executor; owns_kernel=false, working_directory=pwd()) = SessionRuntime(executor, ReentrantLock(), ReentrantLock(),
    TaskHandle[], AbstractSession[], false, false, owns_kernel, nothing, realpath(working_directory))

mutable struct Session{C,R,D} <: AbstractSession
    kernel::Kernel
    conversation::C
    runtime::R
    definition::D
end

initialize_executor!(executor, session) = executor

"""Resolve a session include from the current included file, or from the session workspace."""
function include_in_session(session::Session, target::Module, path::AbstractString)
    source = Base.source_path()
    directory = isnothing(source) || !isfile(source) ? working_directory(session) : dirname(source)
    return Base.include(target, isabspath(path) ? path : joinpath(directory, path))
end

function initialize_executor!(executor::JuliaExecutor, session::Session)
    scope, output = executor.scope, executor.output
    Core.eval(scope, :(using JuliaForever2))
    Core.eval(scope, :(const kernel = $(QuoteNode(session.kernel))))
    Core.eval(scope, :(const session = $(QuoteNode(session))))
    Core.eval(scope, :(const output = $(QuoteNode(output))))
    Core.eval(scope, :(include(path) = JuliaForever2.include_in_session(session, @__MODULE__, path)))
    Core.eval(scope, :(print(args...) = Base.print(output, args...)))
    Core.eval(scope, :(print(io::IO, args...) = Base.print(io, args...)))
    Core.eval(scope, :(println(args...) = Base.println(output, args...)))
    Core.eval(scope, :(println(io::IO, args...) = Base.println(io, args...)))
    return executor
end

function Session(kernel::Kernel; executor=JuliaExecutor(), messages=Message[], definition=nothing, owns_kernel=false,
        working_directory=pwd())
    isdir(working_directory) || error("Session working directory is not a directory: $working_directory")
    session = Session(kernel, Conversation(messages), SessionRuntime(executor; owns_kernel, working_directory), definition)
    initialize_executor!(executor, session)
    return session
end

Session(definition::AgentDefinition; messages=Message[], working_directory=pwd()) = Session(definition_kernel(definition);
    executor=Base.invokelatest(definition.executor_factory), messages, definition, owns_kernel=true, working_directory)

const CONVERSATION_PROPERTIES = (:messages, :lock, :usage, :revision, :changes)
const RUNTIME_PROPERTIES = (:executor, :execution_lock, :shutdown_lock, :handles, :children, :closed, :executor_closed)

function Base.getproperty(session::Session, name::Symbol)
    name in CONVERSATION_PROPERTIES && return getproperty(getfield(session, :conversation), name)
    name in RUNTIME_PROPERTIES && return getproperty(getfield(session, :runtime), name)
    name === :scope && return getproperty(getfield(session, :runtime).executor, :scope)
    name === :output && return getproperty(getfield(session, :runtime).executor, :output)
    return getfield(session, name)
end

function Base.setproperty!(session::Session, name::Symbol, value)
    name in CONVERSATION_PROPERTIES && return setproperty!(getfield(session, :conversation), name, value)
    name in RUNTIME_PROPERTIES && return setproperty!(getfield(session, :runtime), name, value)
    return setfield!(session, name, value)
end

Base.propertynames(session::Session, private::Bool=false) =
    (fieldnames(typeof(session))..., CONVERSATION_PROPERTIES..., RUNTIME_PROPERTIES..., :scope, :output)

append_message!(session::Session, message) = append_message!(session.conversation, message)
clear_history!(session::Session) = clear_history!(session.conversation)
replace_message!(session::Session, index::Integer, message) = replace_message!(session.conversation, index, message)
history_revision(session::Session) = history_revision(session.conversation)
history_snapshot(session::Session, revision=nothing) = history_snapshot(session.conversation, revision)
record_usage!(session::Session, report) = record_usage!(session.conversation, report)
usage_label(session::Session) = usage_label(session.conversation)

Base.isopen(session::Session) = lock(() -> !session.runtime.closed, session.conversation.lock)

"""Read the session's workspace independently of the process-wide working directory."""
working_directory(session::Session) = lock(() -> session.runtime.working_directory, session.runtime.execution_lock)

"""Resolve a path against the session's workspace without changing process state."""
function workspace_path(session::Session, path::AbstractString)
    lock(session.runtime.execution_lock) do
        directory = session.runtime.working_directory
        return normpath(isabspath(path) ? path : joinpath(directory, path))
    end
end

"""Change a session's workspace only when the destination exists as a directory."""
function set_working_directory!(session::Session, path::AbstractString)
    return lock(session.runtime.execution_lock) do
        isopen(session) || return (ok=false, reason="Session is closed")
        isempty(path) && return (ok=false, reason="Working directory cannot be empty")
        destination = workspace_path(session, path)
        isdir(destination) || return (ok=false, reason="Not a directory: $destination")
        session.runtime.working_directory = realpath(destination)
        return (ok=true, reason="")
    end
end
