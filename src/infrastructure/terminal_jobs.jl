module TerminalJobs
using Libdl,SHA,JSON

"""Use an explicitly installed native ABI bridge; no compiler, download or reference harness runs on launch."""
Base.@kwdef struct TerminalJobAdapter
    library::String=normpath(joinpath(@__DIR__,"..","..","deps","usr","lib","libjf2_terminal_jobs."*Libdl.dlext))
end
const LIBRARY_LOCK=ReentrantLock()
const LIBRARIES=Dict{String,Ptr{Cvoid}}()
function terminal_library(adapter::TerminalJobAdapter)
    lock(LIBRARY_LOCK) do
        get!(LIBRARIES,adapter.library) do
            Sys.islinux() || error("Native terminal job control currently requires Linux GNU libc")
            isfile(adapter.library) || error("Native terminal job control is not built; run julia scripts/build_terminal_jobs.jl with a C compiler")
            metadata_path=adapter.library*".json"
            isfile(metadata_path) || error("Native terminal job-control build metadata is missing; rebuild the adapter")
            metadata=JSON.parsefile(metadata_path)
            source=normpath(joinpath(@__DIR__,"..","..","deps","native","terminal_jobs.c"))
            get(metadata,"source_sha256",nothing)==bytes2hex(sha256(read(source))) || error("Native terminal job-control source changed; rebuild the adapter")
            get(metadata,"library_sha256",nothing)==bytes2hex(sha256(read(adapter.library))) || error("Native terminal job-control binary verification failed; rebuild the adapter")
            library=Libdl.dlopen(adapter.library)
            abi=ccall(Libdl.dlsym(library,:jf2_terminal_abi),Cuint,())
            if abi!=0x00010000
                Libdl.dlclose(library)
                error("Unsupported native terminal job-control ABI")
            end
            library
        end
    end
end
terminal_symbol(adapter::TerminalJobAdapter,name::Symbol)=Libdl.dlsym(terminal_library(adapter),name)
terminal_error(operation,code)=string(operation,": ",Base.Libc.strerror(code)," (",code,")")

"""Own one child group, its saved foreground terminal, and its unreaped process identity."""
Base.@kwdef mutable struct TerminalJob
    adapter::TerminalJobAdapter
    pointer::Ptr{Cvoid}
    finished::Bool=false
    exit_code::Int=-1
    signal::Int=0
    stopped_signal::Int=0
    restored::Bool=false
    closed::Bool=false
end

"""Atomically establish an owned foreground child group before exec, without changing parent signal handlers."""
spawn_terminal_job(adapter::TerminalJobAdapter,arguments::Vector{String};kwargs...)=spawn_owned_job(adapter,:jf2_terminal_spawn,arguments;kwargs...)
spawn_pipe_job(adapter::TerminalJobAdapter,arguments::Vector{String};kwargs...)=spawn_owned_job(adapter,:jf2_pipe_spawn,arguments;kwargs...)
function spawn_owned_job(adapter::TerminalJobAdapter,entry::Symbol,arguments::Vector{String};directory::String,input_fd::Integer,output_fd::Integer,error_fd::Integer,environment=ENV)
    valid=!isempty(arguments) && all(value->!occursin('\0',value),arguments) && !occursin('\0',directory)
    valid || error("Terminal job arguments contain NUL or lack an executable")
    entries=[string(key,"=",value) for (key,value) in environment]
    all(value->!occursin('\0',value),entries) || error("Terminal job environment contains NUL")
    argv=Ptr{UInt8}[pointer(value) for value in arguments];push!(argv,C_NULL)
    envp=Ptr{UInt8}[pointer(value) for value in entries];push!(envp,C_NULL)
    pointer_out=Ref{Ptr{Cvoid}}(C_NULL)
    code=GC.@preserve arguments entries argv envp begin
        ccall(terminal_symbol(adapter,entry),Cint,
            (Ref{Ptr{Cvoid}},Cstring,Ptr{Ptr{UInt8}},Ptr{Ptr{UInt8}},Cint,Cint,Cint),
            pointer_out,directory,argv,envp,input_fd,output_fd,error_fd)
    end
    job=pointer_out[]==C_NULL ? nothing : TerminalJob(;adapter,pointer=pointer_out[],finished=code!=0)
    (ok=code==0,reason=code==0 ? "" : terminal_error("Terminal job spawn failed",code),job)
end

function poll_terminal_job!(job::TerminalJob)
    if job.closed
        (ok=true,reason="",finished=job.finished,exit_code=job.exit_code,signal=job.signal,stopped_signal=job.stopped_signal)
    else
        finished=Ref{Cint}(0);exit_code=Ref{Cint}(-1);signal=Ref{Cint}(0)
        code=ccall(terminal_symbol(job.adapter,:jf2_terminal_poll),Cint,(Ptr{Cvoid},Ref{Cint},Ref{Cint},Ref{Cint}),job.pointer,finished,exit_code,signal)
        if code==0
            job.finished=finished[]!=0;job.exit_code=Int(exit_code[]);job.signal=Int(signal[])
            stopped=Ref{Cint}(0)
            code=ccall(terminal_symbol(job.adapter,:jf2_terminal_stopped),Cint,(Ptr{Cvoid},Ref{Cint}),job.pointer,stopped)
            code==0 && (job.stopped_signal=Int(stopped[]))
        end
        (ok=code==0,reason=code==0 ? "" : terminal_error("Terminal job wait failed",code),finished=job.finished,exit_code=job.exit_code,signal=job.signal,stopped_signal=job.stopped_signal)
    end
end

"""Signal only the still-unreaped child process group whose session and group identity remain verified."""
function signal_terminal_job!(job::TerminalJob,signal::Integer)
    code=job.closed ? 0 : ccall(terminal_symbol(job.adapter,:jf2_terminal_signal),Cint,(Ptr{Cvoid},Cint),job.pointer,signal)
    (ok=code==0,reason=code==0 ? "" : terminal_error("Terminal job signal failed",code))
end

function restore_terminal_job!(job::TerminalJob)
    code=job.closed || job.restored ? 0 : ccall(terminal_symbol(job.adapter,:jf2_terminal_restore),Cint,(Ptr{Cvoid},),job.pointer)
    code==0 && (job.restored=true)
    (ok=code==0,reason=code==0 ? "" : terminal_error("Terminal foreground restoration failed",code))
end

function close_terminal_job!(job::TerminalJob)
    state=poll_terminal_job!(job)
    if !state.ok || !state.finished
        (ok=false,reason=state.ok ? "Terminal job is still running" : state.reason)
    else
        restored=restore_terminal_job!(job)
        code=!restored.ok || job.closed ? 0 : ccall(terminal_symbol(job.adapter,:jf2_terminal_release),Cint,(Ptr{Cvoid},),job.pointer)
        if restored.ok
            job.closed=true;job.pointer=C_NULL
        end
        (ok=restored.ok && code==0,reason=!restored.ok ? restored.reason : code==0 ? "" : terminal_error("Terminal job release failed",code))
    end
end
end
