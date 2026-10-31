using JSON

struct CodexProvider{P}
    executable::String
    model::String
    reasoning::String
    policy::P
end
CodexProvider(executable::AbstractString="codex"; model="gpt-6.1-terra", reasoning="max", policy=CodeModePolicy()) = CodexProvider(String(executable), String(model), String(reasoning), policy)
CodexProvider(executable::AbstractString, model::AbstractString, reasoning::AbstractString) = CodexProvider(executable; model, reasoning)
(provider::CodexProvider)(messages, session) = call_provider(provider, messages, session)

function codex_usage(events)
    report = UsageReport()
    for line in events
        event = parse_json(line)
        event isa AbstractDict || continue
        get(event, "type", "") == "turn.completed" && (report = normalize_usage(get(event, "usage", nothing)))
    end
    return report
end
record_codex_usage!(session::Session, events) = record_usage!(session, codex_usage(events))

function respond(provider::CodexProvider, request::ModelRequest, context::ExecutionContext)
    cancelled(context) && return provider_failure("Request cancelled or timed out.")
    schema = request.schema
    conversation = conversation_messages(request.messages, request.instructions)
    return mktempdir() do directory
        schemafile = joinpath(directory, "schema.json")
        outfile = joinpath(directory, "reply.json")
        eventsfile = joinpath(directory, "events.jsonl")
        inputfile = joinpath(directory, "input.json")
        write(schemafile, JSON.json(schema))
        write(inputfile, JSON.json(conversation))
        reasoning = "model_reasoning_effort=" * JSON.json(provider.reasoning)
        command = `$(provider.executable) exec --ephemeral --ignore-user-config --skip-git-repo-check --sandbox read-only -C $directory --model $(provider.model) -c $reasoning --json --output-schema $schemafile -o $outfile -`
        completed = open(eventsfile, "w") do output
            open(inputfile, "r") do input
                process = run(pipeline(ignorestatus(command); stdin=input, stdout=output, stderr=devnull); wait=false)::Base.Process
                ownership = own_resource!(context, process; cleanup=stop_process!)
                process_completed = wait_process!(process, context)
                release!(ownership)
                process_completed
            end
        end
        completed || return provider_failure(cancelled(context) ? "Request cancelled or timed out." : "Codex could not produce a response. Check that the CLI is installed and signed in.")
        isfile(outfile) || return provider_failure("Codex did not return an agent response.")
        return ProviderResult(decode_reply(request.protocol, read(outfile, String)), codex_usage(eachline(eventsfile)))
    end
end

respond(provider::CodexProvider, messages, session, context::ExecutionContext) = legacy_provider_response(provider, messages, session, context)

provider_id(::CodexProvider) = :codex
provider_name(::CodexProvider) = "Codex"
provider_detail(provider::CodexProvider) = "(openai-codex) " * provider.model * " • " * provider.reasoning
codex_provider_descriptor() = ProviderDescriptor(:codex, "ChatGPT / Codex", dir -> CodexProvider();
    auth=codex_sign_in!, status=Returns("CLI sign-in"))
