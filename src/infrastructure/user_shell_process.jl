module UserShellProcess
using ..TerminalJobs, ..UserShellOutput

"""Return real process outcomes separately from command exit success and archival commitment."""
Base.@kwdef struct Result
    ok::Bool
    reason::String=""
    output::String=""
    exit_code::Union{Nothing,Int}=nothing
    cancelled::Bool=false
    truncated::Bool=false
    full_output_path::Union{Nothing,String}=nothing
end

"""Own only this explicitly submitted command's process, pipe reader and output accumulator."""
Base.@kwdef mutable struct Operation
    job::Union{Nothing,TerminalJobs.TerminalJob}=nothing
    pipe::Union{Nothing,Pipe}=nothing
    input::Union{Nothing,IOStream}=nothing
    reader::Union{Nothing,Task}=nothing
    chunks::Channel{Vector{UInt8}}=Channel{Vector{UInt8}}(32)
    output::UserShellOutput.Accumulator=UserShellOutput.Accumulator()
    lock::ReentrantLock=ReentrantLock()
    started::Bool=false
    completed::Bool=false
    terminate_remaining::Bool=true
end

function attempt(operation)
    worker=Task(operation);schedule(worker);wait(worker;throw=false)
    if istaskfailed(worker)
        errors=Base.current_exceptions(worker;backtrace=false)
        (ok=false,reason=isempty(errors) ? "Shell operation failed" : sprint(showerror,first(errors).exception),value=nothing)
    else
        (ok=true,reason="",value=fetch(worker))
    end
end
function shell_path(custom::Union{Nothing,String}=nothing)
    if !isnothing(custom) && !isempty(custom)
        isfile(custom) || error("Custom shell path not found: $custom")
        custom
    elseif Sys.iswindows()
        error("Native shell process control is not implemented for Windows")
    elseif isfile("/bin/bash")
        "/bin/bash"
    else
        found=Sys.which("bash")
        isnothing(found) ? "sh" : String(found)
    end
end
function read_chunks!(operation::Operation)
    pipe=operation.pipe
    isnothing(pipe) && error("Shell output pipe is unavailable")
    while isopen(pipe.out) && !eof(pipe.out)
        bytes=readavailable(pipe.out)
        for index in 1:64*1024:length(bytes)
            put!(operation.chunks,bytes[index:min(length(bytes),index+64*1024-1)])
        end
    end
    nothing
end
function drain_chunks!(operation::Operation,on_chunk)
    count=0
    while isready(operation.chunks)
        bytes=take!(operation.chunks);count+=length(bytes)
        delta=UserShellOutput.feed!(operation.output,bytes)
        isempty(delta) || Base.invokelatest(on_chunk,delta)
    end
    count
end
function spawn!(operation::Operation,adapter::TerminalJobs.TerminalJobAdapter,arguments::Vector{String},directory::String,environment)
    pipe=Pipe();operation.pipe=pipe
    Base.link_pipe!(pipe;reader_supports_async=true,writer_supports_async=false)
    input=open("/dev/null","r");operation.input=input
    result=TerminalJobs.spawn_pipe_job(adapter,arguments;directory,
        input_fd=Base.cconvert(Cint,Base._fd(input)),output_fd=Base.cconvert(Cint,Base._fd(pipe.in)),error_fd=Base.cconvert(Cint,Base._fd(pipe.in)),environment)
    operation.job=result.job
    close(pipe.in)
    result.ok || error(result.reason)
    operation.reader=@async read_chunks!(operation)
    result.job::TerminalJobs.TerminalJob
end
function wait!(operation::Operation,job::TerminalJobs.TerminalJob,cancelled,on_chunk)
    exit_at=nothing;last_output=time_ns();cancelled_command=false;done=false
    while !done
        data=drain_chunks!(operation,on_chunk);data>0 && (last_output=time_ns())
        state=TerminalJobs.poll_terminal_job!(job);state.ok || error(state.reason)
        if Base.invokelatest(cancelled) && !cancelled_command
            stopped=TerminalJobs.signal_terminal_job!(job,Base.SIGKILL)
            stopped.ok || error(stopped.reason)
            cancelled_command=true
        elseif state.stopped_signal!=0 && !state.finished
            error("Shell command stopped (signal $(state.stopped_signal)); suspension is unavailable")
        end
        if state.finished
            isnothing(exit_at) && (exit_at=time_ns();last_output=exit_at)
            reader=operation.reader
            ended=!isnothing(reader) && istaskdone(reader)
            if ended
                fetch(reader)
                drain_chunks!(operation,on_chunk)
            end
            done=ended || (time_ns()-last_output)/1e9>=0.1
        end
        done || sleep(0.002)
    end
    cancelled_command
end

function cleanup_job!(operation::Operation)
    job=operation.job
    if !isnothing(job) && !job.closed
        state=TerminalJobs.poll_terminal_job!(job);state.ok || error(state.reason)
        if !state.finished || operation.terminate_remaining
            stopped=TerminalJobs.signal_terminal_job!(job,Base.SIGKILL);stopped.ok || error(stopped.reason)
            while !job.finished
                state=TerminalJobs.poll_terminal_job!(job);state.ok || error(state.reason)
                job.finished || sleep(0.002)
            end
        end
        released=TerminalJobs.close_terminal_job!(job);released.ok || error(released.reason)
    end
    nothing
end
function cleanup_io!(operation::Operation)
    pipe=operation.pipe
    if !isnothing(pipe)
        isopen(pipe.in) && close(pipe.in)
        isopen(pipe.out) && close(pipe.out)
    end
    input=operation.input
    isnothing(input) || isopen(input) && close(input)
    nothing
end
function cleanup_reader!(operation::Operation)
    reader=operation.reader
    if !isnothing(reader)
        close(operation.chunks)
        wait(reader;throw=false)
    end
    nothing
end
function cleanup!(operation::Operation)
    phases=(()->cleanup_job!(operation),()->cleanup_io!(operation),()->cleanup_reader!(operation),()->UserShellOutput.close!(operation.output))
    outcomes=map(attempt,phases)
    operation.completed=all(result->result.ok,outcomes)
    failures=[result.reason for result in outcomes if !result.ok]
    isempty(failures) || error(join(failures,"; "))
    nothing
end

"""Run only caller-authorized raw user shell text with isolated process ownership and bounded streaming output."""
function execute_owned(command::String;directory::String,shell::Union{Nothing,String}=nothing,prefix::String="",
        operation::Operation=Operation(),adapter::TerminalJobs.TerminalJobAdapter=TerminalJobs.TerminalJobAdapter(),
        cancelled=Returns(false),on_chunk=Returns(nothing),environment=ENV)
    performed=attempt() do
        isdir(directory) || error("Working directory does not exist: $directory\nCannot execute bash commands.")
        if Base.invokelatest(cancelled)
            Result(;ok=true,cancelled=true)
        else
            executable=shell_path(shell);resolved=isempty(prefix) ? command : prefix*"\n"*command
            job=spawn!(operation,adapter,[executable,"-c",resolved],directory,environment)
            was_cancelled=wait!(operation,job,cancelled,on_chunk)
            output=UserShellOutput.finish!(operation.output)
            isempty(output.final_chunk) || Base.invokelatest(on_chunk,output.final_chunk)
            code=was_cancelled ? nothing : job.signal==0 ? job.exit_code : 128+job.signal
            operation.terminate_remaining=was_cancelled
            Result(;ok=true,output=output.output,exit_code=code,cancelled=was_cancelled,truncated=output.truncated,full_output_path=output.full_output_path)
        end
    end
    cleaned=attempt(()->cleanup!(operation))
    if !cleaned.ok
        Result(;ok=false,reason="Shell cleanup failed: "*cleaned.reason)
    elseif !performed.ok
        Result(;ok=false,reason=performed.reason)
    else
        performed.value::Result
    end
end
function execute(command::String;operation::Operation=Operation(),kwargs...)
    accepted=lock(operation.lock) do
        available=!operation.started && !operation.completed
        available && (operation.started=true)
        available
    end
    accepted ? execute_owned(command;operation,kwargs...) : Result(;ok=false,reason="Shell operation owner is already used")
end

end
