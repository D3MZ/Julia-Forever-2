const INLINE_CONTENT_MAX_BYTES = 32 * 1024 * 1024
const INLINE_CONTENT_MAX_BLOCKS = 4096
const INLINE_CONTENT_MAX_IMAGES = 64
const INLINE_IMAGE_MIMES = ("image/png", "image/jpeg", "image/gif", "image/webp")

"""A static admission error, never image bytes or untrusted metadata."""
struct InlineContentFailure
    reason::Symbol
end
abstract type NativeInlineBlock end

function inline_base64_value(byte::UInt8)
    0x41 <= byte <= 0x5a && return Int(byte - 0x41)
    0x61 <= byte <= 0x7a && return Int(byte - 0x61) + 26
    0x30 <= byte <= 0x39 && return Int(byte - 0x30) + 52
    byte == 0x2b && return 62
    byte == 0x2f && return 63
    -1
end
function inline_base64_valid(data::String)
    count = ncodeunits(data)
    0 < count <= INLINE_CONTENT_MAX_BYTES && count % 4 == 0 || return false
    padding = codeunit(data, count) == 0x3d ? (codeunit(data, count - 1) == 0x3d ? 2 : 1) : 0
    for index in 1:count - padding
        inline_base64_value(codeunit(data, index)) >= 0 || return false
    end
    final = inline_base64_value(codeunit(data, count - padding))
    padding == 2 ? final & 0x0f == 0 : padding == 1 ? final & 0x03 == 0 : true
end

"""Immutable owned text in explicit native multimodal content."""
struct InlineText <: NativeInlineBlock
    text::String
    function InlineText(text::String)
        isvalid(text) && ncodeunits(text) <= INLINE_CONTENT_MAX_BYTES || error("Invalid inline text")
        new(text)
    end
end
function InlineText(text::AbstractString)
    codeunit(text) === UInt8 && ncodeunits(text) <= INLINE_CONTENT_MAX_BYTES || error("Invalid inline text")
    InlineText(String(text))
end

"""Immutable base64 and normalized MIME, never a URL or deferred filesystem read."""
struct InlineImage <: NativeInlineBlock
    data::String
    mime_type::String
    function InlineImage(data::String, mime_type::String)
        mime_type in INLINE_IMAGE_MIMES && inline_base64_valid(data) || error("Invalid inline image")
        new(data, mime_type)
    end
end

function inline_image(data::AbstractString, mime_type::AbstractString)
    codeunit(data) === UInt8 && 0 < ncodeunits(data) <= INLINE_CONTENT_MAX_BYTES &&
        codeunit(mime_type) === UInt8 && 0 < ncodeunits(mime_type) <= 128 || return InlineContentFailure(:image_budget)
    owned, mime = String(data), lowercase(strip(String(mime_type)))
    mime == "image/jpg" && (mime = "image/jpeg")
    mime in INLINE_IMAGE_MIMES || return InlineContentFailure(:image_mime)
    inline_base64_valid(owned) || return InlineContentFailure(:image_base64)
    InlineImage(owned, mime)
end

function inline_block_bytes(block::InlineText)
    bytes = 32
    for byte in codeunits(block.text)
        bytes += byte < 0x20 ? 6 : byte in (0x22, 0x5c) ? 2 : 1
        bytes > INLINE_CONTENT_MAX_BYTES && return bytes
    end
    bytes
end
inline_block_bytes(block::InlineImage) = ncodeunits(block.data) + ncodeunits(block.mime_type) + 64
function inline_blocks_valid(blocks::Tuple)
    length(blocks) <= INLINE_CONTENT_MAX_BLOCKS || return false
    bytes, images = 0, 0
    for block in blocks
        block isa Union{InlineText,InlineImage} || return false
        images += block isa InlineImage
        count = inline_block_bytes(block)
        count <= INLINE_CONTENT_MAX_BYTES - bytes && images <= INLINE_CONTENT_MAX_IMAGES || return false
        bytes += count
    end
    true
end

"""Own immutable content independently of preserved, explicitly snapshotted message provenance."""
struct InlineContentMetadata{M}
    blocks::Tuple
    original::M
    function InlineContentMetadata(blocks::Tuple, original)
        inline_blocks_valid(blocks) || error("Invalid inline content")
        inline_original_valid(original) || error("Unsupported or over-budget inline provenance")
        owned = inline_original_snapshot(original)
        new{typeof(owned)}(blocks, owned)
    end
end
Base.:(==)(left::InlineText, right::InlineText) = left.text == right.text
Base.:(==)(left::InlineImage, right::InlineImage) = left.data == right.data && left.mime_type == right.mime_type
inline_original_snapshot(::Nothing) = nothing
inline_original_snapshot(original::ProviderMessageMetadata) =
    ProviderMessageMetadata(inline_original_snapshot(original.original), timeline_object(original.context))
inline_original_snapshot(::InlineContentMetadata) = error("Nested inline content is not supported")
inline_original_snapshot(original::ExecutionResult) = ExecutionResult(original.ok, original.text, deepcopy(original.value))
inline_original_snapshot(original) = deepcopy(original)

function inline_json_storage_valid(value, depth::Int, nodes::Base.RefValue{Int})
    nodes[] += 1
    depth <= MODEL_IMAGE_MAX_DEPTH && nodes[] <= MODEL_IMAGE_MAX_NODES || return false
    if value isa String
        ncodeunits(value) <= INLINE_CONTENT_MAX_BYTES && isvalid(value)
    elseif value isa Union{Nothing,Bool,Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128,BigInt,Float16,Float32,Float64}
        true
    elseif value isa AbstractVector
        length(value) <= MODEL_IMAGE_MAX_NODES && all(item -> inline_json_storage_valid(item, depth + 1, nodes), value)
    elseif value isa AbstractDict
        length(value) <= MODEL_IMAGE_MAX_NODES && all(pair -> pair.first isa String &&
            inline_json_storage_valid(pair.first, depth + 1, nodes) && inline_json_storage_valid(pair.second, depth + 1, nodes), value)
    else
        false
    end
end
function inline_json_budget!(budget, value, depth::Int)
    if isempty(budget.reason)
        if inline_json_storage_valid(value, depth, Ref(0))
            image_wire_scan!(budget, value, depth)
        else
            budget.reason = "Inline provenance requires bounded lossless JSON storage."
        end
    end
    nothing
end
inline_original_budget!(budget, original, depth::Int) = inline_json_budget!(budget, original, depth)
function inline_original_budget!(budget, original::ExecutionResult, depth::Int)
    inline_json_budget!(budget, Dict{String,Any}("ok" => original.ok, "text" => original.text, "value" => original.value), depth)
end
function inline_original_budget!(budget, original::ProviderMessageMetadata, depth::Int)
    if depth >= MODEL_IMAGE_MAX_DEPTH
        budget.reason = "Inline provenance exceeds its depth limit."
    else
        inline_json_budget!(budget, original.context, depth + 1)
        isempty(budget.reason) && inline_original_budget!(budget, original.original, depth + 1)
    end
    nothing
end
inline_original_budget!(budget, ::InlineContentMetadata, depth::Int) =
    (budget.reason = "Nested inline provenance is unsupported."; nothing)
function inline_original_valid(original)
    budget = ModelImageWireBudget()
    inline_original_budget!(budget, original, 0)
    isempty(budget.reason)
end
function inline_require_json(value)
    budget = ModelImageWireBudget()
    inline_json_budget!(budget, value, 0)
    isempty(budget.reason) || error("Unsupported or over-budget inline archival provenance")
    value
end

inline_attached_budget!(budget, metadata::InlineContentMetadata, depth::Int) = inline_original_budget!(budget, metadata.original, depth)
function inline_attached_budget!(budget, metadata::ProviderMessageMetadata, depth::Int)
    if depth >= MODEL_IMAGE_MAX_DEPTH
        budget.reason = "Inline provenance exceeds its depth limit."
    else
        inline_json_budget!(budget, metadata.context, depth + 1)
        isempty(budget.reason) && inline_attached_budget!(budget, metadata.original, depth + 1)
    end
    nothing
end
inline_attached_budget!(budget, metadata, depth::Int) = (budget.reason = "Invalid inline provenance wrapper."; nothing)
function inline_message_provenance_valid(metadata)
    budget = ModelImageWireBudget()
    inline_attached_budget!(budget, metadata, 0)
    isempty(budget.reason)
end
function inline_message_metadata(metadata)
    depth = 0
    while metadata isa ProviderMessageMetadata
        depth += 1
        depth <= MODEL_IMAGE_MAX_DEPTH || error("Inline provenance exceeds its depth limit")
        metadata = metadata.original
    end
    metadata isa InlineContentMetadata ? metadata : nothing
end
function message_inline_content(message::Message)
    metadata = inline_message_metadata(message.metadata)
    isnothing(metadata) ? nothing : metadata.blocks
end
inline_original_result(metadata) = metadata
inline_original_result(metadata::InlineContentMetadata) = inline_original_result(metadata.original)
inline_original_result(metadata::ProviderMessageMetadata) = inline_original_result(metadata.original)
message_result(message::Message{<:InlineContentMetadata}) = inline_original_result(message.metadata)
message_result(message::Message{<:ProviderMessageMetadata{<:InlineContentMetadata}}) = inline_original_result(message.metadata)
function message_result(message::Message{<:ProviderMessageMetadata{<:ProviderMessageMetadata}})
    isnothing(inline_message_metadata(message.metadata)) ? message.metadata.original : inline_original_result(message.metadata)
end
provider_message_context(metadata::InlineContentMetadata) = provider_message_context(metadata.original)
inline_text_content(blocks::Tuple) = join((block.text for block in blocks if block isa InlineText), "")::String

function inline_message(role::Symbol, blocks::Tuple; kind::Symbol=:text, original=nothing)
    role in (:user, :code_result) && kind == :text && inline_blocks_valid(blocks) || return InlineContentFailure(:message_shape)
    metadata = InlineContentMetadata(blocks, original)
    Message(role, inline_text_content(blocks), kind; metadata)
end
function inline_message_valid(message::Message)
    blocks = message_inline_content(message)
    !isnothing(blocks) && message.role in (:user, :code_result) && message.kind == :text &&
        inline_blocks_valid(blocks) && inline_message_provenance_valid(message.metadata) && message.content == inline_text_content(blocks)
end
inline_canonical_block(block::InlineText) = Dict{String,Any}("type" => "text", "text" => block.text)
inline_canonical_block(block::InlineImage) = Dict{String,Any}("type" => "image", "data" => block.data, "mimeType" => block.mime_type)
inline_canonical_content(blocks::Tuple) = Any[inline_canonical_block(block) for block in blocks]

function inline_sendable_blocks(message::Message)
    blocks = message_inline_content(message)
    original = wire_metadata(inline_original_result(message.metadata))
    if message.role == :code_result || !isnothing(original)
        payload = Dict{String,Any}("kind" => message.role == :code_result ? "code_result" : String(message.kind),
            "content" => message.content, "metadata" => original)
        budget = image_wire_budget(payload)
        isempty(budget.reason) || error("Inline status envelope exceeds its JSON budget")
        image_bytes = sum(inline_block_bytes(block) for block in blocks if block isa InlineImage; init=0)
        budget.bytes <= INLINE_CONTENT_MAX_BYTES - image_bytes || error("Inline message exceeds its wire budget")
        envelope = InlineText(JSON.json(payload))
        result = (envelope, (block for block in blocks if block isa InlineImage)...)
        inline_blocks_valid(result) || error("Inline message exceeds its encoded wire budget")
        result
    else
        blocks
    end
end

"""Preserve legacy text semantics; only validated typed content becomes actual native image blocks."""
function native_message_content(message::Message)
    blocks = message_inline_content(message)
    isnothing(blocks) && return wire_content(message)
    inline_message_valid(message) || error("Invalid native inline message")
    inline_canonical_content(inline_sendable_blocks(message))
end

function inline_parse_block(block::AbstractDict)
    kind = get(block, "type", nothing)
    if kind == "text" && length(block) == 2 && Set(keys(block)) == Set(("type", "text")) && get(block, "text", nothing) isa String
        text = block["text"]
        isvalid(text) && ncodeunits(text) <= INLINE_CONTENT_MAX_BYTES ? InlineText(text) : InlineContentFailure(:text_budget)
    elseif kind == "image" && length(block) == 3 && Set(keys(block)) == Set(("type", "data", "mimeType")) &&
            get(block, "data", nothing) isa String && get(block, "mimeType", nothing) isa String
        inline_image(block["data"], block["mimeType"])
    else
        InlineContentFailure(:block_shape)
    end
end
inline_parse_block(block) = InlineContentFailure(:block_shape)
function parse_inline_content(content::AbstractVector)
    length(content) <= INLINE_CONTENT_MAX_BLOCKS || return InlineContentFailure(:block_count)
    parsed = NativeInlineBlock[]
    bytes, images = 0, 0
    for block in content
        value = inline_parse_block(block)
        value isa InlineContentFailure && return value
        count = inline_block_bytes(value)
        images += value isa InlineImage
        count <= INLINE_CONTENT_MAX_BYTES - bytes && images <= INLINE_CONTENT_MAX_IMAGES || return InlineContentFailure(:content_budget)
        bytes += count
        push!(parsed, value)
    end
    Tuple(parsed)
end
parse_inline_content(content) = InlineContentFailure(:content_shape)
