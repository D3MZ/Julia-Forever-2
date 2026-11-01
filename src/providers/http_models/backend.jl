struct HTTPModelBackend{P,C,T,O}
    protocol::P
    endpoint::String
    credentials::C
    transport::T
    options::O
end

"""Compose a wire protocol with independent endpoint, credential resolver, transport, and request options."""
HTTPModelBackend(protocol, endpoint::AbstractString; credentials=Returns(Pair{String,String}[]), transport=model_http_transport, options=Dict{String,Any}()) = HTTPModelBackend(protocol, String(rstrip(endpoint, '/')), credentials, transport, options)
Base.show(io::IO, backend::HTTPModelBackend) = print(io, "HTTPModelBackend(", nameof(typeof(backend.protocol)), ")")

"""Send an owned streaming request; custom transports implement this same context-aware signature."""
model_http_transport(url, method, body, headers, context, sink) = HTTPTransport.http_request(url, method, body, headers, context; sink)

struct StreamedCompletion{R,U,M}
    reply::R
    usage::U
    message::M
end
response_reply(result::StreamedCompletion) = result.reply
response_usage(result::StreamedCompletion) = result.usage

model_metadata(model::ModelSpec) = model_metadata_value(model.metadata)
model_metadata_value(metadata::AbstractDict) = metadata
model_metadata_value(metadata) = Dict{String,Any}()
model_option(options, name, fallback=nothing) = get(options, name, fallback)
model_request_options(options::AbstractDict, model, request) = options
model_request_options(options, model, request) = Base.invokelatest(options, model, request)

function empty_model_message(model::ModelSpec)
    cost = Dict{String,Any}(name => 0 for name in ("input", "output", "cacheRead", "cacheWrite", "total"))
    usage = Dict{String,Any}(name => 0 for name in ("input", "output", "cacheRead", "cacheWrite", "totalTokens"))
    usage["cost"] = cost
    return Dict{String,Any}("role" => "assistant", "content" => Any[], "api" => model.api,
        "provider" => string(model.provider), "model" => model.id, "usage" => usage,
        "stopReason" => "pending", "timestamp" => round(Int, time() * 1000))
end

Base.@kwdef mutable struct ModelStreamState{M,C}
    model::M
    context::C
    message::Dict{String,Any}
    blocks::Dict{Any,Int} = Dict{Any,Int}()
    arguments::Dict{Int,String} = Dict{Int,String}()
    text_buffers::Dict{Int,IOBuffer} = Dict{Int,IOBuffer}()
    closed_blocks::Set{Int} = Set{Int}()
    received_start::Bool = false
    received_stop::Bool = false
    started::Bool = false
    finished::Bool = false
    error::String = ""
    started_at::UInt64 = time_ns()
end
ModelStreamState(model, context) = ModelStreamState(; model, context, message=empty_model_message(model))

function model_event!(state::ModelStreamState, kind::AbstractString; fields...)
    event = Dict{String,Any}("type" => String(kind))
    for (name, value) in fields
        event[string(name)] = value
    end
    emit!(state.context, HarnessEvent(:model_stream, event))
    return nothing
end

function start_model_stream!(state::ModelStreamState)
    if !state.started
        state.started = true
        model_event!(state, "start")
    end
    nothing
end
function model_cost!(state::ModelStreamState)
    usage = state.message["usage"]
    rates = get(model_metadata(state.model), "cost", Dict{String,Any}())
    cost = usage["cost"]
    for name in ("input", "output", "cacheRead")
        cost[name] = (get(rates, name, 0) / 1_000_000) * usage[name]
    end
    cache_write_1h = min(get(usage, "cacheWrite1h", 0), usage["cacheWrite"])
    cache_write_5m = usage["cacheWrite"] - cache_write_1h
    cache_write_rate = get(rates, "cacheWrite", 0)
    cost["cacheWrite"] = (cache_write_rate / 1_000_000) * cache_write_5m +
        (get(rates, "cacheWrite1h", cache_write_rate) / 1_000_000) * cache_write_1h
    cost["total"] = cost["input"] + cost["output"] + cost["cacheRead"] + cost["cacheWrite"]
    cost["totalFromProvider"] = false
    return nothing
end

function text_model_block!(state::ModelStreamState, kind::String, delta::AbstractString; signature=nothing)
    if !isempty(delta)
        appendtext!(state, kind, delta, signature)
    end
    nothing
end

function appendtext!(state::ModelStreamState, kind::String, delta::AbstractString, signature)
    index = get(state.blocks, kind, 0)
    if index == 0
        block = Dict{String,Any}("type" => kind, kind => "")
        isnothing(signature) || (block["thinkingSignature"] = signature)
        push!(state.message["content"], block)
        index = length(state.message["content"])
        state.blocks[kind] = index
        state.text_buffers[index] = IOBuffer()
        model_event!(state, kind * "_start"; contentIndex=index - 1)
    end
    write(state.text_buffers[index], delta)
    model_event!(state, kind * "_delta"; contentIndex=index - 1, delta=String(delta))
    return nothing
end

model_json_hex_byte(value::UInt8) = 0x30 <= value <= 0x39 || 0x41 <= value <= 0x46 || 0x61 <= value <= 0x66

"""Repair control characters and invalid escapes inside model-generated JSON strings only."""
function repair_model_json(text::AbstractString)
    bytes = codeunits(text)
    output = IOBuffer(sizehint=ncodeunits(text))
    in_string = false
    index = 1
    while index <= length(bytes)
        byte = bytes[index]
        if !in_string
            write(output, byte)
            in_string = byte == 0x22
        elseif byte == 0x22
            write(output, byte)
            in_string = false
        elseif byte == 0x5c
            if index < length(bytes) && bytes[index + 1] in (0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74)
                write(output, byte, bytes[index + 1])
                index += 1
            elseif index + 5 <= length(bytes) && bytes[index + 1] == 0x75 &&
                    all(offset -> model_json_hex_byte(bytes[offset]), index + 2:index + 5)
                write(output, bytes[index:index + 5])
                index += 5
            else
                write(output, 0x5c, 0x5c)
            end
        elseif byte <= 0x1f
            write(output, "\\u", string(byte; base=16, pad=4))
        else
            write(output, byte)
        end
        index += 1
    end
    return String(take!(output))
end

"""Check whether a streamed JSON argument prefix can be a complete object."""
function possible_tool_object(text::String)
    index = lastindex(text)
    while index > 0 && isspace(text[index])
        index = prevind(text, index)
    end
    index > 0 && text[index] == '}'
end
function parse_model_tool_arguments(text::AbstractString)
    parsed = parse_json(text)
    return isnothing(parsed) ? parse_json(repair_model_json(text)) : parsed
end

function finish_model_block!(state::ModelStreamState, index::Int)
    if !(index in state.closed_blocks)
        complete!(state, index)
    end
    nothing
end

function complete!(state::ModelStreamState, index::Int)
    push!(state.closed_blocks, index)
    block = state.message["content"][index]
    kind = block["type"]
    if kind == "toolCall"
        if haskey(state.arguments, index) && !isempty(state.arguments[index])
            arguments = parse_model_tool_arguments(state.arguments[index])
            arguments isa AbstractDict && (block["arguments"] = arguments)
        end
        model_event!(state, "toolcall_end"; contentIndex=index - 1, toolCall=deepcopy(block))
    else
        if haskey(state.text_buffers, index)
            block[kind] = String(take!(pop!(state.text_buffers, index)))
        end
        model_event!(state, string(kind, "_end"); contentIndex=index - 1, content=block[kind])
    end
    return nothing
end

function finish_model_blocks!(state::ModelStreamState)
    for index in eachindex(state.message["content"])
        finish_model_block!(state, index)
    end
    return nothing
end

finish_protocol_stream!(protocol, state::ModelStreamState) = finish_model_blocks!(state)

function finish_model_stream!(state::ModelStreamState)
    if !state.finished
        complete!(state)
    end
    nothing
end

function complete!(state::ModelStreamState)
    for (index, buffer) in state.text_buffers
        block = state.message["content"][index]
        block[block["type"]] = String(take!(buffer))
    end
    empty!(state.text_buffers)
    state.finished = true
    state.message["durationMs"] = Int((time_ns() - state.started_at) ÷ 1_000_000)
    if cancelled(state.context)
        state.message["stopReason"] = "aborted"
        state.error = "Request was aborted"
    elseif state.message["stopReason"] == "pending" && isempty(state.error)
        state.message["stopReason"] = "error"
        state.error = "Stream ended without finish_reason"
    end
    if !isempty(state.error)
        state.message["stopReason"] == "aborted" || (state.message["stopReason"] = "error")
        state.message["errorMessage"] = state.error
        model_event!(state, "error"; reason=state.message["stopReason"])
    else
        model_event!(state, "done"; reason=state.message["stopReason"])
    end
    return nothing
end

function StreamedCompletion(state::ModelStreamState, request::ModelRequest)
    message = state.message
    usage = message["usage"]
    report = UsageReport(usage["input"], usage["output"],
        haskey(model_metadata(state.model), "cost") ? Float64(usage["cost"]["total"]) : nothing,
        usage["cacheRead"], usage["cacheWrite"])
    text = join(block["text"] for block in message["content"] if block["type"] == "text")
    reply = if message["stopReason"] in ("error", "aborted")
        Reply(:error, get(message, "errorMessage", "Model request failed."))
    elseif any(block -> block["type"] == "toolCall", message["content"])
        Reply(:error, "Model returned tool calls; a tool-aware loop must consume StreamedCompletion.message.")
    elseif isnothing(request.protocol)
        Reply(:answer, text)
    else
        decode_reply(request.protocol, text)
    end
    return StreamedCompletion(reply, report, message)
end

function respond_model(backend::HTTPModelBackend, model::ModelSpec, request::ModelRequest, context::ExecutionContext)
    state = ModelStreamState(model, context)
    if !cancelled(context)
        exchange!(backend, state, request)
    end
    finish_model_stream!(state)
    StreamedCompletion(state, request)
end

function exchange!(backend::HTTPModelBackend, state::ModelStreamState, request::ModelRequest)
    model, context = state.model, state.context
    options = model_request_options(backend.options, model, request)
    headers = Pair{String,String}["Content-Type" => "application/json"]
    append!(headers, model_protocol_headers(backend.protocol))
    append!(headers, Base.invokelatest(backend.credentials, model, context))
    payload = model_payload(backend.protocol, model, request, options)
    decoder = SSEDecoder() do event
        if !cancelled(context)
            consume_model_event!(backend.protocol, state, event)
        end
    end
    response = Base.invokelatest(backend.transport, model_endpoint(backend.protocol, backend.endpoint, model), "POST", JSON.json(payload), headers, context, decoder)
    if response.status in 200:299
        start_model_stream!(state)
        finish_protocol_stream!(backend.protocol, state)
    else
        state.error = "Model HTTP request failed ($(response.status)): $(response.reason)"
    end
    state
end
model_protocol_headers(protocol) = Pair{String,String}[]

completion_result(state::ModelStreamState, request::ModelRequest) = StreamedCompletion(state, request)
