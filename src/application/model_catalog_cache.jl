"""Non-secret model metadata cache with source identity, snapshot hash and compare-and-swap publication."""
Base.@kwdef struct FileModelStore
    directory::String
    lock::ReentrantLock=ReentrantLock()
    revisions::Dict{Symbol,Union{Nothing,String}}=Dict{Symbol,Union{Nothing,String}}()
end
FileModelStore(directory::AbstractString)=FileModelStore(;directory=joinpath(abspath(directory),"model-catalogs"))
model_catalog_source(provider::Symbol)="https://pi.dev/api/models/providers/"*pi_catalog_provider(provider)
model_catalog_path(store::FileModelStore,provider::Symbol)=joinpath(store.directory,timeline_digest(String(provider))*".json")
model_catalog_directory_safe(store::FileModelStore)=!islink(store.directory) && !islink(dirname(store.directory))

"""Validate the envelope before its metadata can affect model selection; cache entries grant no credentials."""
model_catalog_envelope(value,provider::Symbol)=nothing
function model_catalog_envelope(value::AbstractDict,provider::Symbol)
    body=get(value,"body",nothing)
    stamp=get(value,"fetchedAt",nothing)
    digest=get(value,"snapshotSha256",nothing)
    valid=get(value,"schemaVersion",nothing)===1 && get(value,"provider",nothing)==String(provider) &&
        get(value,"source",nothing)==model_catalog_source(provider) && body isa String && sizeof(body)<=8*1024*1024 &&
        stamp isa Real && !(stamp isa Bool) && isfinite(stamp) && stamp>0 && digest isa String
    if valid && body isa String && timeline_digest(body)==digest && !isnothing(pi_model_catalog(body,provider))
        Dict{String,Any}(value)
    else
        nothing
    end
end

function read_model_catalog(store::FileModelStore,provider::Symbol)
    lock(store.lock) do
        path=model_catalog_path(store,provider)
        safe=model_catalog_directory_safe(store) && !islink(path) && (!ispath(path) || (isfile(path) && filesize(path)<=16*1024*1024))
        text=safe && isfile(path) ? read(path,String) : nothing
        store.revisions[provider]=isnothing(text) ? nothing : timeline_digest(text)
        isnothing(text) ? nothing : model_catalog_envelope(parse_json(text),provider)
    end
end

function write_model_catalog!(store::FileModelStore,provider::Symbol,entry)
    lock(store.lock) do
        validated=model_catalog_envelope(entry,provider)
        if isnothing(validated) || !model_catalog_directory_safe(store)
            error("Invalid or unsafe model metadata cache")
        else
            haskey(store.revisions,provider) || read_model_catalog(store,provider)
            mkpath(store.directory;mode=0o700)
            path=model_catalog_path(store,provider)
            text=JSON.json(validated)*"\n"
            digest=timeline_replace_file(path,text,store.revisions[provider])
            if read(path,String)!=text
                error("Model metadata cache readback failed")
            end
            store.revisions[provider]=digest
        end
    end
    nothing
end

"""Install cached catalogs only on their already registered native model factory."""
function restore_model_catalogs!(registry::ProviderRegistry,store::FileModelStore)
    restored=Symbol[]
    for descriptor in provider_descriptors(registry)
        if descriptor.create isa ProviderFactory
            entry=read_model_catalog(store,descriptor.id)
            if !isnothing(entry)
                catalog=pi_model_catalog(entry["body"],descriptor.id)
                if !isnothing(catalog)
                    install_model_catalog!(registry,descriptor,catalog)
                    push!(restored,descriptor.id)
                end
            end
        end
    end
    restored
end

"""Keep transport and auth ownership unchanged while replacing only a copied metadata snapshot."""
function install_model_catalog!(registry::ProviderRegistry,descriptor::ProviderDescriptor{<:ProviderFactory},catalog::AbstractVector{<:ModelSpec})
    factory=descriptor.create
    existing=catalog_models(factory)
    preserved=ModelSpec[model for model in existing if !any(remote->remote.kind==model.kind && remote.id==model.id,catalog)]
    updated=vcat(preserved,catalog)
    replacement=ProviderFactory(factory.create;models=()->copy(updated),select=factory.select)
    register_provider!(registry,ProviderDescriptor(descriptor,replacement))
    nothing
end

prepare_catalog_cache!(::Nothing,provider::Symbol)=nothing
prepare_catalog_cache!(store::FileModelStore,provider::Symbol)=read_model_catalog(store,provider)
persist_catalog_metadata!(::Nothing,provider::Symbol,body::AbstractString)=(ok=true,reason="")
function persist_catalog_metadata!(store::FileModelStore,provider::Symbol,body::AbstractString)
    entry=Dict("schemaVersion"=>1,"provider"=>String(provider),"source"=>model_catalog_source(provider),
        "fetchedAt"=>time(),"snapshotSha256"=>timeline_digest(body),"body"=>String(body))
    task=Task(()->write_model_catalog!(store,provider,entry))
    schedule(task)
    wait(task;throw=false)
    istaskfailed(task) ? (ok=false,reason="Catalog refreshed in memory, but its durable cache was not saved.") : (ok=true,reason="")
end

"""Read the separately hash-bound shipped metadata snapshot, never a provider connection or entitlement."""
builtin_model_catalog(provider::Symbol)=provider in (:chatgpt,:codex) ? builtin_model_catalog(Val(provider)) : ModelSpec[]
function builtin_model_catalog(::Val{provider}) where {provider}
    path=joinpath(@__DIR__,"..","providers","catalog_data","builtin-chat-models.json")
    data=parse_json(read(path,String))
    providers=data isa AbstractDict ? get(data,"providers",nothing) : nothing
    rows=providers isa AbstractDict ? get(providers,String(provider),nothing) : nothing
    isnothing(rows) ? ModelSpec[] : something(pi_model_catalog(JSON.json(rows),provider),ModelSpec[])
end
function builtin_model_descriptor(descriptor::ProviderDescriptor)
    factory=ProviderFactory(descriptor)
    seeded=ProviderFactory(factory.create;models=()->builtin_model_catalog(descriptor.id),select=factory.select)
    ProviderDescriptor(descriptor,seeded)
end

"""Persist an installed non-secret metadata snapshot only after the view has accepted its owner."""
function cache_installed_catalog!(store::FileModelStore,descriptor::ProviderDescriptor)
    rows=[merge(model.metadata isa AbstractDict ? Dict{String,Any}(model.metadata) : Dict{String,Any}(),
        Dict("id"=>model.id,"api"=>model.api,"type"=>String(model.kind))) for model in models(descriptor)]
    persist_catalog_metadata!(store,descriptor.id,JSON.json(rows))
end
cache_installed_catalog!(::Nothing,descriptor::ProviderDescriptor)=(ok=true,reason="")
function snapshot_model_cache(directory::AbstractString,descriptors)
    store=FileModelStore(directory)
    for descriptor in descriptors
        read_model_catalog(store,descriptor.id)
    end
    store
end

"""Remove only the observed metadata revision; credential files and other provider entries are untouched."""
function delete_model_catalog!(store::FileModelStore,provider::Symbol)
    lock(store.lock) do
        haskey(store.revisions,provider) || read_model_catalog(store,provider)
        path=model_catalog_path(store,provider)
        if !model_catalog_directory_safe(store) || islink(path)
            error("Unsafe model metadata cache")
        elseif isfile(path)
            timeline_locked_write(path) do
                if islink(path) || timeline_digest(read(path,String))!=store.revisions[provider]
                    error("Model metadata cache changed before removal")
                else
                    rm(path)
                    timeline_sync_directory(path)
                end
            end
            store.revisions[provider]=nothing
        end
    end
    nothing
end
