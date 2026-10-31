provider_failure(message) = ProviderResult(Reply(:error, message), nothing)
transport_failure(response, label) = provider_failure(transport_reason(response, label))

function call_provider(provider, messages, session::Session)
    result = respond(provider, messages, session, ExecutionContext())
    usage = response_usage(result)
    isnothing(usage) || record_usage!(session, usage)
    return response_reply(result)
end

"""Adapt the legacy provider interface at the application boundary."""
function legacy_provider_response(provider, messages, session, context)
    request = model_request(provider.policy, messages, session)
    return respond(provider, request, context)
end
