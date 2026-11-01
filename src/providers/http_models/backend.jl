struct HTTPModelBackend{P,C,T,O}
    protocol::P
    endpoint::String
    credentials::C
    transport::T
    options::O
end

"""Compose a wire protocol with independent endpoint, credential resolver, transport, and request options."""
HTTPModelBackend(protocol, endpoint::AbstractString; credentials=Returns(Pair{String,String}[]),
        transport=model_http_transport, options=Dict{String,Any}()) =
    HTTPModelBackend(protocol, String(rstrip(endpoint, '/')), credentials, transport, options)
Base.show(io::IO, backend::HTTPModelBackend) = print(io, "HTTPModelBackend(", nameof(typeof(backend.protocol)), ")")

"""Send an owned streaming request; custom transports implement this same context-aware signature."""
model_http_transport(url, method, body, headers, context, sink) =
    HTTPTransport.http_request(url, method, body, headers, context; sink)

struct StreamedCompletion{R,U,M}
    reply::R
    usage::U
    message::M
end
response_reply(result::StreamedCompletion) = result.reply
response_usage(result::StreamedCompletion) = result.usage

model_metadata(model::ModelSpec) = model.metadata isa AbstractDict ? model.metadata : Dict{String,Any}()
model_option(options, name, fallback=nothing) = get(options, name, fallback)

function empty_model_message(model::ModelSpec)
    cost = Dict{String,Any}(name => 0 for name in ("input", "output", "cacheRead", "cacheWrite", "total"))
    usage = Dict{String,Any}(name => 0 for name in ("input", "output", "cacheRead", "cacheWrite", "totalTokens"))
    usage["cost"] = cost
    return Dict{String,Any}("role" => "assistant", "content" => Any[], "api" => model.api,
        "provider" => string(model.provider), "model" => model.id, "usage" => usage,
        "stopReason" => "pending", "timestamp" => round(Int, time() * 1000))
end

mutable struct ModelStreamState{M,C}
    model::M
    context::C
    message::Dict{String,Any}
    blocks::Dict{Any,Int}
    arguments::Dict{Int,String}
    closed_blocks::Set{Int}
    received_start::Bool
    received_stop::Bool
    started::Bool
    finished::Bool
    error::String
    started_at::UInt64
end
ModelStreamState(model, context) = ModelStreamState(model, context, empty_model_message(model),
    Dict{Any,Int}(), Dict{Int,String}(), Set{Int}(), false, false, false, false, "", time_ns())

function model_event!(state::ModelStreamState, kind::AbstractString; fields...)
    event = Dict{String,Any}("type" => String(kind))
    for (name, value) in fields
        event[string(name)] = value
    end
    emit!(state.context, HarnessEvent(:model_stream, event))
    return nothing
end

function start_model_stream!(state::ModelStreamState)
    state.started && return nothing
    state.started = true
    model_event!(state, "start")
    return nothing
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
    isempty(delta) && return nothing
    index = get(state.blocks, kind, 0)
    if index == 0
        block = Dict{String,Any}("type" => kind, kind => "")
        isnothing(signature) || (block["thinkingSignature"] = signature)
        push!(state.message["content"], block)
        index = length(state.message["content"])
        state.blocks[kind] = index
        model_event!(state, kind * "_start"; contentIndex=index - 1)
    end
    block = state.message["content"][index]
    block[kind] *= delta
    model_event!(state, kind * "_delta"; contentIndex=index - 1, delta=String(delta))
    return nothing
end

function finish_model_block!(state::ModelStreamState, index::Int)
    index in state.closed_blocks && return nothing
    push!(state.closed_blocks, index)
    block = state.message["content"][index]
    kind = block["type"]
    if kind == "toolCall"
        if haskey(state.arguments, index) && !isempty(state.arguments[index])
            arguments = parse_json(state.arguments[index])
            arguments isa AbstractDict && (block["arguments"] = arguments)
        end
        model_event!(state, "toolcall_end"; contentIndex=index - 1, toolCall=deepcopy(block))
    else
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
    state.finished && return nothing
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

function completion_result(state::ModelStreamState, request::ModelRequest)
    message = state.message
    usage = message["usage"]
    report = UsageReport(usage["input"] + usage["cacheRead"] + usage["cacheWrite"],
        usage["output"], haskey(model_metadata(state.model), "cost") ? Float64(usage["cost"]["total"]) : nothing)
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
    if cancelled(context)
        finish_model_stream!(state)
        return completion_result(state, request)
    end
    options = backend.options isa AbstractDict ? backend.options : Base.invokelatest(backend.options, model, request)
    headers = Pair{String,String}["Content-Type" => "application/json"]
    append!(headers, model_protocol_headers(backend.protocol))
    append!(headers, Base.invokelatest(backend.credentials, model, context))
    payload = model_payload(backend.protocol, model, request, options)
    decoder = SSEDecoder() do event
        cancelled(context) || consume_model_event!(backend.protocol, state, event)
    end
    response = Base.invokelatest(backend.transport, model_endpoint(backend.protocol, backend.endpoint, model),
        "POST", JSON.json(payload), headers, context, decoder)
    if response.status in 200:299
        start_model_stream!(state)
        finish_protocol_stream!(backend.protocol, state)
    else
        state.error = "Model HTTP request failed ($(response.status)): $(response.reason)"
    end
    finish_model_stream!(state)
    return completion_result(state, request)
end

model_protocol_headers(protocol) = Pair{String,String}[]
