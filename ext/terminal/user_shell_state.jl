"""Parse only directly submitted user input; expanded resources never call this function."""
function raw_user_shell(input::AbstractString)
    text=String(strip(input));excluded=startswith(text,"!!")
    command=startswith(text,"!") ? String(strip(chop(text;head=excluded ? 2 : 1,tail=0))) : ""
    isempty(command) ? nothing : (command,exclude_from_context=excluded)
end

"""Own one command separately from agent execution and publish bounded UI mailboxes."""
Base.@kwdef mutable struct UserShellRun
    id::JuliaForever2.UUID=JuliaForever2.uuid4()
    session_id::JuliaForever2.UUID
    archive_id::String
    timestamp::Int=floor(Int,time()*1000)
    command::String
    excluded::Bool
    directory::String
    checkpoint::String
    digest::String
    process::JuliaForever2.UserShellProcess.Operation=JuliaForever2.UserShellProcess.Operation()
    cancelled::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false)
    task::Union{Nothing,Task}=nothing
    lock::ReentrantLock=ReentrantLock()
    mailbox::String=""
    notified::Bool=false
    visible::String=""
    deferred::Bool=false
    expanded::Bool=false
    result::Union{Nothing,JuliaForever2.UserShellProcess.Result}=nothing
    message::Union{Nothing,Message{JuliaForever2.UserShellMetadata}}=nothing
    uncertain::Bool=false
    reason::String=""
    started_ns::UInt64=time_ns()
end

"""Expose native execution as a replaceable extension operation without interpreting callback data as commands."""
Base.@kwdef struct UserShellExecution
    execute::Function
end
Base.@kwdef mutable struct UserShellState
    active::Union{Nothing,UserShellRun}=nothing
    pending::Vector{UserShellRun}=UserShellRun[]
    failures::Vector{UserShellRun}=UserShellRun[]
    interceptor::Union{Nothing,Function}=nothing
    adapter::JuliaForever2.TerminalJobs.TerminalJobAdapter=JuliaForever2.TerminalJobs.TerminalJobAdapter()
    shell::Union{Nothing,String}=nothing
    prefix::String=""
end
