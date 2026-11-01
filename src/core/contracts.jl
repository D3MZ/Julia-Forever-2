struct ExecutionResult{T}
    ok::Bool
    text::String
    value::T
end

ExecutionResult(ok::Bool, text::AbstractString, value=nothing) = ExecutionResult(ok, String(text), value)
ExecutionResult(result::ExecutionResult) = result
ExecutionResult(result::NamedTuple) = ExecutionResult(result.ok, result.text, get(result, :value, nothing))
execution_result(result) = ExecutionResult(result)

struct Message{T}
    role::Symbol
    content::String
    kind::Symbol
    metadata::T
end

Message(role::Symbol, content::AbstractString, kind::Symbol=:text; metadata=nothing) = Message(role, String(content), kind, metadata)
message_result(message::Message) = message.metadata

struct Reply
    kind::Symbol
    content::String
end

struct ProviderResult{R,U}
    reply::R
    usage::U
end

response_reply(response) = response
response_reply(response::ProviderResult) = response.reply
response_usage(response) = nothing
response_usage(response::ProviderResult) = response.usage

struct HarnessEvent{T}
    kind::Symbol
    data::T
end

abstract type AgentDecision end

struct Answer <: AgentDecision
    content::String
end
Answer(content::AbstractString) = Answer(String(content))

struct RunJulia
    source::String
end
RunJulia(source::AbstractString) = RunJulia(String(source))

struct ActionDecision{A} <: AgentDecision
    action::A
end

struct Failure <: AgentDecision
    content::String
end
Failure(content::AbstractString) = Failure(String(content))

ExecutionResult(answer::Answer) = ExecutionResult(true, answer.content)
ExecutionResult(failure::Failure) = ExecutionResult(false, failure.content)
AgentDecision(response) = agent_decision(response)
agent_decision(decision::AgentDecision) = decision
agent_decision(action::RunJulia) = ActionDecision(action)
agent_decision(reply::Reply) = agent_decision(Val(reply.kind), reply.content)
agent_decision(response) = Failure("Provider returned an unsupported decision.")
agent_decision(::Val{:answer}, content) = Answer(content)
agent_decision(::Val{:code}, content) = ActionDecision(RunJulia(content))
agent_decision(::Val{:error}, content) = Failure(content)
agent_decision(::Val{kind}, content) where {kind} = Failure("Unsupported reply kind: $kind")

struct ModelRequest{H,S,F,P}
    messages::H
    instructions::String
    schema::S
    response_format::F
    protocol::P
end

abstract type AbstractSession end
