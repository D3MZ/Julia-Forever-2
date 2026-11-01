module CredentialStorage

using JSON
using ..JSONCodec: parse_json

const AUTH_LOCK = ReentrantLock()
const AUTH_ACCOUNT_LOCKS = Dict{Tuple{String,Symbol},ReentrantLock}()

function auth_lock(dir::AbstractString, provider::Symbol)
    lock(AUTH_LOCK) do
        return get!(ReentrantLock, AUTH_ACCOUNT_LOCKS, (abspath(dir), provider))
    end
end

config_dir() = get(ENV, "JULIAFOREVER_CONFIG_DIR", joinpath(homedir(), ".config", "juliaforever2"))

function credential_path(dir::AbstractString, provider::Symbol)
    label = String(provider)
    valid = !isempty(label) && !(label in (".", "..")) && !any(char -> char in ('/', '\\', '\0'), label)
    valid ? joinpath(dir, label * ".json") : nothing
end
validate(::Nothing) = error("Invalid credential provider name")
validate(path::AbstractString) = path

function save_credentials!(dir::AbstractString, provider::Symbol, credentials)
    path = validate(credential_path(dir, provider))
    lock(auth_lock(dir, provider)) do
        mkpath(dir; mode=0o700)
        mktemp(dir) do temp, io
            chmod(temp, 0o600)
            write(io, JSON.json(credentials))
            close(io)
            Base.Filesystem.rename(temp, path)
        end
    end
    return nothing
end

function load_credentials(dir::AbstractString, provider::Symbol)
    path = credential_path(dir, provider)
    !isnothing(path) && !islink(path) && isfile(path) ? credentials(parse_json(read(path, String))) : nothing
end

credentials(data::AbstractDict) = data
credentials(data) = nothing
end

using .CredentialStorage: config_dir, save_credentials!, load_credentials, auth_lock
