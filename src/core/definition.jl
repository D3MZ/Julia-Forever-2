struct AgentDefinition{P,F,C,W}
    provider::P
    executor_factory::F
    protocol::C
    wrappers::W
end

"""Describe agent behavior; each Session constructs its own executor and conversation."""
AgentDefinition(provider; executor_factory=JuliaExecutor, protocol=provider_protocol(provider), wrappers=()) = AgentDefinition(provider, executor_factory, protocol, Tuple(wrappers))

function Kernel(definition::AgentDefinition)
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, definition.provider))
    install!(kernel, ComponentSpec(:executor, default_evaluate!))
    implementation = foldl((inner, wrapper) -> Base.invokelatest(wrapper, inner), definition.wrappers; init=default_loop!)
    install!(kernel, ComponentSpec(:loop, implementation))
    kernel
end

definition_kernel(definition::AgentDefinition) = Kernel(definition)

operation_protocol(::Nothing, provider) = provider_protocol(provider)
operation_protocol(definition::AgentDefinition, provider) = definition.protocol
