struct AgentDefinition{P,F,C,W}
    provider::P
    executor_factory::F
    protocol::C
    wrappers::W
end

"""Describe agent behavior; each Session constructs its own executor and conversation."""
AgentDefinition(provider; executor_factory=JuliaExecutor, protocol=provider_protocol(provider), wrappers=()) =
    AgentDefinition(provider, executor_factory, protocol, Tuple(wrappers))

function definition_kernel(definition::AgentDefinition)
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, definition.provider))
    install!(kernel, ComponentSpec(:executor, default_evaluate!))
    implementation = default_loop!
    for wrapper in definition.wrappers
        implementation = Base.invokelatest(wrapper, implementation)
    end
    install!(kernel, ComponentSpec(:loop, implementation))
    return kernel
end

operation_protocol(::Nothing, provider) = provider_protocol(provider)
operation_protocol(definition::AgentDefinition, provider) = definition.protocol
