"""Expose only optional warning facts from an already selected provider; extensions may specialize without exposing credentials."""
provider_warning_facts(provider)=(anthropic_subscription=false,)
provider_warning_facts(provider::ConfiguredModelProvider)=provider_warning_facts(provider.backend)
function provider_warning_facts(provider::ModelProvider{<:ModelSpec})
    provider.model.provider==:anthropic ? provider_warning_facts(provider.backend,provider.model) : (anthropic_subscription=false,)
end
provider_warning_facts(backend,model)=(anthropic_subscription=false,)
function provider_warning_facts(backend::HTTPModelBackend,model::ModelSpec)
    provider_warning_facts(backend.credentials,model)
end
function provider_warning_facts(resolver::APIKeyCredentialResolver,model::ModelSpec)
    subscription=false
    if resolver.provider==:anthropic && model.provider==:anthropic
        task=Task() do
            saved=api_key_credentials(resolver.directory,resolver.provider)
            api_key_saved(saved) && model.id in saved["model_ids"] && startswith(saved["key"],"sk-ant-oat")
        end
        schedule(task);wait(task;throw=false)
        subscription=!istaskfailed(task) && fetch(task)===true
    end
    (anthropic_subscription=subscription,)
end
