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
    line = String(@view decoder.line[:])
    empty!(decoder.line)
    if decoder.first_line
        startswith(line, "\ufeff") && (line = chop(line; head=1, tail=0))
        decoder.first_line = false
    end
    if isempty(line)
        if !isempty(decoder.data)
            data = length(decoder.data) == 1 ? only(decoder.data) : join(decoder.data, '\n')
            decoder.sink(SSEEvent(isempty(decoder.event) ? "message" : decoder.event, data, decoder.id))
        end
        empty!(decoder.data)
        decoder.event = ""
        return nothing
    end
    startswith(line, ':') && return nothing
    colon = findfirst(isequal(':'), line)
    field = isnothing(colon) ? line : SubString(line, firstindex(line), prevind(line, colon))
    value = isnothing(colon) ? "" : SubString(line, nextind(line, colon))
    startswith(value, ' ') && (value = SubString(value, nextind(value, firstindex(value))))
    if field == "data"
        push!(decoder.data, String(value))
    elseif field == "event"
        decoder.event = String(value)
    elseif field == "id" && !occursin('\0', value)
        decoder.id = String(value)
    end
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
