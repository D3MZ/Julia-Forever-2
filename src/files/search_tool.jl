module FileSearchTools

import Artifacts

const FD_VERSION=v"10.5.0"
const FD_TARGETS=Dict((:Linux,:x86_64)=>"x86_64-unknown-linux-musl")

"""Resolve an already-installed pinned artifact only; this function never downloads tools at runtime."""
function installed_fd(;manifest=joinpath(@__DIR__,"..","..","Artifacts.toml"))
    target=get(FD_TARGETS,(Sys.KERNEL,Sys.ARCH),nothing)
    hash=isfile(manifest) ? Artifacts.artifact_hash("fd",manifest) : nothing
    if isnothing(target) || isnothing(hash) || !Artifacts.artifact_exists(hash)
        nothing
    else
        path=joinpath(Artifacts.artifact_path(hash),"fd-v$(FD_VERSION)-$target",Sys.iswindows() ? "fd.exe" : "fd")
        isfile(path) ? path : nothing
    end
end

"""Prefer the pinned installed tool, then an explicitly installed system fd/fdfind executable."""
function find_fd()
    installed=installed_fd()
    if !isnothing(installed)
        installed
    else
        found=Sys.which("fd")
        isnothing(found) ? Sys.which("fdfind") : found
    end
end

end
