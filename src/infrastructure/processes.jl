module ProcessRuntime

using ..JuliaForever2: ExecutionContext, cancelled, remaining_time

function wait_process!(process::Base.Process, context::ExecutionContext)
    while process_running(process) && !cancelled(context)
        sleep(min(0.02, max(0.001, remaining_time(context))))
    end
    if process_running(process)
        kill(process)
        timedwait(() -> !process_running(process), 1.0; pollint=0.01)
        process_running(process) && kill(process, Base.SIGKILL)
    end
    wait(process)
    return success(process) && !cancelled(context)
end

"""Stop an owned subprocess and wait until the operating system reaps it."""
function stop_process!(process::Base.Process)
    if process_running(process)
        kill(process)
        timedwait(() -> !process_running(process), 1.0; pollint=0.01)
        process_running(process) && kill(process, Base.SIGKILL)
    end
    wait(process)
    return nothing
end

end

using .ProcessRuntime: wait_process!, stop_process!
