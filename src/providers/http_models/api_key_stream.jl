"""Own bounded HTTP framing without retaining request headers, keys, or rejected bodies."""
Base.@kwdef mutable struct APIKeyHeaderGate
    interrupt::Base.Event
    maximum_body::Int
    maximum_headers::Int=64*1024
    lock::ReentrantLock=ReentrantLock()
    status::Int=0
    header_bytes::Int=0
    body_bytes::Int=0
    received_bytes::Int=0
    content_length::Union{Nothing,Int}=nothing
    content_type::Union{Nothing,String}=nothing
    headers_complete::Bool=false
    failure::Symbol=:none
end
Base.show(io::IO,gate::APIKeyHeaderGate)=print(io,"APIKeyHeaderGate(status=",gate.status,", bytes=",gate.body_bytes,", failure=",gate.failure,")")
function api_key_gate_fail!(gate::APIKeyHeaderGate,reason::Symbol)
    gate.failure==:none && (gate.failure=reason)
    notify(gate.interrupt)
    nothing
end
function api_key_header_line!(gate::APIKeyHeaderGate,line::AbstractString)
    if startswith(line,"HTTP/")
        matched=match(r"^HTTP/(?:1\.[01]|2|3) ([1-5][0-9][0-9])(?: |\r?$)",line)
        if isnothing(matched) || gate.body_bytes>0
            api_key_gate_fail!(gate,:headers)
        else
            gate.status=parse(Int,something(matched.captures[1],"0"))
            gate.content_length=nothing
            gate.content_type=nothing
            gate.headers_complete=false
        end
    elseif isempty(strip(line))
        gate.headers_complete=gate.status>=200
    else
        pair=split(line,':';limit=2)
        if length(pair)==2
            name=lowercase(strip(first(pair)))
            value=strip(last(pair))
            if name=="content-type"
                mime=String(lowercase(strip(first(split(value,';';limit=2)))))
                if !isnothing(gate.content_type) && gate.content_type!=mime
                    api_key_gate_fail!(gate,:headers)
                else
                    gate.content_type=mime
                end
            elseif name=="content-length"
                length_value=tryparse(Int,value)
                if isnothing(length_value) || length_value<0 || !isnothing(gate.content_length) && gate.content_length!=length_value
                    api_key_gate_fail!(gate,:headers)
                else
                    gate.content_length=length_value
                    length_value>gate.maximum_body && api_key_gate_fail!(gate,:body_limit)
                end
            end
        end
    end
    nothing
end
"""Use Downloads' supported debug hook only to observe inbound framing; never print its data."""
function api_key_header_debug!(gate::APIKeyHeaderGate,kind::String,data::String)
    if kind=="DATA IN"
        lock(gate.lock) do
            if gate.failure==:none
                if sizeof(data)>max(0,gate.maximum_body-gate.received_bytes)
                    api_key_gate_fail!(gate,:body_limit)
                else
                    gate.received_bytes+=sizeof(data)
                end
            end
        end
    elseif kind=="HEADER IN"
        lock(gate.lock) do
            if gate.failure==:none
                if sizeof(data)>gate.maximum_headers-gate.header_bytes
                    api_key_gate_fail!(gate,:header_limit)
                else
                    gate.header_bytes+=sizeof(data)
                    for line in eachsplit(data,'\n';keepempty=false)
                        gate.failure==:none && api_key_header_line!(gate,line)
                    end
                    data=="\n" && api_key_header_line!(gate,"")
                end
            end
        end
    end
    nothing
end

"""Forward real chunks only after final successful SSE headers and before the bounded byte ceiling."""
struct APIKeyStreamSink{I,C} <: IO
    output::I
    gate::APIKeyHeaderGate
    context::C
end
Base.show(io::IO,sink::APIKeyStreamSink)=print(io,"APIKeyStreamSink([private stream], ",sink.gate,")")
Base.isopen(::APIKeyStreamSink)=true
Base.iswritable(::APIKeyStreamSink)=true
Base.flush(sink::APIKeyStreamSink)=flush(sink.output)
function Base.unsafe_write(sink::APIKeyStreamSink,pointer::Ptr{UInt8},count::UInt)
    gate=sink.gate
    accepted=lock(gate.lock) do
        if cancelled(sink.context)
            api_key_gate_fail!(gate,:cancelled)
            false
        elseif gate.failure!=:none
            false
        elseif count>UInt(max(0,gate.maximum_body-gate.body_bytes))
            api_key_gate_fail!(gate,:body_limit)
            false
        elseif !gate.headers_complete
            api_key_gate_fail!(gate,:headers)
            false
        elseif !(200<=gate.status<300)
            gate.body_bytes+=Int(count)
            false
        elseif gate.content_type!="text/event-stream"
            api_key_gate_fail!(gate,:content_type)
            false
        else
            gate.body_bytes+=Int(count)
            true
        end
    end
    accepted && unsafe_write(sink.output,pointer,count)
    Int(count)
end

api_key_gate_reason(::Val{:none})=""
api_key_gate_reason(::Val{:cancelled})="API key response cancelled; any partial output is incomplete."
api_key_gate_reason(::Val{:body_limit})="API key response exceeded its byte limit; any partial output is incomplete."
api_key_gate_reason(::Val{:header_limit})="API key response exceeded its header limit."
api_key_gate_reason(::Val{:content_type})="API key response was not an event stream."
api_key_gate_reason(::Val)="API key response framing was rejected; any partial output is incomplete."
function api_key_stream_response(response,gate::APIKeyHeaderGate)
    failure=lock(()->gate.failure,gate.lock)
    if failure!=:none
        (status=0,body="",reason=api_key_gate_reason(Val(failure)))
    else
        api_key_transport_response(response,nothing)
    end
end
