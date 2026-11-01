"""A decoded, temporary response preview; it never becomes conversation history by itself."""
struct ResponseProgress
    kind::Symbol
    text::String
end

protocol_progress(policy, text::AbstractString) = nothing

protocol_whitespace(byte::UInt8) = byte in (0x20, 0x09, 0x0a, 0x0d)

function skip_protocol_whitespace(bytes, index)
    while index <= length(bytes) && protocol_whitespace(bytes[index])
        index += 1
    end
    return index
end

function protocol_hex_digit(byte::UInt8)
    if 0x30 <= byte <= 0x39
        Int(byte - 0x30)
    elseif 0x41 <= byte <= 0x46
        Int(byte - 0x41) + 10
    elseif 0x61 <= byte <= 0x66
        Int(byte - 0x61) + 10
    else
        -1
    end
end
function protocol_hex_quad(bytes, index)
    if index + 3 > length(bytes)
        (value=0, next=index, status=:incomplete)
    else
        hexadecimal(bytes, index)
    end
end

function hexadecimal(bytes, index)
    value = 0
    offset = 0
    valid = true
    while offset < 4 && valid
        digit = protocol_hex_digit(bytes[index + offset])
        valid = digit >= 0
        value = 16 * value + digit
        offset += 1
    end
    valid ? (value, next=index + 4, status=:complete) : (value=0, next=index, status=:invalid)
end
function protocol_unicode_escape(bytes, index)
    first = protocol_hex_quad(bytes, index)
    if first.status != :complete
        first
    elseif 0xd800 <= first.value <= 0xdbff
        surrogate(bytes, index, first)
    elseif 0xdc00 <= first.value <= 0xdfff
        (value=0, next=index, status=:invalid)
    else
        first
    end
end

function surrogate(bytes, index, first)
    next = first.next
    if next + 1 > length(bytes)
        (value=0, next=index, status=:incomplete)
    elseif bytes[next] != 0x5c || bytes[next + 1] != 0x75
        (value=0, next=index, status=:invalid)
    else
        surrogate(index, first, protocol_hex_quad(bytes, next + 2))
    end
end

function surrogate(index::Integer, first, second)
    if second.status != :complete
        second
    elseif 0xdc00 <= second.value <= 0xdfff
        (value=0x10000 + (first.value - 0xd800) * 0x400 + second.value - 0xdc00, next=second.next, status=:complete)
    else
        (value=0, next=index, status=:invalid)
    end
end
function protocol_utf8_size(byte::UInt8)
    if 0xc2 <= byte <= 0xdf
        2
    elseif 0xe0 <= byte <= 0xef
        3
    elseif 0xf0 <= byte <= 0xf4
        4
    else
        0
    end
end
"""Validate UTF-8 continuation bytes without allocating temporary substring views."""
protocol_utf8_continuation(byte::UInt8) = 0x80 <= byte <= 0xbf

function protocol_utf8_valid(bytes, index, size)
    lead = bytes[index]
    second = bytes[index + 1]
    if size == 2
        protocol_utf8_continuation(second)
    elseif size == 3
        protocol_utf8_continuation(bytes[index + 2]) && continuation(lead, second, 0xe0, 0xa0, 0xed, 0x9f)
    else
        protocol_utf8_continuation(bytes[index + 2]) && protocol_utf8_continuation(bytes[index + 3]) && continuation(lead, second, 0xf0, 0x90, 0xf4, 0x8f)
    end
end

function continuation(lead, second, lowerlead, lower, upperlead, upper)
    if lead == lowerlead
        lower <= second <= 0xbf
    elseif lead == upperlead
        0x80 <= second <= upper
    else
        protocol_utf8_continuation(second)
    end
end
protocol_string_buffer(::Nothing) = IOBuffer()
protocol_string_buffer(output::IOBuffer) = output

protocol_string_result(::Nothing, bytes, pending, index, status) = (text=String(@view bytes[pending]), next=index, status)

function protocol_string_result(output::IOBuffer, bytes, pending, index, status)
    write(output, @view bytes[pending])
    return (text=takestring!(output), next=index, status)
end

"""Read the complete decoded prefix of one JSON string without accepting unfinished escapes."""
function protocol_string(bytes, index)
    if index > length(bytes)
        (text="", next=index, status=:incomplete)
    elseif bytes[index] != 0x22
        (text="", next=index, status=:invalid)
    else
        scanstring(bytes, index + 1)
    end
end

struct StringEscape
    value::Union{Nothing,Char,UInt8}
    next::Int
    status::Symbol

    function StringEscape(value::Union{Nothing,Char,UInt8}, next::Int, status::Symbol)
        if (isnothing(value) && status in (:incomplete, :invalid)) || (!isnothing(value) && status == :complete)
            new(value, next, status)
        else
            error("Invalid decoded escape state")
        end
    end
end

@inline function StringEscape(bytes, index::Int)
    if index == length(bytes)
        StringEscape(nothing, index, :incomplete)
    elseif bytes[index + 1] == 0x75
        character = protocol_unicode_escape(bytes, index + 2)
        character.status == :complete ? StringEscape(Char(character.value), character.next, :complete) : StringEscape(nothing, index, character.status)
    else
        byte = unescape(bytes[index + 1])
        isnothing(byte) ? StringEscape(nothing, index, :invalid) : StringEscape(byte, index + 2, :complete)
    end
end

function unescape(byte::UInt8)
    if byte == 0x62
        0x08
    elseif byte == 0x66
        0x0c
    elseif byte == 0x6e
        0x0a
    elseif byte == 0x72
        0x0d
    elseif byte == 0x74
        0x09
    else
        byte in (0x22, 0x5c, 0x2f) ? byte : nothing
    end
end

emit!(output::IOBuffer, character::Char) = print(output, character)
emit!(output::IOBuffer, byte::UInt8) = write(output, byte)

function escaped(output, bytes, pending, value::Union{Char,UInt8})
    buffer = protocol_string_buffer(output)
    write(buffer, @view bytes[pending])
    emit!(buffer, value)
    buffer
end

function scalar(bytes, index)
    size = protocol_utf8_size(bytes[index])
    if size == 0
        (next=index, status=:invalid)
    elseif index + size - 1 > length(bytes)
        (next=index, status=:incomplete)
    elseif protocol_utf8_valid(bytes, index, size)
        (next=index + size, status=:pending)
    else
        (next=index, status=:invalid)
    end
end

function scanstring(bytes, index)
    first = index
    output = nothing
    status = :pending
    while index <= length(bytes) && status == :pending
        byte = bytes[index]
        if byte == 0x22
            status = :complete
        elseif byte == 0x5c
            escape = StringEscape(bytes, index)
            value = escape.value
            if isnothing(value)
                status = escape.status
            else
                output = escaped(output, bytes, first:(index - 1), value)
                index = escape.next
                first = index
            end
        elseif byte < 0x20
            status = :invalid
        elseif byte < 0x80
            index += 1
        else
            character = scalar(bytes, index)
            index, status = character.next, character.status
        end
    end
    next = status == :complete ? index + 1 : index
    protocol_string_result(output, bytes, first:(index - 1), next, status == :pending ? :incomplete : status)
end
response_progress(kind, content::Nothing) = nothing
response_progress(kind, content::String) = kind in (:answer, :code) ? ResponseProgress(kind, content) : nothing

"""Track the parsed fields and position of a cumulative response preview."""
struct ResponsePreview
    kind::Symbol
    content::Union{Nothing,String}
    seen_kind::Bool
    seen_content::Bool
    after_comma::Bool
    index::Int
    status::Symbol
end

ResponsePreview(index::Int) = ResponsePreview(:unknown, nothing, false, false, false, index, :pending)
ResponsePreview(preview::ResponsePreview; kind=preview.kind, content=preview.content, seen_kind=preview.seen_kind, seen_content=preview.seen_content, after_comma=preview.after_comma, index=preview.index, status=preview.status) = ResponsePreview(kind, content, seen_kind, seen_content, after_comma, index, status)

"""Decode semantic previews from cumulative code-mode JSON, in either field order."""
function protocol_progress(::CodeModePolicy, text::AbstractString)
    bytes = codeunits(text)
    index = skip_protocol_whitespace(bytes, 1)
    index <= length(bytes) && bytes[index] == 0x7b ? preview(bytes, ResponsePreview(index + 1)) : nothing
end

function preview(bytes, state::ResponsePreview)
    while state.status == :pending
        state = advance(state, bytes)
    end
    state.status == :invalid ? nothing : response_progress(state.kind, state.content)
end

function advance(state::ResponsePreview, bytes)
    index = skip_protocol_whitespace(bytes, state.index)
    if index > length(bytes)
        ResponsePreview(state; status=:incomplete)
    elseif bytes[index] == 0x7d
        valid = !state.after_comma && skip_protocol_whitespace(bytes, index + 1) > length(bytes)
        ResponsePreview(state; status=valid ? :complete : :invalid)
    else
        field(state, bytes, protocol_string(bytes, index))
    end
end

function field(state::ResponsePreview, bytes, key)
    index = skip_protocol_whitespace(bytes, key.next)
    if key.status != :complete
        ResponsePreview(state; status=key.status)
    elseif index > length(bytes)
        ResponsePreview(state; status=:incomplete)
    elseif bytes[index] != 0x3a
        ResponsePreview(state; status=:invalid)
    else
        value = protocol_string(bytes, skip_protocol_whitespace(bytes, index + 1))
        separate(update(state, key.text, value), bytes, value)
    end
end

function update(state::ResponsePreview, key, value)
    if value.status == :invalid
        ResponsePreview(state; status=:invalid)
    elseif key == "kind" && !state.seen_kind
        kind = value.status == :complete ? responsekind(value.text) : state.kind
        ResponsePreview(state; kind, seen_kind=true)
    elseif key == "content" && !state.seen_content
        ResponsePreview(state; content=value.text, seen_content=true)
    else
        ResponsePreview(state; status=:invalid)
    end
end

responsekind(text) = text == "answer" ? :answer : text == "code" ? :code : :unknown

function separate(state::ResponsePreview, bytes, value)
    index = skip_protocol_whitespace(bytes, value.next)
    if state.status == :invalid
        state
    elseif value.status == :incomplete || index > length(bytes)
        ResponsePreview(state; status=:incomplete)
    elseif bytes[index] == 0x2c
        ResponsePreview(state; index=index + 1, after_comma=true)
    elseif bytes[index] == 0x7d
        ResponsePreview(state; index, after_comma=false)
    else
        ResponsePreview(state; status=:invalid)
    end
end
"""Publish an operation-scoped decoded preview while keeping wire fragments private to adapters."""
function emit_protocol_progress!(policy, text::AbstractString, context::ExecutionContext)
    progress = cancelled(context) ? nothing : protocol_progress(policy, text)
    if !isnothing(progress)
        emit!(context, HarnessEvent(:response_progress, (operation_id=operation_id(context), progress)))
    end
    progress
end
