using UUIDs: UUID, uuid4, uuid5

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

struct Workspace
    path::String

    Workspace(path::String) = isdir(path) ? new(realpath(path)) : error("Session working directory is not a directory: $path")
end

Workspace(path::AbstractString) = Workspace(String(path))

Base.@kwdef mutable struct SessionRuntime{E,C}
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
    id::UUID
    parent_id::Union{Nothing,UUID}
    root_id::UUID
    compaction_settings::C
    pending_inputs::PendingInputs = PendingInputs()
end

SessionRuntime(executor; owns_kernel=false, working_directory=pwd(), id=uuid4(), parent_id=nothing,
    root_id=id, compaction=nothing) = SessionRuntime(executor, ReentrantLock(), ReentrantLock(),
    TaskHandle[], AbstractSession[], false, false, owns_kernel, nothing,
    Workspace(working_directory).path, id, parent_id, root_id, compaction, PendingInputs())

"""Preserve the prior positional runtime constructor with a fresh session-owned input queue."""
SessionRuntime(executor, execution_lock, shutdown_lock, handles, children, closed, executor_closed,
    owns_kernel, shutdown_task, working_directory, id, parent_id, root_id, compaction_settings) =
    SessionRuntime(executor, execution_lock, shutdown_lock, handles, children, closed, executor_closed,
        owns_kernel, shutdown_task, working_directory, id, parent_id, root_id, compaction_settings, PendingInputs())

mutable struct Session{C,R,D} <: AbstractSession
    kernel::Kernel
    conversation::C
    runtime::R
    definition::D
end

execute!(executor::JuliaExecutor, session::Session, code::AbstractString, ::ExecutionContext) = execute_julia!(executor, code, joinpath(working_directory(session), "agent-code.jl"))

execute!(executor::JuliaExecutor, session::Session, action::RunJulia, context::ExecutionContext) = execute!(executor, session, action.source, context)

initialize_executor!(executor, session) = executor

"""Resolve a session include from the current included file, or from the session workspace."""
function include_in_session(session::Session, target::Module, path::AbstractString)
    source = Base.source_path()
    directory = isnothing(source) || !isfile(source) ? working_directory(session) : String(dirname(source))
    relative = String(path)
    return Base.include(target, isabspath(relative) ? relative : joinpath(directory, relative))
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
        working_directory=pwd(), id=uuid4(), parent_id=nothing, root_id=id,
        compaction=nothing, compaction_entry=nothing)
    session = Session(kernel, Conversation(messages; compaction=compaction_entry),
        SessionRuntime(executor; owns_kernel, working_directory, id, parent_id, root_id,
            compaction), definition)
    initialize_executor!(executor, session)
    return session
end

Session(definition::AgentDefinition; messages=Message[], working_directory=pwd(), id=uuid4(),
    parent_id=nothing, root_id=id, compaction=nothing, compaction_entry=nothing) =
    Session(Kernel(definition); executor=Base.invokelatest(definition.executor_factory),
        messages, definition, owns_kernel=true, working_directory, id, parent_id, root_id,
        compaction, compaction_entry)

const CONVERSATION_PROPERTIES = (:messages, :lock, :usage, :revision, :changes)
const RUNTIME_PROPERTIES = (:executor, :execution_lock, :shutdown_lock, :handles, :children, :closed, :executor_closed)

function Base.getproperty(session::Session, name::Symbol)
    if name in CONVERSATION_PROPERTIES
        getproperty(getfield(session, :conversation), name)
    elseif name in RUNTIME_PROPERTIES
        getproperty(getfield(session, :runtime), name)
    elseif name in (:scope, :output)
        getproperty(getfield(session, :runtime).executor, name)
    else
        getfield(session, name)
    end
end
function Base.setproperty!(session::Session, name::Symbol, value)
    if name in CONVERSATION_PROPERTIES
        setproperty!(getfield(session, :conversation), name, value)
    elseif name in RUNTIME_PROPERTIES
        setproperty!(getfield(session, :runtime), name, value)
    else
        setfield!(session, name, value)
    end
end
Base.propertynames(session::Session, private::Bool=false) = (fieldnames(typeof(session))..., CONVERSATION_PROPERTIES..., RUNTIME_PROPERTIES..., :scope, :output)

"""Commit an optional durable journal before changing visible session history."""
function journal_history!(session::Session, operation::Symbol, arguments...)
    journal = component(session.kernel, :history_journals)
    if journal isa HistoryJournals
        Base.invokelatest(journal, session, operation, arguments...)
    end
    nothing
end

function append_message!(session::Session, message)
    lock(session.conversation.lock) do
        journal_history!(session, :append, message)
        append_message!(session.conversation, message)
    end
end

function clear_history!(session::Session)
    lock(session.conversation.lock) do
        journal_history!(session, :clear)
        clear_history!(session.conversation)
    end
end

function replace_message!(session::Session, index::Integer, message)
    lock(session.conversation.lock) do
        checkbounds(session.messages, index)
        journal_history!(session, :replace, index, message)
        replace_message!(session.conversation, index, message)
    end
end

history_revision(session::Session) = history_revision(session.conversation)
history_snapshot(session::Session, revision=nothing) = history_snapshot(session.conversation, revision)
compaction_snapshot(session::Session) = compaction_snapshot(session.conversation)
function context_messages(session::Session)
    lock(session.conversation.lock) do
        journals = component(session.kernel, :history_journals)
        projected = journals isa HistoryJournals ? Base.invokelatest(history_journal_context, journals, session) : nothing
        isnothing(projected) ? context_messages(session.conversation) : projected
    end
end
record_usage!(session::Session, report) = record_usage!(session.conversation, report)
usage_label(session::Session) = usage_label(session.conversation)

Base.isopen(session::Session) = lock(() -> !session.runtime.closed, session.conversation.lock)

"""Read stable session identity and ancestry without retaining its parent runtime."""
session_lineage(session::Session) = (id=session.runtime.id, parent_id=session.runtime.parent_id, root_id=session.runtime.root_id)

"""Fork a Julia message prefix into a separately owned session with a fresh root identity."""
function fork_session(source::Session, messages::AbstractVector{<:Message})
    inherited = deepcopy(Message[message for message in messages])
    kernel = fork_kernel(source.kernel)
    return Session(kernel; executor=fork_executor(source.runtime.executor),
        messages=inherited, definition=source.definition, owns_kernel=true,
        working_directory=working_directory(source))
end

"""Read the session's workspace without waiting for an active turn to finish."""
working_directory(session::Session)::String = lock(() -> session.runtime.working_directory, session.conversation.lock)

"""Resolve a path against the session's workspace without changing process state."""
function workspace_path(session::Session, path::AbstractString)
    lock(session.runtime.execution_lock) do
        directory = session.runtime.working_directory
        return normpath(isabspath(path) ? path : joinpath(directory, path))
    end
end

"""Change a session's workspace only when the destination exists as a directory."""
function set_working_directory!(session::Session, path::AbstractString)
    lock(session.runtime.execution_lock) do
        if !isopen(session)
            (ok=false, reason="Session is closed")
        elseif isempty(path)
            (ok=false, reason="Working directory cannot be empty")
        else
            relocate!(session, workspace_path(session, path))
        end
    end
end

function relocate!(session::Session, destination::AbstractString)
    if isdir(destination)
        directory = realpath(destination)
        lock(session.conversation.lock) do
            session.runtime.working_directory = directory
        end
        (ok=true, reason="")
    else
        (ok=false, reason="Not a directory: $destination")
    end
end
