import JSON

"""Filesystem-backed, named compositions of independently registered Julia plugins."""
struct ProfileStore
    directory::String
    ProfileStore(directory::AbstractString) = new(abspath(directory))
end

function profile_path(store::ProfileStore, name::Symbol)
    label = String(name)
    if isempty(label) || label in (".", "..") || any(character -> character in ('/', '\\', '\0'), label)
        return nothing
    end
    return joinpath(store.directory, label * ".json")
end

"""Accept only saved regular files, not symlinked profile entries."""
is_saved_profile_file(::Nothing) = false
is_saved_profile_file(path::AbstractString) = !islink(path) && isfile(path)

"""Atomically save a profile's JSON-compatible configuration, not its live plugin instances."""
function save_profile!(store::ProfileStore, profile::Profile)
    path = profile_path(store, profile.name)
    isnothing(path) && return (ok=false, reason="Invalid profile name")
    data = Dict(
        "format" => "JuliaForever2.profile",
        "version" => 1,
        "name" => String(profile.name),
        "plugins" => String.(profile.plugins),
        "config" => Dict(String(name) => value for (name, value) in profile.config),
        "bindings" => Dict(String(name) => String(provider) for (name, provider) in profile.bindings),
    )
    serialized = JSON.json(data) * "\n"
    mkpath(store.directory; mode=0o700)
    mktemp(store.directory) do temporary, output
        chmod(temporary, 0o600)
        write(output, serialized)
        close(output)
        Base.Filesystem.rename(temporary, path)
    end
    return (ok=true, reason="")
end

"""Load a named profile independently of its plugin factories; missing profiles return nothing."""
function load_profile(store::ProfileStore, name::Union{Symbol,AbstractString})
    identity = Symbol(name)
    path = profile_path(store, identity)
    is_saved_profile_file(path) || return nothing
    data = JSON.parsefile(path)
    data["format"] == "JuliaForever2.profile" || error("Invalid profile format: $identity")
    data["version"] == 1 || error("Unsupported profile version: $identity")
    data["name"] == String(identity) || error("Profile identity mismatch: $identity")
    return Profile(identity, Symbol.(data["plugins"]); config=data["config"], bindings=data["bindings"])
end

"""List valid saved profile names without opening or activating their plugins."""
function profile_names(store::ProfileStore)
    isdir(store.directory) || return Symbol[]
    names = Symbol[]
    for filename in readdir(store.directory)
        endswith(filename, ".json") || continue
        identity = Symbol(first(filename, length(filename) - 5))
        path = profile_path(store, identity)
        is_saved_profile_file(path) && push!(names, identity)
    end
    return sort!(names)
end

"""Activate a saved named composition using the host's own Julia plugin registry."""
function activate!(host::PluginHost, store::ProfileStore, name::Union{Symbol,AbstractString})
    profile = load_profile(store, name)
    isnothing(profile) && return (ok=false, reason="Unknown profile $name")
    return activate!(host, profile)
end
