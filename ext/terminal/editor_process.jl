"""Own exactly one explicitly requested external editor process and its cancellation flag."""
Base.@kwdef mutable struct ExternalEditorProcess
    process::Union{Nothing,Base.Process,JuliaForever2.TerminalJobs.TerminalJob}=nothing
    cancelled::Threads.Atomic{Bool}=Threads.Atomic{Bool}(false)
    started::Bool=false
    completed::Bool=false
end

"""Resolve user configuration before VISUAL, EDITOR and the platform's documented default."""
function external_editor_command(configured::Union{Nothing,AbstractString}=nothing;environment=ENV,windows=Sys.iswindows())
    if !isnothing(configured) && !isempty(strip(configured))
        String(configured)
    else
        visual=get(environment,"VISUAL","");editor=get(environment,"EDITOR","")
        !isempty(visual) ? String(visual) : !isempty(editor) ? String(editor) : windows ? "notepad" : "nano"
    end
end

cancel_external_editor!(owner::ExternalEditorProcess)=(owner.cancelled[]=true;nothing)
external_editor_failure(reason;cancelled=false,exit_code=nothing)=(ok=false,reason=string(reason),content=nothing,cancelled,exit_code)

"""Read only the owned prompt file, refusing replacement aliases, oversized output or invalid UTF-8."""
function external_editor_read(path::String,max_bytes::Int)
    if islink(path) || !isfile(path)
        error("External editor prompt was removed or replaced by a link; prompt unchanged")
    elseif filesize(path)>max_bytes
        error("External editor prompt exceeds the configured size limit; prompt unchanged")
    else
        bytes=read(path);content=String(bytes)
        isvalid(content) || error("External editor prompt is not valid UTF-8; prompt unchanged")
        startswith(content,'\ufeff') && (content=chop(content;head=1,tail=0))
        endswith(content,'\n') && (content=chop(content;tail=1))
        String(content)
    end
end

external_editor_running(process::Base.Process)=process_running(process)
external_editor_wait!(process::Base.Process)=wait(process)
external_editor_signal!(process::Base.Process,signal)=kill(process,signal)
external_editor_release!(::Base.Process)=nothing
external_editor_exit_status(process::Base.Process)=(code=Int(process.exitcode),signal=Int(process.termsignal))
external_editor_check_stop!(::Base.Process)=nothing
function external_editor_check_stop!(job::JuliaForever2.TerminalJobs.TerminalJob)
    if job.stopped_signal!=0
        error("External editor stopped (signal $(job.stopped_signal)); suspend is unavailable and prompt is unchanged")
    end
    nothing
end
function external_editor_running(job::JuliaForever2.TerminalJobs.TerminalJob)
    state=JuliaForever2.TerminalJobs.poll_terminal_job!(job)
    state.ok || error(state.reason)
    !state.finished
end
function external_editor_wait!(job::JuliaForever2.TerminalJobs.TerminalJob)
    while external_editor_running(job)
        sleep(0.005)
    end
    nothing
end
function external_editor_signal!(job::JuliaForever2.TerminalJobs.TerminalJob,signal)
    result=JuliaForever2.TerminalJobs.signal_terminal_job!(job,signal)
    result.ok || error(result.reason)
    nothing
end
function external_editor_release!(job::JuliaForever2.TerminalJobs.TerminalJob)
    result=JuliaForever2.TerminalJobs.close_terminal_job!(job)
    result.ok || error(result.reason)
    nothing
end
external_editor_exit_status(job::JuliaForever2.TerminalJobs.TerminalJob)=(code=job.exit_code,signal=job.signal)
function external_editor_spawn!(owner::ExternalEditorProcess,::Nothing,arguments,directory,input,output,errors)
    process=run(pipeline(ignorestatus(Cmd(Cmd(arguments);dir=directory));stdin=input,stdout=output,stderr=errors);wait=false)::Base.Process
    owner.process=process
    process
end
function external_editor_spawn!(owner::ExternalEditorProcess,adapter::JuliaForever2.TerminalJobs.TerminalJobAdapter,arguments,directory,input,output,errors)
    result=JuliaForever2.TerminalJobs.spawn_terminal_job(adapter,arguments;directory,
        input_fd=Base.cconvert(Cint,Base._fd(input)),output_fd=Base.cconvert(Cint,Base._fd(output)),error_fd=Base.cconvert(Cint,Base._fd(errors)))
    owner.process=result.job
    result.ok || error(result.reason)
    result.job::JuliaForever2.TerminalJobs.TerminalJob
end

function external_editor_exit(owner::ExternalEditorProcess,path::String,max_bytes::Int)
    process=owner.process
    isnothing(process) && error("External editor has no completed process; prompt unchanged")
    exit=external_editor_exit_status(process)
    if owner.cancelled[]
        external_editor_failure("External editor cancelled; prompt unchanged";cancelled=true)
    elseif exit.code!=0 || exit.signal!=0
        signal=get(Dict(2=>"SIGINT",9=>"SIGKILL",15=>"SIGTERM"),exit.signal,"signal $(exit.signal)")
        detail=exit.signal==0 ? "code $(exit.code)" : signal
        external_editor_failure("External editor exited with $detail; prompt unchanged";exit_code=exit.code)
    else
        (ok=true,reason="",content=external_editor_read(path,max_bytes),cancelled=false,exit_code=0)
    end
end

"""Launch the configured editor with literal argv and caller-owned terminal IO, never through a shell."""
function external_editor_launch!(owner::ExternalEditorProcess,command::String,path::String,directory::String;input,output,errors,on_started,job_adapter=nothing)
    arguments=String.(split(command,' ';keepempty=true));push!(arguments,path)
    process=external_editor_spawn!(owner,job_adapter,arguments,directory,input,output,errors)
    Base.invokelatest(on_started,owner)
    while external_editor_running(process) && !owner.cancelled[]
        external_editor_check_stop!(process)
        sleep(0.005)
    end
    owner.cancelled[] && external_editor_running(process) && external_editor_signal!(process,Base.SIGTERM)
    if owner.cancelled[]
        Base.timedwait(()->!external_editor_running(process),0.2;pollint=0.005)
        external_editor_running(process) && external_editor_signal!(process,Base.SIGKILL)
    end
    external_editor_wait!(process)
    nothing
end

function external_editor_cleanup!(owner::ExternalEditorProcess,directory::Union{Nothing,String})
    process=owner.process
    if !isnothing(process) && external_editor_running(process)
        external_editor_signal!(process,Base.SIGKILL);external_editor_wait!(process)
    end
    isnothing(process) || external_editor_release!(process)
    isnothing(directory) || !ispath(directory) || rm(directory;recursive=true,force=true)
    owner.completed=true
    nothing
end

"""Return edited text only after a real successful exit and cleanup; every failure preserves the caller's draft."""
edit_external_text(command::AbstractString,content::AbstractString;kwargs...)=edit_external_text(String(command),String(content);kwargs...)
function edit_external_text(command::String,content::String;directory::AbstractString=pwd(),
        owner::ExternalEditorProcess=ExternalEditorProcess(),input=devnull,output=devnull,errors=devnull,
        temporary_root::AbstractString=tempdir(),max_bytes::Int=50*1024*1024,on_started=Returns(nothing),job_adapter=nothing)
    if owner.started || owner.completed
        external_editor_failure("External editor process owner is already used; prompt unchanged")
    elseif owner.cancelled[]
        external_editor_failure("External editor cancelled; prompt unchanged";cancelled=true)
    else
        owner.started=true;temporary=Ref{Union{Nothing,String}}(nothing);phase=Ref(:prepare)
        attempt=preference_attempt() do
            max_bytes>=0 || error("External editor size limit must be nonnegative")
            ncodeunits(content)<=max_bytes || error("External editor input exceeds the configured size limit; prompt unchanged")
            created=mktempdir(temporary_root;prefix="jf2-editor-")
            temporary[]=created
            chmod(created,0o700);path=joinpath(created,"prompt.md")
            open(path,"w") do io
                chmod(path,0o600);write(io,content)
            end
            phase[]=:launch
            external_editor_launch!(owner,String(command),path,abspath(directory);input,output,errors,on_started,job_adapter)
            phase[]=:read
            external_editor_exit(owner,path,max_bytes)
        end
        cleanup=preference_attempt(()->external_editor_cleanup!(owner,temporary[]))
        if !cleanup.ok
            external_editor_failure("External editor cleanup failed: "*cleanup.reason)
        elseif !attempt.ok
            reason=phase[]==:launch && isnothing(owner.process) && isnothing(job_adapter) ? "Failed to launch external editor: "*String(command) : attempt.reason
            external_editor_failure(reason;cancelled=owner.cancelled[])
        else
            attempt.value
        end
    end
end
