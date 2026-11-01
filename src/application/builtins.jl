"""Assemble the first-party providers into an application-owned catalog."""
function builtin_provider_registry()
    registry = ProviderRegistry()
    for descriptor in (demo_provider_descriptor(), chatgpt_provider_descriptor(),
            openrouter_provider_descriptor(), codex_provider_descriptor())
        register_provider!(registry, with_model_selection(descriptor))
    end
    return registry
end

"""Install built-in descriptors outside global scope to preserve a function barrier."""
function register_builtin_providers!()
    foreach(register_provider!, provider_descriptors(builtin_provider_registry()))
    nothing
end

register_builtin_providers!()
