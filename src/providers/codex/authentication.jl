function codex_sign_in!(flow::AuthFlow, provider::Symbol, dir::AbstractString; announce=Returns(nothing), executable=Sys.which("codex"))
    active_auth(flow) ? login!(flow, executable, announce) : (ok=false, reason="Sign-in cancelled.")
end

function login!(flow::AuthFlow, ::Nothing, announce)
    close(flow.context)
    (ok=false, reason="Install the Codex CLI to sign in with ChatGPT.")
end

function login!(flow::AuthFlow, executable::AbstractString, announce)
    output = Pipe()
    output_ownership = own_resource!(flow.context, output)
    process = run(pipeline(ignorestatus(`$executable login`); stdin=devnull, stdout=output, stderr=output); wait=false)::Base.Process
    process_ownership = own_resource!(flow.context, process; cleanup=stop_process!)
    close(output.in)
    reader = Threads.@spawn for line in eachline(output)
        url = match(r"https://[^\s]+", line)
        if !isnothing(url)
            announce(String(url.match))
        end
    end
    completed = wait_process!(process, flow.context)
    release!(process_ownership)
    wait(reader)
    release!(output_ownership)
    close(flow.context)
    if !active_auth(flow)
        (ok=false, reason="Sign-in cancelled.")
    else
        completed ? (ok=true, reason="ChatGPT / Codex connected.") : (ok=false, reason="Codex sign-in failed. Run codex login to retry.")
    end
end
