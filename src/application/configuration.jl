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

function default_kernel(provider=DemoProvider())
    kernel = Kernel()
    install!(kernel, ComponentSpec(:provider, provider))
    install!(kernel, ComponentSpec(:executor, default_evaluate!))
    install!(kernel, ComponentSpec(:loop, default_loop!))
    return kernel
end

"""Return display information while the selected provider generation remains retained."""
function provider_selection_snapshot(kernel::Kernel)
    snapshot = with_component(kernel, :provider) do provider
        (id=Base.invokelatest(provider_id, provider),
            name=String(Base.invokelatest(provider_name, provider)),
            detail=String(Base.invokelatest(provider_detail, provider)))
    end
    return isnothing(snapshot) ? (id=:none, name="No provider", detail="No provider") : snapshot
end

"""Read provider availability for settings without coupling views to credential storage."""
function provider_settings_snapshot(dir::AbstractString=config_dir(); registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    return [(descriptor=descriptor, status=String(Base.invokelatest(descriptor.status, dir)))
        for descriptor in provider_descriptors(registry)]
end

"""Select and persist a provider only after its component is installed successfully."""
function select_provider!(kernel::Kernel, id::Symbol; dir::AbstractString=config_dir(),
        registry::ProviderRegistry=DEFAULT_PROVIDER_REGISTRY)
    provider = provider_from_name(id; dir, registry)
    isnothing(provider) && return (ok=false, reason="Provider is unavailable.")
    result = install!(kernel, ComponentSpec(:provider, provider))
    result.ok && save_provider!(dir, id)
    return result
end
