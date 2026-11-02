"""Persist an execution receipt before starting, then retain its outcome until verified archival commit."""
function user_shell_receipt(run::UserShellRun;result=nothing)
    record=Dict{String,Any}("format"=>"JuliaForever2.user-shell-recovery.v1","id"=>string(run.id),
        "sessionId"=>string(run.session_id),"archiveId"=>run.archive_id,"command"=>run.command,
        "excludeFromContext"=>run.excluded,"cwd"=>run.directory,"state"=>"started")
    if result isa JuliaForever2.UserShellProcess.Result
        record["state"]=result.ok ? "executed-uncommitted" : "failed"
        record["reason"]=result.reason
        record["message"]=result.ok ? JuliaForever2.user_shell_record(JuliaForever2.user_shell_message(run.command,result;exclude_from_context=run.excluded,execution_id=run.id,timestamp=run.timestamp)) : nothing
    end
    record
end
function user_shell_write_receipt!(run::UserShellRun;result=nothing)
    text=JSON.json(user_shell_receipt(run;result))*"\n"
    run.digest=JuliaForever2.timeline_replace_file(run.checkpoint,text,isempty(run.digest) ? nothing : run.digest)
    nothing
end
function prepare_user_shell(app::App,request)
    root=joinpath(app.settings.directory,"shell-results")
    islink(root) && error("Shell recovery directory cannot be a symbolic link")
    isdir(root) || mkpath(root;mode=0o700)
    directory=mktempdir(root;prefix="execution-");chmod(directory,0o700)
    timeline=app.archive.timeline
    isnothing(timeline) && error("Shell execution requires an initialized session archive")
    run=UserShellRun(;session_id=app.session.runtime.id,archive_id=timeline.identity.id,
        command=request.command,excluded=request.exclude_from_context,directory=app.settings.workspace,
        checkpoint=joinpath(directory,"result.json"),digest="",deferred=app.busy)
    user_shell_write_receipt!(run)
    run
end

"""Publish only the latest bounded process output; one queued wake-up drains the mailbox."""
function user_shell_stream!(app::App,run::UserShellRun,chunk::String)
    ready=lock(run.lock) do
        run.mailbox=join(run.process.output.chunks)
        pending=!run.notified;run.notified=true
        pending
    end
    ready && enqueue_event!(app,TaskEvent(:user_shell_stream,run.id))
    nothing
end
function user_shell_stream_received!(app::App,id)
    run=app.operations.shell.active
    if !isnothing(run) && run.id==id
        lock(run.lock) do
            run.visible=run.mailbox;run.notified=false
        end
    end
    nothing
end

"""Extensions may supply a real result or replace execution; errors never fall through to local commands."""
function execute_user_shell(app::App,run::UserShellRun,interceptor,adapter,shell,prefix)
    outcome=JuliaForever2.UserShellProcess.attempt() do
        event=(command=run.command,exclude_from_context=run.excluded,cwd=run.directory)
        override=isnothing(interceptor) ? nothing : Base.invokelatest(interceptor,event)
        on_chunk=chunk->user_shell_stream!(app,run,String(chunk))
        result=if override isa JuliaForever2.UserShellProcess.Result
            override
        elseif override isa UserShellExecution
            Base.invokelatest(override.execute,event;on_chunk=chunk->begin
                delta=JuliaForever2.UserShellOutput.feed!(run.process.output,Vector{UInt8}(codeunits(String(chunk))))
                user_shell_stream!(app,run,delta)
            end,cancelled=()->run.cancelled[])
        elseif isnothing(override)
            JuliaForever2.UserShellProcess.execute(run.command;operation=run.process,directory=run.directory,
                adapter,shell,prefix,on_chunk,cancelled=()->run.cancelled[])
        else
            error("User shell interceptor must return nothing, a real Result, or UserShellExecution")
        end
        result isa JuliaForever2.UserShellProcess.Result || error("User shell operation returned no native Result")
        result
    end
    result=outcome.ok ? outcome.value::JuliaForever2.UserShellProcess.Result : JuliaForever2.UserShellProcess.Result(;ok=false,reason=outcome.reason)
    cleanup=JuliaForever2.UserShellProcess.attempt(()->JuliaForever2.UserShellOutput.close!(run.process.output))
    cleanup.ok || (result=JuliaForever2.UserShellProcess.Result(;ok=false,reason="Shell output cleanup failed: "*cleanup.reason))
    receipt=JuliaForever2.UserShellProcess.attempt(()->user_shell_write_receipt!(run;result))
    (result,receipt_ok=receipt.ok,receipt_reason=receipt.reason)
end

"""Start one explicitly submitted command without replacing the active agent operation or granting hidden permissions."""
function start_user_shell!(app::App,request)
    state=app.operations.shell
    if app.operations.closing[] || !isopen(app.session)
        (ok=false,reason="Session is closed")
    elseif !isnothing(state.active)
        app.status="A bash command is already running. Press Esc to cancel it first."
        (ok=false,reason=app.status)
    elseif any(run->run.uncertain,state.pending)
        app.status="Resolve the uncommitted shell result before running another command."
        (ok=false,reason=app.status)
    elseif app.busy && app.operations.active_kind ∉ (:turn,:evaluation,:compaction_done)
        app.status="Finish the current session operation before running a shell command."
        (ok=false,reason=app.status)
    else
        prepared=JuliaForever2.UserShellProcess.attempt(()->prepare_user_shell(app,request))
        if !prepared.ok
            app.status=prepared.reason
            (ok=false,reason=app.status)
        else
            run=prepared.value::UserShellRun
            state.active=run
            interceptor,adapter,shell,prefix=state.interceptor,state.adapter,state.shell,state.prefix
            task=Threads.@spawn execute_user_shell(app,run,interceptor,adapter,shell,prefix)
            run.task=task
            notify_completion!(app,:user_shell_done,task,run)
            Tachikoma.clear!(app.input);app.menu=false;app.status="Running shell command…"
            (ok=true,reason="")
        end
    end
end

"""Cancel only the owned shell worker; process-group manipulation remains serialized inside it."""
function cancel_user_shell!(app::App)
    run=app.operations.shell.active
    if !isnothing(run)
        run.cancelled[]=true;app.status="Cancelling shell command…"
    end
    !isnothing(run)
end
function user_shell_owner_matches(app::App,run::UserShellRun)
    timeline=app.archive.timeline
    app.session.runtime.id==run.session_id && !isnothing(timeline) && timeline.identity.id==run.archive_id
end
user_shell_blocked(app::App)=!isnothing(app.operations.shell.active) || !isempty(app.operations.shell.pending)
function require_user_shell_idle!(app::App)
    blocked=user_shell_blocked(app)
    blocked && (app.status="Finish or reconcile the active shell execution before changing session history.")
    !blocked
end

"""Commit journal-first only after agent tool ordering is complete; uncertain writes are never blindly retried."""
function flush_user_shell!(app::App)
    state=app.operations.shell
    if !app.busy && !app.operations.closing[]
        active=state.active
        isnothing(active) || (active.deferred=false)
        foreach(run->(run.deferred=false),state.pending)
        blocked=false
        for run in state.pending
            if blocked
                nothing
            elseif run.uncertain
                app.status=run.reason;blocked=true
            elseif !user_shell_owner_matches(app,run)
                run.uncertain=true;run.reason="Shell result belongs to another session; retained at "*run.checkpoint
                app.status=run.reason;blocked=true
            else
                message=run.message
                outcome=JuliaForever2.UserShellProcess.attempt() do
                    isnothing(message) && error("Completed shell result has no archival message")
                    user_shell_archive_owned(app) || error("Shell history journal owner changed; no append submitted")
                    lock(app.session.runtime.execution_lock) do
                        append_message!(app.session,message)
                    end
                    readback=JuliaForever2.load_timeline(app.archive.store,run.archive_id)
                    records=JuliaForever2.timeline_messages(readback)
                    matches=filter(record->get(record,"jf2ExecutionId",nothing)==string(run.id),records)
                    length(matches)==1 && only(matches)==JuliaForever2.user_shell_record(message) || error("Shell archive readback did not confirm the exact execution")
                    true
                end
                if outcome.ok
                    run.message=nothing;app.transcript.display_key=nothing;app.status="Ready"
                    removed=JuliaForever2.UserShellProcess.attempt(()->rm(run.checkpoint))
                    if !removed.ok
                        run.reason="Shell result archived; receipt cleanup failed: "*removed.reason
                        push!(state.failures,run);app.status=run.reason
                    end
                else
                    run.uncertain=true
                    run.reason="Shell command executed, but archival outcome needs reconciliation: "*outcome.reason*". Receipt: "*run.checkpoint
                    app.status=run.reason;blocked=true
                end
            end
        end
        filter!(run->!isnothing(run.message),state.pending)
    end
    isempty(state.pending)
end

function user_shell_done!(app::App,run::UserShellRun)
    state=app.operations.shell
    if state.active===run
        task=run.task
        isnothing(task) && error("Shell completion lacks its owned task")
        outcome=JuliaForever2.UserShellProcess.attempt(()->fetch(task))
        state.active=nothing
        if !outcome.ok
            run.result=JuliaForever2.UserShellProcess.Result(;ok=false,reason=outcome.reason)
        else
            result=outcome.value
            run.result=result.result
            if !result.receipt_ok
                run.uncertain=true;run.reason="Shell outcome receipt failed: "*result.receipt_reason*". Inspect "*run.checkpoint
            end
        end
        result=run.result::JuliaForever2.UserShellProcess.Result
        run.visible=result.output
        if result.ok
            run.message=JuliaForever2.user_shell_message(run.command,result;exclude_from_context=run.excluded,execution_id=run.id,timestamp=run.timestamp)
            push!(state.pending,run)
            flush_user_shell!(app)
        else
            run.reason="Bash command failed: "*result.reason
            push!(state.failures,run);app.status=run.reason
        end
    end
    nothing
end

"""Wait for owned cleanup and preserve receipts before the frontend closes its session."""
function close_user_shell!(app::App)
    state=app.operations.shell;run=state.active
    if !isnothing(run)
        run.cancelled[]=true
        task=run.task
        isnothing(task) || wait(task;throw=false)
        user_shell_done!(app,run)
    end
    nothing
end

"""Install an explicit trusted extension interceptor without changing an already-running execution."""
function register_user_shell_interceptor!(app::App,handler::Union{Nothing,Function})
    state=app.operations.shell
    if !isnothing(state.active) || app.operations.closing[]
        (ok=false,reason="A shell execution is active or terminal is closing")
    else
        state.interceptor=handler
        (ok=true,reason="")
    end
end

"""Require the same archive observer before a shell outcome enters model-visible history."""
function user_shell_archive_owned(app::App)
    journals=component(app.session.kernel,:history_journals)
    journals isa JuliaForever2.HistoryJournals && lock(journals.lock) do
        get(journals.observers,app.session.runtime.id,nothing)===app.archive
    end
end
