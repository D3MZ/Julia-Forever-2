mutable struct PluginContext{C}
    kernel::Kernel
    name::Symbol
    config::C
    owner::Symbol
    entry::Union{Nothing,ComponentEntry}
    selected::Set{Symbol}
    declared::Set{Symbol}
    dependencies::Dict{Symbol,Any}
    provided::Dict{Symbol,Any}
    pending::Set{Symbol}
    resources::Vector{ResourceRegistration}
    lock::ReentrantLock
    closed::Bool
    failure::String
end

function PluginContext(kernel::Kernel, spec::PluginSpec, config, selected)
    return PluginContext(kernel, spec.name, config, gensym(:plugin), nothing, Set(selected), Set(spec.provides),
        Dict{Symbol,Any}(), Dict{Symbol,Any}(), Set{Symbol}(), ResourceRegistration[], ReentrantLock(), false, "")
end

function plugin_available(context::PluginContext)
    return lock(context.kernel.lock) do
        entry = context.entry
        !isnothing(entry) && !entry.cleaning && !entry.cleaned && lock(() -> !context.closed, context.lock)
    end
end

"""Retain the activation generation even after a profile switch removes its original kernel names."""
function acquire_plugin!(context::PluginContext)
    lock(context.kernel.lock) do
        plugin_available(context) ? retain!(context.kernel, context.entry) : nothing
    end
end
plugin_value(value) = value
plugin_value(value::Task) = plugin_value(fetch(value))

"""Retain an arbitrary plugin resource until every consumer of its activation has finished."""
function own_resource!(context::PluginContext, value; cleanup=close)
    owned = Ref{ResourceRegistration}()
    registration = ResourceRegistration(value, value -> begin
        lock(context.lock) do
            filter!(resource -> resource !== owned[], context.resources)
        end
        plugin_value(Base.invokelatest(cleanup, value))
    end)
    owned[] = registration
    accepted = lock(context.lock) do
        if context.closed
            false
        else
            push!(context.resources, registration)
            true
        end
    end
    accepted || release!(registration)
    return registration
end

"""Register a reversible plugin effect, disposed in reverse registration order."""
effect!(cleanup, context::PluginContext) = own_resource!(context, nothing; cleanup=value -> Base.invokelatest(cleanup))

"""Read an exact dependency generation or a service published by this activation."""
function service(context::PluginContext, name::Symbol)
    return lock(context.lock) do
        return get(context.dependencies, name, get(context.provided, name, nothing))
    end
end

function plugin_failure!(context::PluginContext, reason)
    lock(context.lock) do
        isempty(context.failure) && (context.failure = String(reason))
    end
    return (ok=false, reason=String(reason), active=false)
end

"""Publish a selected service; unselected implementations immediately release their value."""
function reserve!(context::PluginContext, name::Symbol)
    lock(context.lock) do
        if context.closed
            :closed
        elseif !(name in context.declared)
            :undeclared
        elseif !(name in context.selected)
            :unselected
        elseif haskey(context.provided, name) || name in context.pending
            :duplicate
        else
            push!(context.pending, name)
            :selected
        end
    end
end

function provide!(context::PluginContext, name::Symbol, value; requires=Symbol[], cleanup=Returns(nothing))
    dispose = value -> plugin_value(Base.invokelatest(cleanup, value))
    disposition = reserve!(context, name)
    if disposition === :selected
        publish!(context, name, value, requires, dispose)
    else
        dispose(value)
        disposition === :unselected ? (ok=true, reason="", active=false) : plugin_failure!(context, "Plugin $(context.name) cannot provide $name: $disposition")
    end
end

function publish!(context::PluginContext, name::Symbol, value, requires, dispose)
    dependencies = unique([context.owner; collect(Symbol, requires)])
    result = install!(context.kernel, ComponentSpec(name, value; requires=dependencies, cleanup=dispose))
    lock(context.lock) do
        delete!(context.pending, name)
        if result.ok
            context.provided[name] = value
        end
    end
    if result.ok
        (ok=true, reason="", active=true)
    else
        dispose(value)
        plugin_failure!(context, result.reason)
    end
end
"""Dispose every effect even when an earlier cleanup fails."""
function Base.close(context::PluginContext)
    resources = lock(context.lock) do
        context.closed = true
        pending = reverse(copy(context.resources))
        empty!(context.resources)
        pending
    end
    failures = Task[]
    for resource in resources
        worker = spawn_cleanup(() -> release!(resource))
        wait(worker; throw=false)
        istaskfailed(worker) && push!(failures, worker)
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

