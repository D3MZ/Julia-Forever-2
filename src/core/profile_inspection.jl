"""A structural profile preview; no factories, effects, or service cleanup run."""
struct ProfilePlan
    profile::Symbol
    revision::UInt64
    active::Vector{Symbol}
    inactive::Vector{Symbol}
    services::Vector{Pair{Symbol,Symbol}}
    inherited::Vector{Symbol}
    requires::Vector{Pair{Symbol,Vector{Symbol}}}
end

profile_plan_failure(reason) = (ok=false, reason=String(reason), plan=nothing)

"""Preview plugin order and service resolution without activating the requested profile."""
function profile_plan(host::PluginHost, requested::Profile)
    profile = Profile(requested)
    catalog = profile_specs(host.registry, profile)
    catalog.ok ? inspect_registered_profile(host, profile, catalog.specs) : profile_plan_failure(catalog.reason)
end

function inspect_registered_profile(host::PluginHost, profile::Profile, specs)
    providers = profile_providers(specs, profile)
    providers.ok ? inspect_selected_profile(host, profile, specs, providers.selected) :
        profile_plan_failure(providers.reason)
end

function inspect_selected_profile(host::PluginHost, profile::Profile, specs, selected)
    state = lock(host.lock) do
        if host.closed
            nothing
        else
            (revision=host.revision,
                order=profile_order(specs, selected, host.base),
                inherited=Symbol[entry.name for entry in component_snapshot(host.base)
                    if !haskey(selected, entry.name)])
        end
    end
    inspect_profile_state(profile, selected, state)
end

inspect_profile_state(profile::Profile, selected, ::Nothing) = profile_plan_failure("Plugin host is closed")

function inspect_profile_state(profile::Profile, selected, state)
    if !state.order.ok
        profile_plan_failure(state.order.reason)
    else
        ordered = state.order.ordered
        active = Symbol[spec.name for spec in ordered]
        plan = ProfilePlan(profile.name, state.revision, active,
            Symbol[name for name in profile.plugins if !(name in active)],
            sort!(Pair{Symbol,Symbol}[name => provider for (name, provider) in selected]; by=first),
            sort!(state.inherited),
            Pair{Symbol,Vector{Symbol}}[spec.name => copy(spec.requires) for spec in ordered])
        (ok=true, reason="", plan)
    end
end

"""Inspect a saved named composition without starting any of its plugins."""
function profile_plan(host::PluginHost, store::ProfileStore, name::Union{Symbol,AbstractString})
    profile = load_profile(store, name)
    isnothing(profile) ? profile_plan_failure("Unknown profile $name") : profile_plan(host, profile)
end
