"""Snapshot supported input-image filtering for one model request, not process-global permissions."""
Base.@kwdef struct ModelImagePolicy
    block_images::Bool=false
end
const MODEL_IMAGE_POLICY=Base.ScopedValues.ScopedValue(ModelImagePolicy())
const BLOCKED_IMAGE_TEXT="Image reading is disabled."
model_image_policy()=MODEL_IMAGE_POLICY[]
with_model_image_policy(callback,policy::ModelImagePolicy)=Base.ScopedValues.with(callback,MODEL_IMAGE_POLICY=>policy)
with_model_image_policy(callback,blocked::Bool)=with_model_image_policy(callback,ModelImagePolicy(;block_images=blocked))

image_input_block(block)=false
image_input_block(block::AbstractDict)=get(block,"type",nothing) in ("image","image_url","input_image")
image_input_children(block)=nothing
image_input_children(block::AbstractDict)=get(block,"type",nothing)=="tool_result" ? get(block,"content",nothing) : nothing
image_input_present(content)=false
image_input_present(content::AbstractVector)=any(block->image_input_block(block) || image_input_present(image_input_children(block)),content)
image_placeholder_type(::Val)="text"
image_placeholder_type(::Val{:responses})="input_text"
image_placeholder(format)=Dict{String,Any}("type"=>image_placeholder_type(format),"text"=>BLOCKED_IMAGE_TEXT)
image_placeholder_text(block)=false
image_placeholder_text(block::AbstractDict)=get(block,"type",nothing) in ("text","input_text") && get(block,"text",nothing)==BLOCKED_IMAGE_TEXT

"""Project recognized image blocks and nested tool results without modifying retained source data."""
function project_image_block(block::AbstractDict,format)
    if image_input_block(block)
        image_placeholder(format)
    elseif image_input_present(image_input_children(block))
        merge(block,Dict("content"=>project_image_content(image_input_children(block),format)))
    else
        block
    end
end
project_image_block(block,format)=block
project_image_content(content,format)=content
function project_image_content(content::AbstractVector,format)
    if image_input_present(content)
        projected=Any[]
        for original in content
            block=project_image_block(original,format)
            if isempty(projected) || !image_placeholder_text(block) || !image_placeholder_text(last(projected))
                push!(projected,block)
            end
        end
        projected
    else
        content
    end
end

"""Match Pi's user/tool image policy and preserve assistant signatures and non-image message fields."""
function project_image_message(message::AbstractDict,format)
    role=get(message,"role",nothing)
    if role in ("user","tool","toolResult") && image_input_present(get(message,"content",nothing))
        merge(message,Dict("content"=>project_image_content(message["content"],format)))
    elseif format==Val(:responses) && get(message,"type",nothing)=="function_call_output" && image_input_present(get(message,"output",nothing))
        merge(message,Dict("output"=>project_image_content(message["output"],format)))
    else
        message
    end
end
project_image_message(message,format)=message
project_model_images(messages,policy::ModelImagePolicy=model_image_policy();format=Val(:canonical))=messages
project_model_image_message(message::Message,format)=message
function project_model_image_message(message,format)
    normalized=normalize_model_image_json(message)
    normalized isa ModelImagePolicyFailure ? normalized : project_image_message(normalized,format)
end
function project_model_image_message(message::NamedTuple,format)
    normalized=normalize_model_image_json(message)
    if normalized isa ModelImagePolicyFailure
        normalized
    else
        projected=project_image_message(normalized,format)
        if haskey(message,:content) && haskey(projected,"content")
            merge(message,(content=projected["content"],))
        elseif haskey(message,:output) && haskey(projected,"output")
            merge(message,(output=projected["output"],))
        else
            message
        end
    end
end
function project_model_images(messages::Union{AbstractVector,Tuple},policy::ModelImagePolicy=model_image_policy();format=Val(:canonical))
    if policy.block_images
        budget=image_wire_budget(messages;native_messages=true)
        if !isempty(budget.reason)
            ModelImagePolicyFailure(budget.reason)
        else
            projected=map(message->project_model_image_message(message,format),messages)
            failure=findfirst(message->message isa ModelImagePolicyFailure,projected)
            isnothing(failure) ? projected : projected[failure]
        end
    else
        messages
    end
end
function project_model_images(request::ModelRequest,policy::ModelImagePolicy=model_image_policy())
    messages=project_model_images(request.messages,policy)
    messages isa ModelImagePolicyFailure ? messages : ModelRequest(messages,request.instructions,request.schema,request.response_format,request.protocol)
end

"""Filter a supported final wire payload after provider options; opaque adapters must implement their own policy hook."""
function model_image_payload_field(payload::AbstractDict,field::String,format,policy::ModelImagePolicy)
    if policy.block_images
        normalized=normalize_model_image_json(payload)
        if normalized isa ModelImagePolicyFailure
            normalized
        elseif haskey(normalized,field)
            messages=project_model_images(normalized[field],policy;format)
            messages isa ModelImagePolicyFailure ? messages : merge(normalized,Dict(field=>messages))
        else
            normalized
        end
    else
        payload
    end
end
model_image_payload(protocol,payload,policy::ModelImagePolicy=model_image_policy())=payload
model_image_payload(::Val{:responses},payload::AbstractDict,policy::ModelImagePolicy=model_image_policy())=
    model_image_payload_field(payload,"input",Val(:responses),policy)
model_image_payload(::Val{:openai_chat},payload::AbstractDict,policy::ModelImagePolicy=model_image_policy())=
    model_image_payload_field(payload,"messages",Val(:openai_chat),policy)
model_image_payload(::Val{:anthropic},payload::AbstractDict,policy::ModelImagePolicy=model_image_policy())=
    model_image_payload_field(payload,"messages",Val(:anthropic),policy)
