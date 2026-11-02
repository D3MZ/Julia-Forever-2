import SHA

"""Bounded, read-only workspace file inspection shared by optional Julia frontends."""
struct WorkspaceFileService{R}
    registry::R
    max_entries::Int
    max_lines::Int
    max_page_bytes::Int
    max_file_bytes::Int
end

"""Create a replaceable file-inspection service; no HTTP or agent runtime is required."""
function WorkspaceFileService(registry; max_entries=256, max_lines=200,
        max_page_bytes=131_072, max_file_bytes=1_048_576)
    if !(1 <= max_entries <= 1024 && 1 <= max_lines <= 2000 &&
            1 <= max_page_bytes <= 262_144 && max_page_bytes <= max_file_bytes <= 8_388_608)
        error("Invalid workspace file inspection limits")
    end
    WorkspaceFileService(registry, Int(max_entries), Int(max_lines),
        Int(max_page_bytes), Int(max_file_bytes))
end

workspace_file_error(message::AbstractString) = RpcError(-32602, String(message))
workspace_file_unavailable(message::AbstractString) = RpcError(-32044, String(message))

"""Only normalized relative paths without escapes are accepted at this boundary."""
function workspace_file_segments(relative::AbstractString)
    segments = isempty(relative) ? String[] : String.(split(relative, '/'; keepempty=true))
    if ncodeunits(relative) > 4096 || isabspath(relative) ||
            occursin('\\', relative) || occursin(':', relative) ||
            occursin('\0', relative) ||
            any(part -> isempty(part) || part in (".", ".."), segments)
        nothing
    else
        segments
    end
end

"""Resolve against one registered workspace, refusing symlinks at every path component."""
function workspace_file_target(files::WorkspaceFileService, workspace_id, relative)
    if !(workspace_id isa AbstractString && relative isa AbstractString)
        workspace_file_error("A registered workspaceId and relative path are required")
    else
        segments = workspace_file_segments(relative)
        if isnothing(segments)
            workspace_file_error("Invalid workspace-relative path")
        else
            rows = workspace_snapshot(files.registry)["workspaces"]
            index = findfirst(row -> row["id"] == workspace_id, rows)
            if isnothing(index)
                workspace_file_unavailable("Unknown registered workspace")
            else
                root = String(rows[index]["path"])
                workspace_file_resolved(root, segments, relative)
            end
        end
    end
end

function workspace_file_resolved(root::String, segments::Vector{String}, relative)
    if !isdir(root) || islink(root) || realpath(root) != root
        workspace_file_unavailable("Registered workspace is no longer a safe directory")
    else
        candidate = root
        unsafe = false
        for segment in segments
            candidate = joinpath(candidate, segment)
            unsafe |= islink(candidate)
        end
        if unsafe
            workspace_file_unavailable("Symbolic links are not readable in workspace file inspection")
        else
            (absolutePath=candidate, path=String(relative))
        end
    end
end

workspace_file_version(statinfo) = bytes2hex(SHA.sha256(
    string(statinfo.device, ':', statinfo.inode, ':', statinfo.size, ':', statinfo.mtime, ':', statinfo.ctime)))

function workspace_file_identity(path::AbstractString)
    information = stat(path)
    Dict{String,Any}("absolutePath" => String(path),
        "version" => workspace_file_version(information), "bytes" => information.size)
end

"""Read metadata for a regular file without reading or modifying its contents."""
function workspace_file_stat(files::WorkspaceFileService, workspace_id, relative)
    target = workspace_file_target(files, workspace_id, relative)
    if target isa RpcError
        target
    elseif !isfile(target.absolutePath)
        workspace_file_unavailable("Workspace file does not exist or is not regular")
    else
        workspace_file_identity(target.absolutePath)
    end
end

"""List direct children in stable order, reporting truncation rather than hiding it."""
function workspace_file_list(files::WorkspaceFileService, workspace_id, relative="")
    target = workspace_file_target(files, workspace_id, relative)
    if target isa RpcError
        target
    elseif !isdir(target.absolutePath)
        workspace_file_unavailable("Workspace directory does not exist")
    else
        names = readdir(target.absolutePath; sort=true)
        visible = Iterators.take(names, files.max_entries)
        entries = Dict{String,Any}[]
        for name in visible
            path = joinpath(target.absolutePath, name)
            kind = islink(path) ? "other" : isdir(path) ? "directory" :
                isfile(path) ? "file" : "other"
            row = Dict{String,Any}("name" => name, "type" => kind)
            if kind == "file"
                row["size"] = filesize(path)
            end
            push!(entries, row)
        end
        Dict("path" => target.path, "entries" => entries,
            "truncated" => length(names) > files.max_entries)
    end
end

"""Page UTF-8 text by one-based line numbers, rejecting binary and changed files."""
function workspace_file_read(files::WorkspaceFileService, workspace_id, relative;
        offset=1, limit=files.max_lines)
    if !(offset isa Integer && !(offset isa Bool) && 1 <= offset <= typemax(Int) &&
            limit isa Integer && !(limit isa Bool) && 1 <= limit <= files.max_lines)
        workspace_file_error("Invalid text line window")
    else
        target = workspace_file_stat(files, workspace_id, relative)
        if target isa RpcError
            target
        elseif target["bytes"] > files.max_file_bytes
            workspace_file_unavailable("Workspace file exceeds the text inspection limit")
        else
            workspace_file_read_page(files, target, Int(offset), Int(limit))
        end
    end
end

"""Verify the opened descriptor and name refer to the observed regular file."""
function workspace_file_read_checked(metadata::AbstractDict, offset::Int, count::Int)
    path = metadata["absolutePath"]
    expected = metadata["version"]
    open(path, "r") do stream
        initial = workspace_file_version(stat(stream))
        if initial != expected || islink(path) || !isfile(path) ||
                realpath(path) != path || workspace_file_version(stat(path)) != expected
            workspace_file_unavailable("Workspace file changed before reading")
        else
            seek(stream, offset)
            bytes = read(stream, count)
            if workspace_file_version(stat(stream)) != expected || islink(path) ||
                    !isfile(path) || realpath(path) != path ||
                    workspace_file_version(stat(path)) != expected
                workspace_file_unavailable("Workspace file changed while reading")
            else
                bytes
            end
        end
    end
end

function workspace_file_read_page(files::WorkspaceFileService, metadata::AbstractDict, offset::Int, limit::Int)
    bytes = workspace_file_read_checked(metadata, 0, files.max_file_bytes + 1)
    if bytes isa RpcError
        bytes
    elseif length(bytes) > files.max_file_bytes
        workspace_file_unavailable("Workspace file exceeds the text inspection limit")
    else
        workspace_file_text_page(metadata, offset, limit, String(bytes))
    end
end

function workspace_file_text_page(metadata::AbstractDict, offset::Int, limit::Int, text::String)
    if !isvalid(text) || occursin('\0', text)
        workspace_file_unavailable("Workspace file is not UTF-8 text")
    else
        lines = split(text, '\n'; keepempty=true)
        endswith(text, "\n") && pop!(lines)
        last_line = offset > length(lines) ? length(lines) : min(length(lines), offset + limit - 1)
        count = max(0, last_line - offset + 1)
        page = count == 0 ? "" : join(@view(lines[offset:last_line]), "\n")
        Dict{String,Any}("absolutePath" => metadata["absolutePath"],
            "version" => metadata["version"], "bytes" => metadata["bytes"],
            "offset" => offset, "lines" => count, "text" => page,
            "eof" => last_line >= length(lines))
    end
end

"""Read a zero-based byte window; callers choose their transport encoding."""
function workspace_file_bytes(files::WorkspaceFileService, workspace_id, relative;
        offset=0, count=files.max_page_bytes)
    if !(offset isa Integer && !(offset isa Bool) && 0 <= offset <= typemax(Int) &&
            count isa Integer && !(count isa Bool) && 1 <= count <= files.max_page_bytes)
        workspace_file_error("Invalid byte window")
    else
        target = workspace_file_stat(files, workspace_id, relative)
        if target isa RpcError
            target
        else
            workspace_file_read_bytes(files, target, Int(offset), Int(count))
        end
    end
end

function workspace_file_read_bytes(files::WorkspaceFileService, metadata::AbstractDict,
        offset::Int, count::Int)
    bytes = workspace_file_read_checked(metadata, offset, count)
    if bytes isa RpcError
        bytes
    else
        Dict{String,Any}("absolutePath" => metadata["absolutePath"],
            "version" => metadata["version"], "bytes" => metadata["bytes"],
            "offset" => offset, "data" => bytes,
            "eof" => offset >= metadata["bytes"] ||
                length(bytes) >= metadata["bytes"] - offset)
    end
end

"""Check file freshness without transferring contents; clients can poll when desired."""
function workspace_file_observe(files::WorkspaceFileService, workspace_id, relative; version=nothing)
    target = workspace_file_target(files, workspace_id, relative)
    if target isa RpcError
        target
    elseif !isfile(target.absolutePath)
        Dict("absent" => true, "changed" => !isnothing(version))
    else
        metadata = workspace_file_identity(target.absolutePath)
        metadata["absent"] = false
        metadata["changed"] = isnothing(version) || metadata["version"] != version
        metadata
    end
end

"""Expose read-only workspace inspection as a replaceable plugin service."""
function workspace_files_plugin(; name=:workspace_files, service_name=:workspace_files,
        workspace_service=:workspace_registry, factory=WorkspaceFileService)
    contract = Symbol(service_name)
    dependency = Symbol(workspace_service)
    setup = context -> provide!(context, contract,
        Base.invokelatest(factory, service(context, dependency)))
    PluginSpec(name, setup; requires=[dependency], provides=[contract])
end
