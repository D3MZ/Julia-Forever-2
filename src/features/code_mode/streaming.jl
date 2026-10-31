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
        return Int(byte - 0x30)
    elseif 0x41 <= byte <= 0x46
        return Int(byte - 0x41) + 10
    elseif 0x61 <= byte <= 0x66
        return Int(byte - 0x61) + 10
    end
    return -1
end

function protocol_hex_quad(bytes, index)
    if index + 3 > length(bytes)
        return (value=0, next=index, status=:incomplete)
    end
    value = 0
    for offset in 0:3
        digit = protocol_hex_digit(bytes[index + offset])
        if digit < 0
            return (value=0, next=index, status=:invalid)
        end
        value = 16 * value + digit
    end
    return (value, next=index + 4, status=:complete)
end

function protocol_unicode_escape(bytes, index)
    first = protocol_hex_quad(bytes, index)
    first.status == :complete || return first
    if 0xd800 <= first.value <= 0xdbff
        next = first.next
        if next + 1 > length(bytes)
            return (value=0, next=index, status=:incomplete)
        elseif bytes[next] != 0x5c || bytes[next + 1] != 0x75
            return (value=0, next=index, status=:invalid)
        end
        second = protocol_hex_quad(bytes, next + 2)
        second.status == :complete || return second
        if 0xdc00 <= second.value <= 0xdfff
            value = 0x10000 + (first.value - 0xd800) * 0x400 + second.value - 0xdc00
            return (value, next=second.next, status=:complete)
        end
        return (value=0, next=index, status=:invalid)
    elseif 0xdc00 <= first.value <= 0xdfff
        return (value=0, next=index, status=:invalid)
    end
    return first
end

function protocol_utf8_size(byte::UInt8)
    if 0xc2 <= byte <= 0xdf
        return 2
    elseif 0xe0 <= byte <= 0xef
        return 3
    elseif 0xf0 <= byte <= 0xf4
        return 4
    end
    return 0
end

protocol_string_result(output, index, status) = (text=String(take!(output)), next=index, status)

"""Read the complete decoded prefix of one JSON string without accepting unfinished escapes."""
function protocol_string(bytes, index)
    output = IOBuffer()
    if index > length(bytes)
        return protocol_string_result(output, index, :incomplete)
    elseif bytes[index] != 0x22
        return protocol_string_result(output, index, :invalid)
    end
    index += 1
    while index <= length(bytes)
        byte = bytes[index]
        if byte == 0x22
            return protocol_string_result(output, index + 1, :complete)
        elseif byte == 0x5c
            if index == length(bytes)
                return protocol_string_result(output, index, :incomplete)
            end
            escape = bytes[index + 1]
            if escape == 0x75
                character = protocol_unicode_escape(bytes, index + 2)
                if character.status != :complete
                    return protocol_string_result(output, index, character.status)
                end
                print(output, Char(character.value))
                index = character.next
            else
                escaped = escape == 0x62 ? 0x08 : escape == 0x66 ? 0x0c :
                    escape == 0x6e ? 0x0a : escape == 0x72 ? 0x0d :
                    escape == 0x74 ? 0x09 : escape in (0x22, 0x5c, 0x2f) ? escape : nothing
                if isnothing(escaped)
                    return protocol_string_result(output, index, :invalid)
                end
                write(output, escaped)
                index += 2
            end
        elseif byte < 0x20
            return protocol_string_result(output, index, :invalid)
        elseif byte < 0x80
            write(output, byte)
            index += 1
        else
            size = protocol_utf8_size(byte)
            if size == 0
                return protocol_string_result(output, index, :invalid)
            elseif index + size - 1 > length(bytes)
                return protocol_string_result(output, index, :incomplete)
            end
            character = String(collect(@view bytes[index:(index + size - 1)]))
            if !isvalid(character)
                return protocol_string_result(output, index, :invalid)
            end
            write(output, character)
            index += size
        end
    end
    return protocol_string_result(output, index, :incomplete)
end

response_progress(kind, content::Nothing) = nothing
response_progress(kind, content::String) = kind in (:answer, :code) ? ResponseProgress(kind, content) : nothing

"""Decode semantic previews from cumulative code-mode JSON, in either field order."""
function protocol_progress(::CodeModePolicy, text::AbstractString)
    bytes = codeunits(text)
    index = skip_protocol_whitespace(bytes, 1)
    if index > length(bytes) || bytes[index] != 0x7b
        return nothing
    end
    index += 1
    kind = :unknown
    content = nothing
    seen_kind = false
    seen_content = false
    after_comma = false
    while true
        index = skip_protocol_whitespace(bytes, index)
        if index > length(bytes)
            return response_progress(kind, content)
        elseif bytes[index] == 0x7d
            if after_comma || skip_protocol_whitespace(bytes, index + 1) <= length(bytes)
                return nothing
            end
            return response_progress(kind, content)
        end
        key = protocol_string(bytes, index)
        if key.status == :invalid
            return nothing
        elseif key.status == :incomplete
            return response_progress(kind, content)
        end
        index = skip_protocol_whitespace(bytes, key.next)
        if index > length(bytes)
            return response_progress(kind, content)
        elseif bytes[index] != 0x3a
            return nothing
        end
        index = skip_protocol_whitespace(bytes, index + 1)
        value = protocol_string(bytes, index)
        if value.status == :invalid
            return nothing
        elseif key.text == "kind" && !seen_kind
            seen_kind = true
            if value.status == :complete
                kind = value.text == "answer" ? :answer : value.text == "code" ? :code : :unknown
            end
        elseif key.text == "content" && !seen_content
            seen_content = true
            content = value.text
        else
            return nothing
        end
        if value.status == :incomplete
            return response_progress(kind, content)
        end
        index = skip_protocol_whitespace(bytes, value.next)
        if index > length(bytes)
            return response_progress(kind, content)
        elseif bytes[index] == 0x2c
            index += 1
            after_comma = true
        elseif bytes[index] == 0x7d
            after_comma = false
        else
            return nothing
        end
    end
end

"""Publish an operation-scoped decoded preview while keeping wire fragments private to adapters."""
function emit_protocol_progress!(policy, text::AbstractString, context::ExecutionContext)
    if cancelled(context)
        return nothing
    end
    progress = protocol_progress(policy, text)
    if !isnothing(progress)
        emit!(context, HarnessEvent(:response_progress, (operation_id=operation_id(context), progress)))
    end
    return progress
end
