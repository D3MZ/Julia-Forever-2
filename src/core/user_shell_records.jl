"""Preserve shell display and exclusion semantics independently of provider-neutral text."""
struct UserShellMetadata
    record::Dict{String,Any}
end
wire_metadata(::UserShellMetadata)=nothing

"""Create a durable message only from a real completed process result, never from model output."""
function user_shell_message(command::String,result::UserShellProcess.Result;exclude_from_context::Bool=false,
        execution_id::UUID=uuid4(),timestamp::Integer=floor(Int,time()*1000))
    result.ok || error("Cannot commit a failed shell execution attempt: "*result.reason)
    record=Dict{String,Any}("role"=>"bashExecution","command"=>command,"output"=>result.output,
        "exitCode"=>result.exit_code,"cancelled"=>result.cancelled,"truncated"=>result.truncated,
        "excludeFromContext"=>exclude_from_context,"timestamp"=>timestamp,"jf2ExecutionId"=>string(execution_id))
    isnothing(result.full_output_path) || (record["fullOutputPath"]=result.full_output_path)
    Message(:user,timeline_bash_text(record);metadata=UserShellMetadata(record))
end
function user_shell_record(message::Message{UserShellMetadata})
    record=message.metadata.record
    valid=timeline_valid_message(record) && timeline_json_value(record) &&
        message.role==:user && message.kind==:text && message.content==timeline_bash_text(record)
    valid || error("Shell execution content or archival metadata changed without an adapter")
    timeline_object(record)
end
model_context_message(message::Message{UserShellMetadata})=
    get(user_shell_record(message),"excludeFromContext",false) ? nothing : Message(:user,message.content)
function timeline_archive_message(message::Message{UserShellMetadata};timestamp=nothing,
        provider_message=nothing,provider=nothing,model=nothing,api=nothing)
    any(!isnothing,(provider_message,provider,model,api)) && error("Shell execution records cannot carry provider result overrides")
    user_shell_record(message)
end
stored_session_version(::Message{UserShellMetadata})=3
function stored_session_message(message::Message{UserShellMetadata})
    Dict("role"=>String(message.role),"content"=>message.content,"kind"=>String(message.kind),"shell"=>user_shell_record(message))
end
function restored_shell_message(entry::AbstractDict,version::Int)
    version==3 || error("Shell execution records require stored session version 3")
    raw=get(entry,"shell",nothing)
    raw isa AbstractDict || error("Invalid stored shell execution record")
    message=Message(Symbol(entry["role"]),String(entry["content"]),Symbol(entry["kind"]);metadata=UserShellMetadata(timeline_object(raw)))
    user_shell_record(message)
    message
end
