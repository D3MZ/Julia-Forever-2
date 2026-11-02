"""Expose only opt-in, locally authenticated, read-only workspace file operations."""
function browser_workspace_files(files, method::AbstractString, params::AbstractDict)
    workspace_id = get(params, "workspaceId", nothing)
    relative = get(params, "path", "")
    if !(workspace_id isa AbstractString && relative isa AbstractString)
        JuliaForever2.RpcError(-32602, "workspaceId and relative file path are required")
    elseif method == "workspace/file/list"
        JuliaForever2.workspace_file_list(files, workspace_id, relative)
    elseif method == "workspace/file/stat"
        JuliaForever2.workspace_file_stat(files, workspace_id, relative)
    elseif method == "workspace/file/read"
        JuliaForever2.workspace_file_read(files, workspace_id, relative;
            offset=get(params, "offset", 1), limit=get(params, "limit", 200),
            version=get(params, "version", nothing))
    elseif method == "workspace/file/bytes"
        browser_workspace_file_bytes(files, workspace_id, relative, params)
    elseif method == "workspace/file/observe"
        JuliaForever2.workspace_file_observe(files, workspace_id, relative;
            version=get(params, "version", nothing))
    else
        JuliaForever2.RpcError(-32601, "Unknown workspace file operation")
    end
end

"""JSON transports byte windows as base64; the Julia service returns native bytes."""
function browser_workspace_file_bytes(files, workspace_id, relative, params)
    result = JuliaForever2.workspace_file_bytes(files, workspace_id, relative;
        offset=get(params, "offset", 0), count=get(params, "length", 131_072),
        version=get(params, "version", nothing))
    if result isa JuliaForever2.RpcError
        result
    else
        result["data"] = Base64.base64encode(result["data"])
        result["encoding"] = "base64"
        result
    end
end
