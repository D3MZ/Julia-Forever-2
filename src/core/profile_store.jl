import JSON

"""Filesystem-backed, named compositions of independently registered Julia plugins."""
struct ProfileStore
    directory::String
    ProfileStore(directory::AbstractString) = new(abspath(directory))
end

function profile_path(store::ProfileStore, name::Symbol)
    label = String(name)
    validname(label) ? joinpath(store.directory, label * ".json") : nothing
end

validname(label::AbstractString) = !isempty(label) && !(label in (".", "..")) && !any(character -> character in ('/', '\\', '\0'), label)
"""Accept only saved regular files, not symlinked profile entries."""
is_saved_profile_file(::Nothing) = false
is_saved_profile_file(path::AbstractString) = !islink(path) && isfile(path)

"""Atomically save a profile's JSON-compatible configuration, not its live plugin instances."""
save_profile!(store::ProfileStore, profile::Profile) = persist!(store, profile, profile_path(store, profile.name))
persist!(store::ProfileStore, profile::Profile, ::Nothing) = (ok=false, reason="Invalid profile name")

function persist!(store::ProfileStore, profile::Profile, path::AbstractString)
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
    is_saved_profile_file(path) ? Profile(ProfileRecord(JSON.parsefile(path), identity)) : nothing
end

struct ProfileRecord{D}
    data::D
    name::Symbol

    function ProfileRecord(data::D, name::Symbol) where {D}
        validate(ProfileRecord, data, name)
        new{D}(data, name)
    end
end

function validate(::Type{ProfileRecord}, data, name::Symbol)
    if data["format"] != "JuliaForever2.profile"
        error("Invalid profile format: $name")
    elseif data["version"] != 1
        error("Unsupported profile version: $name")
    elseif data["name"] != String(name)
        error("Profile identity mismatch: $name")
    end
    nothing
end

Profile(record::ProfileRecord) = Profile(record.name, Symbol.(record.data["plugins"]); config=record.data["config"], bindings=record.data["bindings"])
"""List valid saved profile names without opening or activating their plugins."""
function profile_names(store::ProfileStore)
    files = isdir(store.directory) ? readdir(store.directory) : String[]
    names = Symbol[Symbol(chop(file; tail=5)) for file in files if endswith(file, ".json")]
    sort!(filter(name -> is_saved_profile_file(profile_path(store, name)), names))
end
"""Activate a saved named composition using the host's own Julia plugin registry."""
function activate!(host::PluginHost, store::ProfileStore, name::Union{Symbol,AbstractString})
    profile = load_profile(store, name)
    isnothing(profile) ? (ok=false, reason="Unknown profile $name") : activate!(host, profile)
end
