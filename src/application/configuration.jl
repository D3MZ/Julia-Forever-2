function configured_provider(dir::AbstractString=config_dir(); registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    path = joinpath(dir, "provider")
    return provider_from_name(isfile(path) ? strip(read(path, String)) : "demo"; dir, registry)
end

function save_provider!(dir::AbstractString, provider::Symbol)
    mkpath(dir; mode=0o700)
    mktemp(dir) do temp, io
        chmod(temp, 0o600)
        print(io, provider)
        close(io)
        Base.Filesystem.rename(temp, joinpath(dir, "provider"))
    end
    return nothing
end

Kernel(provider) = Kernel(AgentDefinition(provider; protocol=nothing))
default_kernel(provider=DemoProvider()) = Kernel(provider)
"""Return a typed identity while the selected provider generation remains retained."""
function provider_selection_snapshot(kernel::Kernel)
    identity = with_component(kernel, :provider) do provider
        Base.invokelatest(provider_identity, provider)
    end
    isnothing(identity) ? ProviderIdentity(; id=:none, name="No provider", detail="No provider") : identity
end

"""Read provider availability for settings without coupling views to credential storage."""
provider_settings_snapshot(dir::AbstractString=config_dir(); registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY) = [(descriptor=descriptor, status=String(Base.invokelatest(descriptor.status, dir))) for descriptor in provider_descriptors(registry)]

"""Select and persist a provider only after its component is installed successfully."""
select_provider!(kernel::Kernel, id::Symbol; dir::AbstractString=config_dir(), registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY) = select!(kernel, provider_from_name(id; dir, registry), id, dir)
select!(kernel::Kernel, ::Nothing, id::Symbol, directory) = (ok=false, reason="Provider is unavailable.")

function select!(kernel::Kernel, provider, id::Symbol, directory)
    result = install!(kernel, ComponentSpec(:provider, provider))
    if result.ok
        save_provider!(directory, id)
    end
    result
end
