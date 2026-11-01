struct AnthropicMessagesProtocol end
model_endpoint(::AnthropicMessagesProtocol, endpoint, model) = endpoint * "/v1/messages?beta=true"
model_protocol_headers(::AnthropicMessagesProtocol) = ["anthropic-version" => "2023-06-01"]

function anthropic_wire_message(message::Message)
    role = message.role == :assistant ? "assistant" : "user"
    content = wire_content(message)
    return Dict{String,Any}("role" => role,
        "content" => role == "assistant" ? [Dict("type" => "text", "text" => content)] : content)
end
anthropic_wire_message(message::AbstractDict) = deepcopy(message)

function model_payload(::AnthropicMessagesProtocol, model::ModelSpec, request::ModelRequest, options)
    messages = [anthropic_wire_message(message) for message in request.messages
        if !(message isa Message) || !isempty(strip(wire_content(message)))]
    payload = Dict{String,Any}("model" => model.id, "messages" => messages,
        "max_tokens" => get(options, "maxTokens", get(model_metadata(model), "maxTokens", 4096)), "stream" => true)
    if !isempty(request.instructions)
        payload["system"] = [Dict("type" => "text", "text" => request.instructions)]
    end
    for (option, wire) in (("temperature", "temperature"), ("tools", "tools"),
            ("toolChoice", "tool_choice"), ("thinking", "thinking"))
        haskey(options, option) && (payload[wire] = deepcopy(options[option]))
    end
    return payload
end

function anthropic_model_usage!(state::ModelStreamState, raw::AbstractDict; initial=false)
    usage = state.message["usage"]
    for (source, target) in (("input_tokens", "input"), ("output_tokens", "output"),
            ("cache_read_input_tokens", "cacheRead"), ("cache_creation_input_tokens", "cacheWrite"))
        value = get(raw, source, nothing)
        if !isnothing(value)
            usage[target] = value
        elseif initial
            usage[target] = 0
        end
    end
    cache = get(raw, "cache_creation", nothing)
    written = cache isa AbstractDict ? get(cache, "ephemeral_1h_input_tokens", nothing) : nothing
    if !isnothing(written) || initial
        usage["cacheWrite1h"] = isnothing(written) ? 0 : written
    end
    details = get(raw, "output_tokens_details", nothing)
    if details isa AbstractDict && !isnothing(get(details, "thinking_tokens", nothing))
        usage["reasoning"] = details["thinking_tokens"]
    end
    usage["totalTokens"] = usage["input"] + usage["output"] + usage["cacheRead"] + usage["cacheWrite"]
    model_cost!(state)
    return nothing
end

function anthropic_block_start!(state::ModelStreamState, event::AbstractDict)
    source = event["content_block"]
    kind = source["type"]
    block = if kind == "text"
        Dict{String,Any}("type" => "text", "text" => get(source, "text", ""))
    elseif kind == "thinking"
        Dict{String,Any}("type" => "thinking", "thinking" => get(source, "thinking", ""),
            "thinkingSignature" => get(source, "signature", ""))
    elseif kind == "redacted_thinking"
        Dict{String,Any}("type" => "thinking", "thinking" => "[Reasoning redacted]",
            "thinkingSignature" => source["data"], "redacted" => true)
    elseif kind == "tool_use"
        Dict{String,Any}("type" => "toolCall", "id" => source["id"], "name" => source["name"],
            "arguments" => get(source, "input", Dict{String,Any}()))
    else
        return nothing
    end
    push!(state.message["content"], block)
    index = length(state.message["content"])
    state.blocks[event["index"]] = index
    if block["type"] == "toolCall"
        state.arguments[index] = ""
        model_event!(state, "toolcall_start"; contentIndex=index - 1)
    else
        model_event!(state, block["type"] * "_start"; contentIndex=index - 1)
    end
    return nothing
end

function anthropic_block_delta!(state::ModelStreamState, event::AbstractDict)
    index = get(state.blocks, event["index"], 0)
    index == 0 && return nothing
    block = state.message["content"][index]
    delta = event["delta"]
    kind = delta["type"]
    if kind == "text_delta" || kind == "thinking_delta"
        field = kind == "text_delta" ? "text" : "thinking"
        block[field] *= delta[field]
        model_event!(state, kind; contentIndex=index - 1, delta=delta[field])
    elseif kind == "signature_delta"
        block["thinkingSignature"] = get(block, "thinkingSignature", "") * delta["signature"]
    elseif kind == "input_json_delta"
        state.arguments[index] *= delta["partial_json"]
        arguments = parse_json(state.arguments[index])
        arguments isa AbstractDict && (block["arguments"] = arguments)
        model_event!(state, "toolcall_delta"; contentIndex=index - 1, delta=delta["partial_json"])
    end
    return nothing
end

function anthropic_stop_reason!(state::ModelStreamState, delta::AbstractDict)
    reason = get(delta, "stop_reason", nothing)
    isnothing(reason) && return nothing
    state.message["rawStopReason"] = reason
    state.message["stopReason"] = get(Dict("end_turn" => "stop", "max_tokens" => "length",
        "tool_use" => "toolUse", "pause_turn" => "stop", "stop_sequence" => "stop"), reason, "error")
    if reason == "refusal"
        details = get(delta, "stop_details", nothing)
        explanation = details isa AbstractDict ? get(details, "explanation", "") : ""
        state.error = isempty(explanation) ? "The model refused to complete the request" : explanation
    elseif reason == "sensitive"
        state.error = "Provider stopped with: sensitive"
    elseif state.message["stopReason"] == "error"
        state.error = "Unhandled stop reason: $reason"
    end
    return nothing
end

function consume_model_event!(::AnthropicMessagesProtocol, state::ModelStreamState, event::SSEEvent)
    start_model_stream!(state)
    if event.event == "error"
        state.error = event.data
        return nothing
    end
    parsed = parse_json(event.data)
    parsed isa AbstractDict || return nothing
    kind = get(parsed, "type", "")
    if kind == "message_start"
        state.received_start = true
        message = parsed["message"]
        state.message["responseId"] = message["id"]
        if get(message, "model", state.model.id) != state.model.id
            state.message["responseModel"] = message["model"]
        end
        anthropic_model_usage!(state, get(message, "usage", Dict{String,Any}()); initial=true)
    elseif kind == "content_block_start"
        anthropic_block_start!(state, parsed)
    elseif kind == "content_block_delta"
        anthropic_block_delta!(state, parsed)
    elseif kind == "content_block_stop"
        index = pop!(state.blocks, parsed["index"], 0)
        index == 0 || finish_model_block!(state, index)
    elseif kind == "message_delta"
        anthropic_stop_reason!(state, parsed["delta"])
        usage = get(parsed, "usage", nothing)
        usage isa AbstractDict && anthropic_model_usage!(state, usage)
    elseif kind == "message_stop"
        state.received_stop = true
    end
    return nothing
end

function finish_protocol_stream!(::AnthropicMessagesProtocol, state::ModelStreamState)
    if isempty(state.error)
        if state.received_start && !state.received_stop
            state.error = "Anthropic stream ended before message_stop"
        elseif state.message["stopReason"] == "pending"
            state.error = "Anthropic stream ended without a stop reason"
        end
    end
    return nothing
end
