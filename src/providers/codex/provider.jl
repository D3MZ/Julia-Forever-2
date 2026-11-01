using JSON

struct CodexProvider{P}
    executable::String
    model::String
    reasoning::String
    policy::P
end
CodexProvider(executable::AbstractString="codex"; model="gpt-6.1-terra", reasoning="max", policy=CodeModePolicy()) = CodexProvider(String(executable), String(model), String(reasoning), policy)
CodexProvider(executable::AbstractString, model::AbstractString, reasoning::AbstractString) = CodexProvider(executable; model, reasoning)
CodexProvider(provider::CodexProvider, model::AbstractString) = CodexProvider(provider.executable; model, reasoning=provider.reasoning, policy=provider.policy)
(provider::CodexProvider)(messages, session) = call_provider(provider, messages, session)

function codex_usage(events)
    report = UsageReport()
    for line in events
        event = parse_json(line)
        if event isa AbstractDict && get(event, "type", "") == "turn.completed"
            report = UsageReport(get(event, "usage", nothing))
        end
    end
    report
end
record_codex_usage!(session::Session, events) = record_usage!(session, codex_usage(events))

struct CodexRequest
    command::Cmd
    input::String
    events::String
    output::String
end

function CodexRequest(provider::CodexProvider, request::ModelRequest, directory::AbstractString)
    schema = joinpath(directory, "schema.json")
    output = joinpath(directory, "reply.json")
    events = joinpath(directory, "events.jsonl")
    input = joinpath(directory, "input.json")
    reasoning = "model_reasoning_effort=" * JSON.json(provider.reasoning)
    command = `$(provider.executable) exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C $directory --model $(provider.model) -c $reasoning --json --output-schema $schema -o $output -`
    CodexRequest(command, input, events, output)
end

function respond(provider::CodexProvider, request::ModelRequest, context::ExecutionContext)
    if cancelled(context)
        provider_failure("Request cancelled or timed out.")
    else
        mktempdir() do directory
            write(joinpath(directory, "schema.json"), JSON.json(request.schema))
            write(joinpath(directory, "input.json"), JSON.json(conversation_messages(request.messages, request.instructions)))
            execute!(CodexRequest(provider, request, directory), request.protocol, context)
        end
    end
end

function execute!(request::CodexRequest, protocol, context)
    completed = open(request.events, "w") do output
        open(request.input, "r") do input
            process = run(pipeline(ignorestatus(request.command); stdin=input, stdout=output, stderr=devnull); wait=false)::Base.Process
            ownership = own_resource!(context, process; cleanup=stop_process!)
            process_completed = wait_process!(process, context)
            release!(ownership)
            process_completed
        end
    end
    if !completed
        provider_failure(cancelled(context) ? "Request cancelled or timed out." : "Codex could not produce a response. Check that the CLI is installed and signed in.")
    elseif isfile(request.output)
        ProviderResult(decode_reply(protocol, read(request.output, String)), codex_usage(eachline(request.events)))
    else
        provider_failure("Codex did not return an agent response.")
    end
end
respond(provider::CodexProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_identity(provider::CodexProvider) = ProviderIdentity(;
    id=:codex, name="Codex", detail="(openai-codex) " * provider.model * " • " * provider.reasoning)
codex_provider_descriptor() = ProviderDescriptor(:codex, "ChatGPT / Codex", dir -> CodexProvider(); auth=codex_sign_in!, status=Returns("CLI sign-in"))
