struct Profile
    name::Symbol
    plugins::Vector{Symbol}
    config::Dict{Symbol,Any}
    bindings::Dict{Symbol,Symbol}
end

"""Select ordered plugins, their configuration, and explicit service implementation choices."""
Profile(name, plugins; config=Dict(), bindings=Dict()) = Profile(Symbol(name), collect(Symbol, plugins), Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(config)), Dict{Symbol,Symbol}(Symbol(key) => Symbol(value) for (key, value) in pairs(bindings)))

Profile(profile::Profile) = Profile(profile.name, copy(profile.plugins); config=deepcopy(profile.config), bindings=copy(profile.bindings))
copy_profile(profile::Profile) = Profile(profile)

"""Compose reusable plugin groups; later groups replace plugin configuration and service bindings."""
function Profile(name, profiles::Profile...)
    plugins = Symbol[]
    config = Dict{Symbol,Any}()
    bindings = Dict{Symbol,Symbol}()
    for profile in profiles
        for plugin in profile.plugins
            plugin in plugins || push!(plugins, plugin)
        end
        for (plugin, value) in profile.config
            config[plugin] = deepcopy(value)
        end
        merge!(bindings, profile.bindings)
    end
    return Profile(name, plugins; config, bindings)
end

compose_profiles(name, profiles::Profile...) = Profile(name, profiles...)

