using JSON

wire_metadata(metadata) = metadata
wire_metadata(result::ExecutionResult) = (ok=result.ok,)

function wire_content(message)
    metadata = wire_metadata(message.metadata)
    if message.kind == :text && message.role != :code_result && isnothing(metadata)
        message.content
    else
        kind = message.role == :code_result ? :code_result : message.kind
        JSON.json((kind, content=message.content, metadata))
    end
end
function conversation_messages(messages, instructions; system_role="system")
    result = Dict{String,Any}[Dict("role" => system_role, "content" => instructions)]
    for message in messages
        role = message.role == :code_result ? "user" : string(message.role)
        push!(result, Dict("role" => role, "content" => wire_content(message)))
    end
    return result
end

choice_reply(policy, data) = agent_reply(nothing)
message_reply(policy, data) = agent_reply(nothing)
message_reply(policy, data::AbstractDict) = decode_reply(policy, get(data, "content", nothing))
choice_reply(policy, data::AbstractDict) = message_reply(policy, get(data, "message", nothing))
choices_reply(policy, choices) = agent_reply(nothing)
choices_reply(policy, choices::AbstractVector) = isempty(choices) ? Reply(:error, "Provider returned no choices.") : choice_reply(policy, first(choices))
