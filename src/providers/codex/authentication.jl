function codex_sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), executable=Sys.which("codex"))
    active_auth(flow) || return (ok=false, reason="Sign-in cancelled.")
    if isnothing(executable)
        close(flow.context)
        return (ok=false, reason="Install the Codex CLI to sign in with ChatGPT.")
    end
    output = Pipe()
    output_ownership = own_resource!(flow.context, output)
    process = run(pipeline(ignorestatus(`$executable login`); stdin=devnull, stdout=output, stderr=output); wait=false)::Base.Process
    process_ownership = own_resource!(flow.context, process; cleanup=stop_process!)
    close(output.in)
    reader = Threads.@spawn for line in eachline(output)
        url = match(r"https://[^\s]+", line)
        isnothing(url) || announce(String(url.match))
    end
    completed = wait_process!(process, flow.context)
    release!(process_ownership)
    wait(reader)
    release!(output_ownership)
    close(flow.context)
    if !active_auth(flow)
        return (ok=false, reason="Sign-in cancelled.")
    end
    return completed ? (ok=true, reason="ChatGPT / Codex connected.") : (ok=false, reason="Codex sign-in failed. Run codex login to retry.")
end
