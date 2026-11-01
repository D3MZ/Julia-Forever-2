module EventStreams



struct SSEEvent
    event::String
    data::String
    id::String
end

mutable struct SSEDecoder{F} <: IO
    sink::F
    line::Vector{UInt8}
    data::Vector{String}
    event::String
    id::String
    after_cr::Bool
    first_line::Bool
end
SSEDecoder(sink) = SSEDecoder(sink, UInt8[], String[], "", "", false, true)
Base.isopen(::SSEDecoder) = true
Base.iswritable(::SSEDecoder) = true
Base.flush(::SSEDecoder) = nothing
Base.close(::SSEDecoder) = nothing

function sse_line!(decoder::SSEDecoder)
    bytes = decoder.line
    start = 1
    if decoder.first_line
        if length(bytes) >= 3 && bytes[1] == 0xef && bytes[2] == 0xbb && bytes[3] == 0xbf
            start = 4
        end
        decoder.first_line = false
    end
    if start > length(bytes)
        if !isempty(decoder.data)
            data = length(decoder.data) == 1 ? only(decoder.data) : join(decoder.data, '\n')
            decoder.sink(SSEEvent(isempty(decoder.event) ? "message" : decoder.event, data, decoder.id))
        end
        empty!(decoder.data)
        decoder.event = ""
        empty!(bytes)
        return nothing
    end
    if bytes[start] == 0x3a
        empty!(bytes)
        return nothing
    end
    colon = findnext(==(0x3a), bytes, start)
    field_end = isnothing(colon) ? length(bytes) : colon - 1
    value_start = isnothing(colon) ? length(bytes) + 1 : colon + 1
    if value_start <= length(bytes) && bytes[value_start] == 0x20
        value_start += 1
    end
    field_length = field_end - start + 1
    if field_length == 4 && bytes[start] == 0x64 && bytes[start + 1] == 0x61 &&
            bytes[start + 2] == 0x74 && bytes[start + 3] == 0x61
        push!(decoder.data, value_start > length(bytes) ? "" : String(@view bytes[value_start:end]))
    elseif field_length == 5 && bytes[start] == 0x65 && bytes[start + 1] == 0x76 &&
            bytes[start + 2] == 0x65 && bytes[start + 3] == 0x6e && bytes[start + 4] == 0x74
        decoder.event = value_start > length(bytes) ? "" : String(@view bytes[value_start:end])
    elseif field_length == 2 && bytes[start] == 0x69 && bytes[start + 1] == 0x64 &&
            isnothing(findnext(==(0x00), bytes, value_start))
        decoder.id = value_start > length(bytes) ? "" : String(@view bytes[value_start:end])
    end
    empty!(bytes)
    return nothing
end

sse_linebreak(byte::UInt8) = byte in (0x0a, 0x0d)

function Base.write(decoder::SSEDecoder, byte::UInt8)
    if decoder.after_cr
        decoder.after_cr = false
        byte == 0x0a && return 1
    end
    if sse_linebreak(byte)
        sse_line!(decoder)
        decoder.after_cr = byte == 0x0d
    else
        push!(decoder.line, byte)
    end
    return 1
end

function Base.unsafe_write(decoder::SSEDecoder, source::Ptr{UInt8}, count::UInt)
    count == 0 && return 0
    count == 1 && return write(decoder, unsafe_load(source))
    bytes = unsafe_wrap(Vector{UInt8}, source, Int(count); own=false)
    index = firstindex(bytes)
    if decoder.after_cr
        decoder.after_cr = false
        bytes[index] == 0x0a && (index += 1)
    end
    while index <= length(bytes)
        ending = findnext(sse_linebreak, bytes, index)
        if isnothing(ending)
            append!(decoder.line, @view bytes[index:end])
            break
        end
        append!(decoder.line, @view bytes[index:(ending - 1)])
        sse_line!(decoder)
        decoder.after_cr = bytes[ending] == 0x0d
        index = ending + 1
        if decoder.after_cr && index <= length(bytes)
            decoder.after_cr = false
            bytes[index] == 0x0a && (index += 1)
        end
    end
    return Int(count)
end

end

using .EventStreams: SSEEvent, SSEDecoder
