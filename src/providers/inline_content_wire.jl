inline_wire_block(::Val{:openai_chat}, block::InlineText) = Dict{String,Any}("type" => "text", "text" => block.text)
inline_wire_block(::Val{:openai_chat}, block::InlineImage) = Dict{String,Any}("type" => "image_url",
    "image_url" => Dict{String,Any}("url" => "data:" * block.mime_type * ";base64," * block.data))
inline_wire_block(::Val{:anthropic}, block::InlineText) = Dict{String,Any}("type" => "text", "text" => block.text)
inline_wire_block(::Val{:anthropic}, block::InlineImage) = Dict{String,Any}("type" => "image",
    "source" => Dict{String,Any}("type" => "base64", "media_type" => block.mime_type, "data" => block.data))
inline_wire_block(::Val{:responses}, block::InlineText) = Dict{String,Any}("type" => "input_text", "text" => block.text)
inline_wire_block(::Val{:responses}, block::InlineImage) = Dict{String,Any}("type" => "input_image",
    "detail" => "auto", "image_url" => "data:" * block.mime_type * ";base64," * block.data)

"""Convert only explicit native inline content using the selected provider's actual wire shape."""
function inline_wire_content(format::Val, message::Message)
    blocks = message_inline_content(message)
    isnothing(blocks) && return wire_content(message)
    inline_message_valid(message) || error("Invalid native inline message")
    Any[inline_wire_block(format, block) for block in inline_sendable_blocks(message)]
end

"""Never silently stringify typed image bytes for a provider lacking an explicit adapter."""
wire_content(message::Message{<:InlineContentMetadata}) = error("This provider requires a native inline-content adapter")

function inline_message_budget!(budget, value::Message, depth)
    if budget.native_messages && depth == 1 && inline_message_valid(value)
        image_wire_scan!(budget, native_message_content(value), depth + 1)
    else
        budget.reason = "Image policy rejected an invalid native inline message."
    end
    nothing
end
image_wire_value!(budget, value::Message{<:InlineContentMetadata}, depth) = inline_message_budget!(budget, value, depth)
function image_wire_value!(budget, value::Message{<:ProviderMessageMetadata}, depth)
    if !isnothing(message_inline_content(value))
        inline_message_budget!(budget, value, depth)
    elseif budget.native_messages && depth == 1
        image_wire_scan!(budget, value.content, depth + 1)
    else
        budget.reason = "Image policy rejected a native message object embedded in wire JSON."
    end
    nothing
end

inline_replace_blocks(metadata::InlineContentMetadata, blocks::Tuple) = InlineContentMetadata(blocks, metadata.original)
inline_replace_blocks(metadata::ProviderMessageMetadata, blocks::Tuple) =
    ProviderMessageMetadata(inline_replace_blocks(metadata.original, blocks), timeline_object(metadata.context))
function inline_project_blocked(message::Message)
    inline_message_valid(message) || return ModelImagePolicyFailure("Image policy rejected an invalid native inline message.")
    blocks = NativeInlineBlock[]
    for block in message_inline_content(message)
        projected = block isa InlineImage ? InlineText(BLOCKED_IMAGE_TEXT) : block
        duplicate = !isempty(blocks) && projected isa InlineText && last(blocks) isa InlineText &&
            projected.text == BLOCKED_IMAGE_TEXT && last(blocks).text == BLOCKED_IMAGE_TEXT
        duplicate || push!(blocks, projected)
    end
    owned = Tuple(blocks)
    Message(message.role, inline_text_content(owned), message.kind; metadata=inline_replace_blocks(message.metadata, owned))
end
project_model_image_message(message::Message{<:InlineContentMetadata}, format) = inline_project_blocked(message)
project_model_image_message(message::Message{<:ProviderMessageMetadata}, format) =
    isnothing(message_inline_content(message)) ? message : inline_project_blocked(message)
