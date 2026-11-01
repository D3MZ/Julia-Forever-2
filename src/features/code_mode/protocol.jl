const CODE_MODE_INSTRUCTIONS = """
You are the model in a Julia agent harness. Respond with a JSON object containing exactly the
string fields kind and content. For an action, return kind=code and Julia source in content;
the host executes it and supplies a user message with kind=code_result and its output.
Return kind=answer when the user's request is complete or no action is needed.
Assistant messages preserve their original kind and content as JSON. Code executes with the
user's permissions in a persistent Julia module with kernel, session, include, print, println,
and the JuliaForever2 exports. Install components with install!(kernel, ComponentSpec(:name,
value; requires=[:dependency])). Layer behavior with wrap_component! around the current
component. spawn_agent! returns a TaskHandle immediately; fetch(handle) waits for its result
and handle.session contains the child session. Generated Julia follows the success path
without exception handling. Inspect code results before claiming an action completed.
"""

struct CodeModePolicy
    instructions::String
end
CodeModePolicy() = CodeModePolicy(CODE_MODE_INSTRUCTIONS)
prompt_instructions(policy::CodeModePolicy, session) = policy.instructions
prompt_instructions(instructions::AbstractString, session) = String(instructions)
reply_schema(policy) = Dict("type" => "object", "properties" => Dict("kind" => Dict("type" => "string", "enum" => ["code", "answer"]), "content" => Dict("type" => "string")), "required" => ["kind", "content"], "additionalProperties" => false)
reply_format(policy) = Dict("type" => "json_object")

function Reply(data::AbstractDict)
    kind = get(data, "kind", nothing)
    content = get(data, "content", nothing)
    kind in ("code", "answer") && content isa AbstractString ? Reply(Symbol(kind), String(content)) : Reply(:error, "Provider returned an invalid agent response.")
end
agent_reply(data::AbstractDict) = Reply(data)
agent_reply(data) = Reply(:error, "Provider returned an invalid agent response.")
decode_reply(text::AbstractString) = agent_reply(parse_json(text))
decode_reply(value) = agent_reply(nothing)
decode_reply(policy, text) = decode_reply(text)

ModelRequest(protocol, messages, session=nothing) = ModelRequest(messages, String(prompt_instructions(protocol, session)), reply_schema(protocol), reply_format(protocol), protocol)
model_request(protocol, messages, session=nothing) = ModelRequest(protocol, messages, session)
provider_protocol(provider) = hasproperty(provider, :policy) ? getproperty(provider, :policy) : CodeModePolicy()

action_content(action) = repr(action)
action_content(action::RunJulia) = action.source
action_kind(action) = :action
action_kind(::RunJulia) = :code
action_payload(action) = action
action_payload(action::RunJulia) = action.source

Message(answer::Answer) = Message(:assistant, answer.content, :answer)
Message(decision::ActionDecision) = Message(:assistant, action_content(decision.action), action_kind(decision.action); metadata=decision.action isa RunJulia ? nothing : decision.action)

decision_message(decision::AgentDecision) = Message(decision)
