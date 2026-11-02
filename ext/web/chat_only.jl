"""A browser chat executor that never evaluates model source or invokes host tools."""
struct WebChatExecutor end
JuliaForever2.execute!(::WebChatExecutor, action, context::JuliaForever2.ExecutionContext) =
    JuliaForever2.ExecutionResult(false, "This private web workspace is chat-only. Host code, files and tools are not enabled.")

"""Create sessions with the standard native loop and an unconditional no-execution boundary."""
struct WebChatFactory{P}
    provider::P
end
const WEB_CHAT_INSTRUCTIONS = "You are Julia Forever in a private chat-only browser workspace. Respond with a JSON object with kind=answer and content containing your answer. You cannot execute code, access host files, run tools or browse. Do not claim that you performed those actions. Explain limitations plainly."
(factory::WebChatFactory)() = JuliaForever2.AgentDefinition(factory.provider; executor_factory=WebChatExecutor,
    protocol=JuliaForever2.CodeModePolicy(WEB_CHAT_INSTRUCTIONS))

"""Start an isolated chat-only browser service with a native ChatGPT subscription provider."""
function JuliaForever2.start_web_server(provider::JuliaForever2.OpenAIProvider;
        store=nothing, titles=isnothing(store) ? nothing : JuliaForever2.SessionTitleService(; store), kwargs...)
    api = JuliaForever2.SessionAPI(; factory=WebChatFactory(provider), store, titles)
    JuliaForever2.start_web_server(api; kwargs...)
end

"""Public exposure requires a dedicated, unopened chat-only session API, not an ambient agent API."""
function remote_web_api_allowed(api, public_origin, workspace)
    isempty(public_origin) || api.factory isa WebChatFactory &&
        lock(() -> isempty(api.sessions) && isempty(api.handles) && !api.closed, api.lock) &&
        remote_web_store_allowed(api.store, realpath(workspace))
end

remote_web_store_allowed(::Nothing, workspace) = true
remote_web_store_allowed(store, workspace) = false
function remote_web_store_allowed(store::JuliaForever2.SessionStore, workspace)
    directory = abspath(store.directory)
    prefix = workspace * (Sys.iswindows() ? "\\" : "/")
    ancestor = directory
    while !ispath(ancestor) && dirname(ancestor) != ancestor
        ancestor = dirname(ancestor)
    end
    canonical = realpath(ancestor)
    contained = startswith(directory, prefix) && !islink(ancestor) &&
        (canonical == workspace || startswith(canonical, prefix))
    contained && (!isdir(directory) || remote_web_store_contents_allowed(store, workspace))
end

function remote_web_store_contents_allowed(store::JuliaForever2.SessionStore, workspace)
    safe = true
    for (directory, folders, files) in walkdir(store.directory; follow_symlinks=false)
        safe &= all(name -> !islink(joinpath(directory, name)), vcat(folders, files))
    end
    for name in readdir(store.directory)
        if endswith(name, ".json")
            record = JuliaForever2.saved_session_record(store, name[1:end-5])
            safe &= !isnothing(record) && abspath(record.directory) == workspace
        end
    end
    safe
end
