Base.@kwdef struct ProviderIdentity
    id::Symbol = :custom
    name::String = "Custom provider"
    detail::String = "Custom provider"
end

provider_id(provider) = :custom
provider_name(provider) = "Custom provider"
provider_detail(provider) = provider_name(provider)

"""Resolve legacy provider display methods once at the application boundary."""
provider_identity(provider) = ProviderIdentity(;
    id=Base.invokelatest(provider_id, provider),
    name=String(Base.invokelatest(provider_name, provider)),
    detail=String(Base.invokelatest(provider_detail, provider)))

const BuiltinProvider = Union{DemoProvider,CodexProvider,OpenRouterProvider,OpenAIProvider}
provider_id(provider::BuiltinProvider) = provider_identity(provider).id
provider_name(provider::BuiltinProvider) = provider_identity(provider).name
provider_detail(provider::BuiltinProvider) = provider_identity(provider).detail
