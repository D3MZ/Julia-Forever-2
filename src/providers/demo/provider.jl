struct DemoProvider end
function respond(::DemoProvider, request::ModelRequest, context::ExecutionContext)
    messages = request.messages
    answer = !isempty(messages) && messages[end].role == :code_result ? "The Julia program finished. Its output is shown above." : "Demo provider: configure Codex or another provider to get a model response. Julia code can be run with /julia."
    return ProviderResult(Reply(:answer, answer), nothing)
end
(provider::DemoProvider)(messages, session) = call_provider(provider, messages, session)

respond(provider::DemoProvider, messages, session, context::ExecutionContext) = respond(provider, model_request(CodeModePolicy(), messages, session), context)

provider_identity(::DemoProvider) = ProviderIdentity(;
    id=:demo, name="Demo", detail="(demo) offline · /settings to connect")
demo_provider_descriptor() = ProviderDescriptor(:demo, "Demo", dir -> DemoProvider(); status=Returns("offline, deterministic"))
