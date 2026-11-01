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

struct SSEField{B}
    bytes::B
    start::Int
    length::Int
    value::Int
end

function SSEField(bytes::AbstractVector{UInt8}, start::Int)
    colon = findnext(==(0x3a), bytes, start)
    stop = isnothing(colon) ? length(bytes) : colon - 1
    value = isnothing(colon) ? length(bytes) + 1 : colon + 1
    if value <= length(bytes) && bytes[value] == 0x20
        value += 1
    end
    SSEField(bytes, start, stop - start + 1, value)
end

text(field::SSEField) = field.value > length(field.bytes) ? "" : String(@view field.bytes[field.value:end])
SSEEvent(decoder::SSEDecoder) = SSEEvent(isempty(decoder.event) ? "message" : decoder.event, length(decoder.data) == 1 ? only(decoder.data) : join(decoder.data, '\n'), decoder.id)

function sse_line!(decoder::SSEDecoder)
    bytes = decoder.line
    start = decoder.first_line && length(bytes) >= 3 && bytes[1] == 0xef && bytes[2] == 0xbb && bytes[3] == 0xbf ? 4 : 1
    decoder.first_line = false
    if start > length(bytes)
        emit!(decoder)
    elseif bytes[start] != 0x3a
        consume!(decoder, SSEField(bytes, start))
    end
    empty!(bytes)
    nothing
end

function emit!(decoder::SSEDecoder)
    if !isempty(decoder.data)
        decoder.sink(SSEEvent(decoder))
    end
    empty!(decoder.data)
    decoder.event = ""
    nothing
end

function consume!(decoder::SSEDecoder, field::SSEField)
    bytes, start = field.bytes, field.start
    if field.length == 4 && bytes[start] == 0x64 && bytes[start + 1] == 0x61 && bytes[start + 2] == 0x74 && bytes[start + 3] == 0x61
        push!(decoder.data, text(field))
    elseif field.length == 5 && bytes[start] == 0x65 && bytes[start + 1] == 0x76 && bytes[start + 2] == 0x65 && bytes[start + 3] == 0x6e && bytes[start + 4] == 0x74
        decoder.event = text(field)
    elseif field.length == 2 && bytes[start] == 0x69 && bytes[start + 1] == 0x64 && isnothing(findnext(==(0x00), bytes, field.value))
        decoder.id = text(field)
    end
    nothing
end
sse_linebreak(byte::UInt8) = byte in (0x0a, 0x0d)

function Base.write(decoder::SSEDecoder, byte::UInt8)
    skip = decoder.after_cr && byte == 0x0a
    decoder.after_cr = false
    if !skip
        if sse_linebreak(byte)
            sse_line!(decoder)
            decoder.after_cr = byte == 0x0d
        else
            push!(decoder.line, byte)
        end
    end
    1
end
function Base.unsafe_write(decoder::SSEDecoder, source::Ptr{UInt8}, count::UInt)
    if count == 0
        0
    elseif count == 1
        write(decoder, unsafe_load(source))
    else
        consume!(decoder, unsafe_wrap(Vector{UInt8}, source, Int(count); own=false))
        Int(count)
    end
end

function consume!(decoder::SSEDecoder, bytes::AbstractVector{UInt8})
    index = firstindex(bytes)
    if decoder.after_cr
        decoder.after_cr = false
        index += bytes[index] == 0x0a
    end
    while index <= length(bytes)
        ending = findnext(sse_linebreak, bytes, index)
        index = consume!(decoder, bytes, index, ending)
    end
    decoder
end

function consume!(decoder::SSEDecoder, bytes, index, ::Nothing)
    append!(decoder.line, @view bytes[index:end])
    length(bytes) + 1
end

function consume!(decoder::SSEDecoder, bytes, index, ending::Int)
    append!(decoder.line, @view bytes[index:(ending - 1)])
    sse_line!(decoder)
    decoder.after_cr = bytes[ending] == 0x0d
    next = ending + 1
    if decoder.after_cr && next <= length(bytes)
        decoder.after_cr = false
        next += bytes[next] == 0x0a
    end
    next
end
end

using .EventStreams: SSEEvent, SSEDecoder
