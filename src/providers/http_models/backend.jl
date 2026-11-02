public response_usage_provenance, message_usage_accounting

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
    provenance::Union{Nothing,Dict{String,Any}}
end
StreamedCompletion(reply,usage,message) = StreamedCompletion(reply,usage,message,nothing)
response_usage_provenance(result) = nothing
response_usage_provenance(result::StreamedCompletion) = deepcopy(result.provenance)
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

"""Actual validated metering observations, independent of source-compatible initialized wire counters."""
Base.@kwdef mutable struct ModelUsageMeter
    input::Union{Nothing,Int} = nothing
    output::Union{Nothing,Int} = nothing
    cache_read::Union{Nothing,Int} = nothing
    cache_write::Union{Nothing,Int} = nothing
    cache_write_1h::Union{Nothing,Int} = nothing
end

"""Only calculate catalog estimates when metered components and applicable prices are known."""
function model_metered_cost(meter::ModelUsageMeter,metadata)
    rates=get(metadata,"cost",nothing)
    values=(meter.input,meter.output,meter.cache_read,meter.cache_write)
    prices=map(name->usage_cost(usage_detail(rates,name)),("input","output","cacheRead","cacheWrite"))
    hourly=usage_cost(usage_detail(rates,"cacheWrite1h"))
    hourly_present=rates isa AbstractDict && haskey(rates,"cacheWrite1h")
    cost=nothing
    if all(!isnothing,values) && all(!isnothing,prices) && (!hourly_present || !isnothing(hourly))
        counts=map(value->something(value,0),values)
        known_prices=map(value->something(value,0.0),prices)
        hourly_rate=hourly_present ? something(hourly,0.0) : known_prices[4]
        observed_hourly=meter.cache_write_1h
        split_known=counts[4]==0 || hourly_rate==known_prices[4] || !isnothing(observed_hourly)
        if split_known
            one_hour=min(something(observed_hourly,0),counts[4])
            ordinary=counts[4]-one_hour
            cost=usage_cost(known_prices[1]/1_000_000*counts[1]+known_prices[2]/1_000_000*counts[2]+
                known_prices[3]/1_000_000*counts[3]+known_prices[4]/1_000_000*ordinary+hourly_rate/1_000_000*one_hour)
        end
    end
    cost
end

"""Expose only observed token fields; computed cost is explicitly a catalog estimate, not a bill."""
function model_usage_provenance(report::UsageReport)
    values=Dict{String,Any}()
    fields=String[]
    for (name,value) in (("input",report.input_tokens),("output",report.output_tokens),
            ("cacheRead",report.cache_read_tokens),("cacheWrite",report.cache_write_tokens))
        if !isnothing(value)
            values[name]=value
            push!(fields,name)
        end
    end
    isnothing(report.cost) || (values["cost"]=report.cost)
    Dict{String,Any}("format"=>"JuliaForever2.usage-provenance.v1","observedFields"=>fields,
        "usage"=>values,"costSource"=>isnothing(report.cost) ? "unknown" : "catalog-estimate")
end

"""Read native presence metadata without rewriting imports or calling legacy declared cost a verified charge."""
function message_usage_accounting(message)
    raw=usage_detail(message,"usage")
    marker=usage_detail(usage_detail(message,"jf2"),"usageProvenance")
    native=marker isa AbstractDict && isequal(get(marker,"format",nothing),"JuliaForever2.usage-provenance.v1")
    report=UsageReport(raw)
    provenance=raw isa AbstractDict ? :legacy : :absent
    cost_source=isnothing(report.cost) ? :unknown : :legacy_declared
    if native
        data=usage_detail(marker,"usage")
        fields=get(marker,"observedFields",nothing)
        observed=fields isa AbstractVector ? fields : Any[]
        input=any(isequal("input"),observed) ? usage_tokens(usage_detail(data,"input")) : nothing
        output=any(isequal("output"),observed) ? usage_tokens(usage_detail(data,"output")) : nothing
        read=any(isequal("cacheRead"),observed) ? usage_tokens(usage_detail(data,"cacheRead")) : nothing
        written=any(isequal("cacheWrite"),observed) ? usage_tokens(usage_detail(data,"cacheWrite")) : nothing
        complete=all(!isnothing,(input,output,read,written))
        estimated=isequal(get(marker,"costSource",nothing),"catalog-estimate")
        cost=complete && estimated ? usage_cost(usage_detail(data,"cost")) : nothing
        report=UsageReport(input,output,cost,read,written)
        provenance=:native
        cost_source=isnothing(cost) ? :unknown : :catalog_estimate
    end
    (;report,provenance,cost_source)
end

mutable struct ModelStreamState{M,C}
    model::M
    context::C
    message::Dict{String,Any}
    blocks::Dict{Any,Int}
    arguments::Dict{Int,IOBuffer}
    text_buffers::Dict{Int,IOBuffer}
    closed_blocks::Set{Int}
    received_start::Bool
    received_stop::Bool
    started::Bool
    finished::Bool
    error::String
    started_at::UInt64
    metering::ModelUsageMeter
end
ModelStreamState(model, context) = ModelStreamState(model, context, empty_model_message(model), Dict{Any,Int}(), Dict{Int,IOBuffer}(), Dict{Int,IOBuffer}(), Set{Int}(), false, false, false, false, "", time_ns(), ModelUsageMeter())

"""Preserve the prior positional stream-state constructor without inventing metering observations."""
ModelStreamState(model,context,message,blocks,arguments,text_buffers,closed_blocks,received_start,received_stop,started,finished,error,started_at) =
    ModelStreamState(model,context,message,blocks,arguments,text_buffers,closed_blocks,received_start,received_stop,started,finished,error,started_at,ModelUsageMeter())

function model_reported_usage(state::ModelStreamState)
    meter=state.metering
    UsageReport(meter.input,meter.output,model_metered_cost(meter,model_metadata(state.model)),meter.cache_read,meter.cache_write)
end

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

"""Read accumulated streamed tool arguments without resetting the append position."""
function model_tool_argument_text(buffer::IOBuffer)
    seekstart(buffer)
    text = read(buffer, String)
    seekend(buffer)
    text
end

"""Accumulate fragments in linear time; parse only at a possible object boundary."""
function append_model_tool_arguments!(state::ModelStreamState, index::Int, fragment::AbstractString)
    buffer = state.arguments[index]
    write(buffer, fragment)
    possible_tool_object(String(fragment)) ? parse_json(model_tool_argument_text(buffer)) : nothing
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
        if haskey(state.arguments, index) && position(state.arguments[index]) > 0
            arguments = parse_model_tool_arguments(model_tool_argument_text(state.arguments[index]))
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
    report = model_reported_usage(state)
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
    return StreamedCompletion(reply, report, message, model_usage_provenance(report))
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
