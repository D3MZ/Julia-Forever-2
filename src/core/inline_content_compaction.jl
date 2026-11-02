# Pinned Pi compaction.ts uses 4800 estimated characters per image (1200 tokens).
const INLINE_IMAGE_ESTIMATED_CHARS = 4800
function inline_estimated_tokens(message::Message)
    blocks = message_inline_content(message)
    isnothing(blocks) && return estimated_tokens(message.content)
    inline_message_valid(message) || error("Invalid inline context message")
    chars = sum(block -> block isa InlineImage ? INLINE_IMAGE_ESTIMATED_CHARS : ncodeunits(block.text), blocks; init=0)
    cld(chars, 4)
end

"""Mark retained visual content honestly in a text-only summary, never invent an image description."""
function summary_message_text(message::Message)
    blocks = message_inline_content(message)
    isnothing(blocks) && return message.content
    inline_message_valid(message) || error("Invalid inline summary message")
    join((block isa InlineText ? block.text :
        "[Image retained in original history: $(block.mime_type); visual content is not included in this text-only summary.]"
        for block in blocks), "")::String
end
