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
    line = String(copy(decoder.line))
    empty!(decoder.line)
    if decoder.first_line
        startswith(line, "\ufeff") && (line = chop(line; head=1, tail=0))
        decoder.first_line = false
    end
    if isempty(line)
        if !isempty(decoder.data)
            decoder.sink(SSEEvent(isempty(decoder.event) ? "message" : decoder.event, join(decoder.data, '\n'), decoder.id))
        end
        empty!(decoder.data)
        decoder.event = ""
        return nothing
    end
    startswith(line, ':') && return nothing
    colon = findfirst(isequal(':'), line)
    field = isnothing(colon) ? line :
        colon == firstindex(line) ? "" : SubString(line, firstindex(line), prevind(line, colon))
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

function Base.write(decoder::SSEDecoder, byte::UInt8)
    if decoder.after_cr
        decoder.after_cr = false
        byte == 0x0a && return 1
    end
    if byte == 0x0d || byte == 0x0a
        sse_line!(decoder)
        decoder.after_cr = byte == 0x0d
    else
        push!(decoder.line, byte)
    end
    return 1
end

function Base.unsafe_write(decoder::SSEDecoder, source::Ptr{UInt8}, count::UInt)
    for index in 1:Int(count)
        write(decoder, unsafe_load(source, index))
    end
    return Int(count)
end

end

using .EventStreams: SSEEvent, SSEDecoder
