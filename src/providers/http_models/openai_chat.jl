struct OpenAIChatProtocol{C}
    compatibility::C
end
"""Configure OpenAI Chat Completions without assigning provider-specific policy to the core."""
OpenAIChatProtocol(; compatibility=Dict{String,Any}()) = OpenAIChatProtocol(compatibility)
model_endpoint(::OpenAIChatProtocol, endpoint, model) = endpoint * "/chat/completions"

function openai_wire_message(message::Message)
    return Dict{String,Any}("role" => (message.role == :code_result ? "user" : string(message.role)),
        "content" => wire_content(message))
end
openai_wire_message(message::AbstractDict) = deepcopy(message)

function model_payload(protocol::OpenAIChatProtocol, model::ModelSpec, request::ModelRequest, options)
    compatibility = protocol.compatibility
    messages = Any[]
    if !isempty(request.instructions)
        reasoning = get(model_metadata(model), "reasoning", false)
        role = reasoning && get(compatibility, "supportsDeveloperRole", true) ? "developer" : "system"
        push!(messages, Dict("role" => role, "content" => request.instructions))
    end
    append!(messages, openai_wire_message.(request.messages))
    payload = Dict{String,Any}("model" => model.id, "messages" => messages, "stream" => true)
    get(compatibility, "supportsUsageInStreaming", true) && (payload["stream_options"] = Dict("include_usage" => true))
    get(compatibility, "supportsStore", true) && (payload["store"] = false)
    if haskey(options, "maxTokens") && options["maxTokens"] != 0
        payload[get(compatibility, "maxTokensField", "max_completion_tokens")] = options["maxTokens"]
    end
    for (option, wire) in (("temperature", "temperature"), ("toolChoice", "tool_choice"),
            ("tools", "tools"), ("reasoningEffort", "reasoning_effort"))
        haskey(options, option) && (payload[wire] = deepcopy(options[option]))
    end
    isnothing(request.response_format) || (payload["response_format"] = request.response_format)
    merge!(payload, get(options, "samplingParams", Dict{String,Any}()))
    return payload
end

function openai_model_usage!(state::ModelStreamState, raw::AbstractDict)
    details = get(raw, "prompt_tokens_details", Dict{String,Any}())
    cached = get(details, "cached_tokens", get(raw, "prompt_cache_hit_tokens", get(raw, "cached_tokens", 0)))
    written = get(details, "cache_write_tokens", 0)
    usage = state.message["usage"]
    usage["input"] = max(0, get(raw, "prompt_tokens", 0) - cached - written)
    usage["output"] = get(raw, "completion_tokens", 0)
    usage["cacheRead"] = cached
    usage["cacheWrite"] = written
    usage["reasoning"] = get(get(raw, "completion_tokens_details", Dict{String,Any}()), "reasoning_tokens", 0)
    usage["totalTokens"] = usage["input"] + usage["output"] + cached + written
    model_cost!(state)
    return nothing
end
openai_model_usage!(state, raw) = nothing

function openai_tool_delta!(state::ModelStreamState, tool::AbstractDict)
    key = get(tool, "index", get(tool, "id", ""))
    index = get(state.blocks, key, 0)
    function_data = get(tool, "function", Dict{String,Any}())
    if index == 0
        block = Dict{String,Any}("type" => "toolCall", "id" => get(tool, "id", ""),
            "name" => get(function_data, "name", ""), "arguments" => Dict{String,Any}())
        push!(state.message["content"], block)
        index = length(state.message["content"])
        state.blocks[key] = index
        state.arguments[index] = ""
        model_event!(state, "toolcall_start"; contentIndex=index - 1)
    end
    block = state.message["content"][index]
    isempty(block["id"]) && (block["id"] = get(tool, "id", ""))
    isempty(block["name"]) && (block["name"] = get(function_data, "name", ""))
    delta = get(function_data, "arguments", "")
    state.arguments[index] *= delta
    if possible_tool_object(state.arguments[index])
        arguments = parse_json(state.arguments[index])
        arguments isa AbstractDict && (block["arguments"] = arguments)
    end
    model_event!(state, "toolcall_delta"; contentIndex=index - 1, delta)
    return nothing
end

function consume_model_event!(protocol::OpenAIChatProtocol, state::ModelStreamState, event::SSEEvent)
    if event.data != "[DONE]"
        consume!(protocol, state, parse_json(event.data))
    end
    nothing
end

consume!(::OpenAIChatProtocol, state::ModelStreamState, chunk) = (state.error = "Invalid JSON in model event stream"; nothing)

function consume!(protocol::OpenAIChatProtocol, state::ModelStreamState, chunk::AbstractDict)
    start_model_stream!(state)
    if haskey(chunk, "id") && !haskey(state.message, "responseId")
        state.message["responseId"] = chunk["id"]
    end
    if haskey(chunk, "model") && chunk["model"] != state.model.id && !isempty(chunk["model"])
        get!(state.message, "responseModel", chunk["model"])
    end
    if haskey(chunk, "usage")
        openai_model_usage!(state, chunk["usage"])
    end
    choices = get(chunk, "choices", Any[])
    if !isempty(choices)
        consume!(protocol, state, chunk, first(choices))
    end
    nothing
end

function consume!(protocol::OpenAIChatProtocol, state::ModelStreamState, chunk, choice)
    if !haskey(chunk, "usage") && haskey(choice, "usage")
        openai_model_usage!(state, choice["usage"])
    end
    reason = get(choice, "finish_reason", nothing)
    if !isnothing(reason) && reason != ""
        state.message["rawStopReason"] = reason
        state.message["stopReason"] = get(Dict("stop" => "stop", "end" => "stop", "length" => "length", "function_call" => "toolUse", "tool_calls" => "toolUse"), reason, "error")
        if state.message["stopReason"] == "error"
            state.error = "Provider finish_reason: $reason"
        end
    end
    Base.append!(protocol, state, get(choice, "delta", nothing))
end

Base.append!(::OpenAIChatProtocol, state::ModelStreamState, delta) = nothing

function Base.append!(::OpenAIChatProtocol, state::ModelStreamState, delta::AbstractDict)
    fields = ("reasoning_content", "reasoning", "reasoning_text")
    index = findfirst(field -> get(delta, field, nothing) isa AbstractString && !isempty(delta[field]), fields)
    if !isnothing(index)
        text_model_block!(state, "thinking", delta[fields[index]]; signature=fields[index])
    end
    text = get(delta, "content", nothing)
    if text isa AbstractString
        text_model_block!(state, "text", text)
    end
    foreach(tool -> openai_tool_delta!(state, tool), get(delta, "tool_calls", Any[]))
    nothing
end
function finish_protocol_stream!(::OpenAIChatProtocol, state::ModelStreamState)
    finish_model_blocks!(state)
    if !cancelled(state.context) && state.message["stopReason"] == "pending" && isempty(state.error)
        state.error = "Stream ended without finish_reason"
    end
    nothing
end
