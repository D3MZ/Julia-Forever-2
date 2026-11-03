struct PluginSpec{F}
    name::Symbol
    setup::F
    provides::Vector{Symbol}
    requires::Vector{Symbol}
end

"""Declare a plugin factory and the service contracts it provides and requires."""
PluginSpec(name, setup; provides=Symbol[], requires=Symbol[]) = PluginSpec(Symbol(name), setup, collect(Symbol, provides), unique(collect(Symbol, requires)))
PluginSpec(setup::Function, name::Union{Symbol,AbstractString}; kwargs...) = PluginSpec(name, setup; kwargs...)

Base.@kwdef mutable struct PluginRegistry
    lock::ReentrantLock = ReentrantLock()
    plugins::Dict{Symbol,PluginSpec} = Dict{Symbol,PluginSpec}()
end

"""Register an independently authored plugin without activating its effects."""
function register_plugin!(registry::PluginRegistry, spec::PluginSpec; replace=false)
    lock(registry.lock) do
        if length(unique(spec.provides)) != length(spec.provides)
            (ok=false, reason="Plugin $(spec.name) declares duplicate services")
        elseif haskey(registry.plugins, spec.name) && !replace
            (ok=false, reason="Plugin $(spec.name) is already registered")
        else
            registry.plugins[spec.name] = PluginSpec(spec)
            (ok=true, reason="")
        end
    end
end

PluginSpec(spec::PluginSpec) = PluginSpec(spec.name, spec.setup; provides=copy(spec.provides), requires=copy(spec.requires))
"""Remove a factory from the catalog without interrupting existing activations."""
function unregister_plugin!(registry::PluginRegistry, name::Symbol)
    return lock(registry.lock) do
        present = haskey(registry.plugins, name)
        delete!(registry.plugins, name)
        return (ok=present, reason=present ? "" : "Plugin $name is not registered")
    end
end

