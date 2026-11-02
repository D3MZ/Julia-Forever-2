"""Resolve a currently existing workspace to its filesystem identity, never a lexical prefix."""
project_trust_canonical(directory::AbstractString)=isdir(directory) ? realpath(directory) : error("Project directory is missing or is not a directory")

"""Require locally owned storage with no other-writer permission; sticky system ancestors may contain private directories."""
function project_trust_permissions_allowed(path::String;system_ancestor::Bool=false)
    if Sys.isunix() && ispath(path)
        metadata=stat(path)
        owner=ccall(:geteuid,Cuint,())
        owned=metadata.uid==owner || (system_ancestor && metadata.uid==0)
        private_writer=(metadata.mode & 0o022)==0
        sticky_ancestor=system_ancestor && isdir(path) && (metadata.mode & 0o1000)!=0
        owned && (private_writer || sticky_ancestor)
    else
        true
    end
end

"""Reject redirected trust files or unsafe private parent directories before reading or writing."""
function project_trust_path_allowed(path::String)
    valid=basename(path)=="project-trust.json" && (!ispath(path) || isfile(path))
    current=path
    while valid && dirname(current)!=current
        valid=!islink(current) && (current==path || !ispath(current) || isdir(current)) &&
            project_trust_permissions_allowed(current;system_ancestor=current!=path && current!=dirname(path))
        current=dirname(current)
    end
    valid
end

"""Read bounded trust data without converting malformed or redirected storage into an implicit grant."""
function project_trust_read(path::String)
    project_trust_path_allowed(path) || error("Project trust storage is redirected or unsafe; project resources are blocked")
    isfile(path) && filesize(path)>1024*1024 && error("Project trust storage exceeds the size limit")
    raw=isfile(path) ? read(path,String) : nothing
    data=isnothing(raw) ? Dict{String,Any}() : JSON.isvalidjson(raw) ? JSON.parse(raw) : nothing
    data isa AbstractDict || error("Project trust storage is invalid JSON; not overwritten")
    result=Dict{String,Bool}()
    for (path,decision) in data
        path isa String && isabspath(path) && normpath(path)==path || error("Project trust contains an invalid directory identity")
        decision isa Bool || isnothing(decision) || error("Project trust values must be true, false or null")
        decision isa Bool && (result[path]=decision)
    end
    (;raw,data=result)
end

"""Find the nearest saved canonical directory decision; child denial overrides parent trust."""
function project_trust_entry(data::Dict{String,Bool},canonical::String)
    path=canonical
    while true
        haskey(data,path) && return (path,decision=data[path])
        parent=dirname(path)
        parent==path && return nothing
        path=parent
    end
end

"""Hold one exclusive native-process write claim and always release it after the operation settles."""
function project_trust_claim(operation,path::String)
    project_trust_path_allowed(path) || error("Project trust storage is unsafe")
    mkpath(dirname(path);mode=0o700)
    claim=path*".lock"
    mkdir(claim;mode=0o700)
    outcome=preference_attempt(operation)
    rm(claim)
    outcome.ok || error(outcome.reason)
    outcome.value
end

"""Persist only the selected unchanged trust snapshot, atomically rename, and verify exact readback."""
function project_trust_save!(state::ProjectTrustState,option::ProjectTrustOption)
    preference_attempt() do
        project_trust_canonical(state.directory)==state.canonical || error("Project directory identity changed; reopen trust selection")
        isempty(state.error) || error(state.error)
        isempty(state.store_error) || error(state.store_error)
        if isempty(option.updates)
            nothing
        else
            lock(terminal_preference_lock(state.path)) do
                project_trust_claim(state.path) do
                    project_trust_canonical(state.directory)==state.canonical || error("Project directory identity changed; reopen trust selection")
                    snapshot=project_trust_read(state.path)
                    snapshot.raw==state.revision || error("Project trust changed concurrently; reopen the selector")
                    data=copy(snapshot.data)
                    for (path,decision) in option.updates
                        isnothing(decision) ? delete!(data,path) : (data[path]=decision)
                    end
                    bytes=JSON.json(data)
                    mktemp(dirname(state.path)) do temporary,io
                        chmod(temporary,0o600)
                        write(io,bytes);flush(io)
                        Sys.isunix() && ccall(:fsync,Cint,(Cint,),fd(io))!=0 && error("Project trust sync failed before replacement")
                        close(io)
                        current=project_trust_read(state.path)
                        current.raw==state.revision || error("Project trust changed before commit; not overwritten")
                        Base.Filesystem.rename(temporary,state.path)
                        JuliaForever2.timeline_sync_directory(state.path)
                        readback=project_trust_read(state.path)
                        readback.raw==bytes || error("Project trust write submitted but readback is uncertain; reconcile before retrying")
                        state.revision=readback.raw
                        nothing
                    end
                end
            end
        end
    end
end
