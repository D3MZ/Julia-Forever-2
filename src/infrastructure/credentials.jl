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
    if isempty(label) || label in (".", "..") || any(char -> char in ('/', '\\', '\0'), label)
        return nothing
    end
    return joinpath(dir, label * ".json")
end

function save_credentials!(dir::AbstractString, provider::Symbol, credentials)
    path = credential_path(dir, provider)
    isnothing(path) && error("Invalid credential provider name")
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
    (isnothing(path) || islink(path) || !isfile(path)) && return nothing
    data = parse_json(read(path, String))
    return data isa AbstractDict ? data : nothing
end
end

using .CredentialStorage: config_dir, save_credentials!, load_credentials, auth_lock
