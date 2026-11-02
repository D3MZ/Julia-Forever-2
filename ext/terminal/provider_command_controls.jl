"""Resolve exact model references without fuzzy matching or silently selecting an ambiguous provider."""
function command_exact_model(reference::AbstractString,models::AbstractVector{<:JuliaForever2.ModelSpec})
    text=lowercase(strip(reference))
    raw=filter(model->lowercase(model.id)==text,models)
    named=nothing
    longest=-1
    for model in models
        provider=lowercase(strip(String(model.provider)))
        for slash in findall(==('/'),text)
            before=String(SubString(text,firstindex(text),prevind(text,slash)))
            after=strip(SubString(text,nextind(text,slash)))
            if !isempty(provider) && strip(before)==provider && !isempty(after) && length(provider)>longest
                candidates=filter(item->item.provider==model.provider && lowercase(item.id)==after,models)
                fallback=filter(item->item.provider==model.provider,raw)
                named=!isempty(candidates) ? first(candidates) : !isempty(fallback) ? first(fallback) : nothing
                longest=length(provider)
            end
        end
    end
    if !isnothing(named)
        named
    elseif !isempty(raw) && length(unique(model.provider for model in raw))==1
        first(raw)
    else
        nothing
    end
end

"""A nonempty explicit scope limits exact commands exactly as it limits the model picker."""
function command_model_pool(app::App)
    models=menu_model_snapshot(app)
    enabled=app.menus.enabled_models
    scoped=isnothing(enabled) ? JuliaForever2.ModelSpec[] : [model for key in enabled for model in models if string(model.provider,"/",model.id)==key]
    (models=isempty(scoped) ? models : scoped,scoped=!isempty(scoped))
end

"""Snapshot registered metadata services before work starts; no provider inference or authentication runs."""
function command_catalog_snapshot(app::App)
    originals=provider_descriptors(app.settings.registry)
    (registry=ProviderRegistry(;descriptors=copy(originals)),originals,ids=configured_model_providers(app),store=JuliaForever2.snapshot_model_cache(app.settings.directory,originals))
end

function command_refresh_catalogs(snapshot)
    errors=String[]
    for id in snapshot.ids
        descriptor=provider_descriptor(snapshot.registry,id)
        if id in (:chatgpt,:openrouter,:codex) && !isnothing(descriptor) && descriptor.create isa JuliaForever2.ProviderFactory
            result=JuliaForever2.refresh_pi_model_catalog!(snapshot.registry,id)
            result.ok || push!(errors,String(id))
        end
    end
    (;snapshot.registry,snapshot.originals,snapshot.store,errors)
end

"""Install only metadata belonging to unchanged descriptors; another writer retains its replacement."""
function command_install_catalogs!(app::App,result)
    for original in result.originals
        current=provider_descriptor(app.settings.registry,original.id)
        updated=provider_descriptor(result.registry,original.id)
        if current===original && updated!==original && !isnothing(updated)
            JuliaForever2.register_provider!(app.settings.registry,updated)
            saved=JuliaForever2.cache_installed_catalog!(get(result,:store,nothing),updated)
            saved.ok || push!(result.errors,String(updated.id)*" (cache not saved)")
        end
    end
    nothing
end

"""Keep refresh latency bounded while a late transport can finish without installing stale state."""
function command_catalog_wait(task::Task;timeout=15.0)
    finished=timedwait(()->istaskdone(task),timeout;pollint=min(0.05,max(0.001,timeout/100)))==:ok
    if !finished
        (kind=:timeout,result=nothing)
    elseif istaskfailed(task)
        (kind=:error,result=nothing)
    else
        (kind=:ready,result=fetch(task))
    end
end

function model_command_lookup!(app::App,query::AbstractString;refresh=command_refresh_catalogs,timeout=15.0)
    app.menus.model_command_request+=UInt(1)
    lookup=ModelCommandLookup(;query=String(query),generation=app.menus.generation,page=app.page,request=app.menus.model_command_request)
    app.menus.model_command=lookup
    snapshot=command_catalog_snapshot(app)
    worker=Threads.@spawn refresh(snapshot)
    task=Threads.@spawn command_catalog_wait(worker;timeout)
    app.status="Refreshing model catalogs…"
    notify_completion!(app,:model_command_catalog_done,task,(lookup,task))
    nothing
end

function model_command!(app::App,arguments::AbstractString;refresh=command_refresh_catalogs,timeout=15.0)
    app.menus.model_command=nothing
    if isempty(arguments)
        open_menu!(app,"model")
    elseif app.busy || app.operations.closing[]
        app.status="Finish or cancel the active operation first."
    else
        pool=command_model_pool(app)
        model=command_exact_model(arguments,pool.models)
        if !isnothing(model)
            configuration_action!(app,string(model.provider,"/",model.id))
        elseif pool.scoped
            open_menu!(app,"model";query=String(arguments))
        else
            model_command_lookup!(app,arguments;refresh,timeout)
        end
    end
    nothing
end

function model_command_catalog_finished!(app::App,value)
    lookup,task=value
    owned=app.menus.model_command===lookup && app.menus.generation==lookup.generation && app.page==lookup.page && !app.operations.closing[] && !app.busy
    if owned
        app.menus.model_command=nothing
        outcome=istaskfailed(task) ? (kind=:error,result=nothing) : fetch(task)
        result=outcome.result
        warning=outcome.kind==:timeout ? "Model refresh timed out; searching cached models." : outcome.kind==:error ? "Could not refresh model catalogs; searching cached models." : ""
        if outcome.kind==:ready && !isnothing(result)
            command_install_catalogs!(app,result)
            isempty(result.errors) || (warning="Could not refresh "*join(result.errors,", ")*"; searching cached models.")
        end
        model=command_exact_model(lookup.query,menu_model_snapshot(app))
        if !isnothing(model)
            configuration_action!(app,string(model.provider,"/",model.id))
        else
            open_menu!(app,"model";query=lookup.query,refresh=false)
            menu=app.menus.model_menu
            if !isnothing(menu)
                model_menu_refresh!(menu,selector_model.(menu_model_snapshot(app));runtime_error=warning)
            end
            isempty(warning) || (app.status=warning)
        end
    end
    nothing
end

"""Validate arguments against the active model's semantic levels, then use its real transaction."""
function thinking_command!(app::App,arguments::AbstractString)
    if isempty(arguments)
        open_menu!(app,"thinking")
    else
        model=with_component(JuliaForever2.selected_model,app.session.kernel,:provider;fallback=:unconfigured)
        if isnothing(model)
            app.status="Select a model before changing its thinking level."
        else
            levels=JuliaForever2.model_supported_thinking_levels(model)
            normalized=lowercase(strip(arguments))
            index=findfirst(level->lowercase(level)==normalized,levels)
            if isnothing(index)
                app.status="Unknown thinking level \""*arguments*"\". Available levels: "*join(levels,", ")*"."
            else
                configuration_action!(app,string(model.provider,"/",model.id);thinking=levels[index])
            end
        end
    end
    nothing
end

"""Resolve only actual registered login methods; unknown references open a prefilled all-method search."""
function login_command!(app::App,arguments::AbstractString;on_login=auth_menu_start_login!)
    if app.busy || app.operations.closing[]
        app.status="Finish or cancel the active operation first."
    else
        open_menu!(app,"login";login_reference=String(arguments),auth_login=on_login)
    end
    nothing
end
