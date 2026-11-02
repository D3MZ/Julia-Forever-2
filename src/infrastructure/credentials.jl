module CredentialStorage

using JSON
using SHA
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

"""Reject redirected credential directories and non-file targets before any private write."""
function credential_write_target(dir::AbstractString, provider::Symbol; replace_link::Bool=false)
    path = validate(credential_path(dir, provider))
    parent = abspath(dir)
    safe = (replace_link || !islink(path)) && (!ispath(path) || isfile(path) || (replace_link && islink(path)))
    while dirname(parent) != parent && safe
        safe = !islink(parent) && (!ispath(parent) || isdir(parent))
        parent = dirname(parent)
    end
    safe || error("Refusing redirected or non-file credential storage")
    path
end

"""Serialize app-owned writes across native processes and release the claim after failure."""
function credential_write(action, dir::AbstractString, provider::Symbol; replace_link::Bool=false)
    lock(auth_lock(dir, provider)) do
        path = credential_write_target(dir, provider; replace_link)
        mkpath(dir; mode=0o700)
        claim = path * ".lock"
        mkdir(claim; mode=0o700)
        worker = Task(() -> action(path))
        schedule(worker)
        wait(worker; throw=false)
        rm(claim)
        fetch(worker)
    end
end

"""Confirm directory durability after replacing or removing app-owned credential files."""
function credential_sync_directory(path::AbstractString)
    if Sys.isunix()
        descriptor = ccall(:open, Cint, (Cstring, Cint), dirname(path), 0)
        descriptor >= 0 || error("Credential change submitted but directory sync is unavailable")
        result = ccall(:fsync, Cint, (Cint,), descriptor)
        closed = ccall(:close, Cint, (Cint,), descriptor)
        result == 0 && closed == 0 || error("Credential change submitted but durability is unconfirmed")
    end
    nothing
end

function save_credentials!(dir::AbstractString, provider::Symbol, credentials)
    credential_write(dir, provider; replace_link=true) do path
        mktemp(dir) do temp, io
            chmod(temp, 0o600)
            write(io, JSON.json(credentials))
            flush(io)
            if Sys.isunix() && ccall(:fsync, Cint, (Cint,), fd(io)) != 0
                error("Credential file sync failed before replacement")
            end
            close(io)
            Base.Filesystem.rename(temp, path)
            credential_sync_directory(path)
        end
    end
    nothing
end

"""Fingerprint only a bounded, regular app-owned credential for stale-selection protection."""
function credential_file_revision(path::AbstractString)
    if isfile(path)
        filesize(path) <= 1024 * 1024 || error("Credential file exceeds the supported size limit")
        bytes2hex(SHA.sha256(read(path)))
    else
        nothing
    end
end

function credential_revision(dir::AbstractString, provider::Symbol)
    lock(auth_lock(dir,provider)) do
        credential_file_revision(credential_write_target(dir,provider))
    end
end

"""Remove only selected local credentials; never revoke remote grants or modify environment credentials."""
function delete_credentials!(dir::AbstractString, provider::Symbol; expected=missing, active=Returns(true))
    credential_write(dir,provider) do path
        current = credential_file_revision(path)
        if !active()
            (ok=false,removed=false,reason="Credential removal cancelled.")
        elseif !ismissing(expected) && expected != current
            (ok=false,removed=false,reason="Credentials changed; reload before removing them.")
        elseif isnothing(current)
            (ok=true,removed=false,reason="No stored credentials to remove.")
        else
            rm(path)
            credential_sync_directory(path)
            if ispath(path) || islink(path)
                error("Credential removal submitted but readback could not verify absence")
            end
            (ok=true,removed=true,reason="Stored credentials removed.")
        end
    end
end

function load_credentials(dir::AbstractString, provider::Symbol)
    path = credential_path(dir, provider)
    !isnothing(path) && !islink(path) && isfile(path) ? credentials(parse_json(read(path, String))) : nothing
end

credentials(data::AbstractDict) = data
credentials(data) = nothing
end

using .CredentialStorage: config_dir, save_credentials!, load_credentials, auth_lock
