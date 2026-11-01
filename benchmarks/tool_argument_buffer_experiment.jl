using JuliaForever2, JSON, SHA, Statistics, Profile, Pkg

const side = ENV["JF2_SIDE"]
const pair = parse(Int, ENV["JF2_PAIR"])
const evidence = ENV["EVIDENCE_DIR"]

const definitions = [
    ("openai/integration-large", :openai, 12, 120_000, 256, false),
    ("anthropic/integration-large", :anthropic, 12, 120_000, 256, false),
    ("openai/medium-fragments", :openai, 4, 24_000, 128, false),
    ("anthropic/medium-fragments", :anthropic, 4, 24_000, 128, false),
    ("openai/small-fragments", :openai, 1, 1_000, 64, false),
    ("anthropic/small-fragments", :anthropic, 1, 1_000, 64, false),
    ("openai/single-fragment", :openai, 4, 2_000, 4096, false),
    ("anthropic/single-fragment", :anthropic, 4, 2_000, 4096, false),
    ("openai/malformed-fragments", :openai, 1, 2_000, 91, true),
    ("anthropic/malformed-fragments", :anthropic, 1, 2_000, 91, true),
]
add_sse!(records, event) = push!(records, "data: " * JSON.json(event) * "\n\n")

function argument_fixture(index, nbytes, malformed)
    sample = "tool $(index) result; streaming JSON text with structured data \\u03bb. "
    value = repeat(sample, cld(nbytes, ncodeunits(sample)))[1:nbytes]
    return malformed ? "{\"payload\":\"" * value :
        JSON.json(Dict("payload" => value, "index" => index, "nested" => Dict("accepted" => true)))
end

function build_fixture(protocol, tools, nbytes, fragment_size, malformed)
    records = String[]
    if protocol == :anthropic
        add_sse!(records, Dict("type" => "message_start", "message" =>
            Dict("id" => "msg-benchmark", "model" => "synthetic-tool-model",
                "usage" => Dict("input_tokens" => 0, "output_tokens" => 0))))
    end
    for tool in 0:(tools - 1)
        arguments = argument_fixture(tool, nbytes, malformed)
        if protocol == :anthropic
            add_sse!(records, Dict("type" => "content_block_start", "index" => tool,
                "content_block" => Dict("type" => "tool_use", "id" => "call-$(tool)",
                    "name" => "perform", "input" => Dict{String,Any}())))
        end
        for first_byte in 1:fragment_size:ncodeunits(arguments)
            fragment = arguments[first_byte:min(first_byte + fragment_size - 1, ncodeunits(arguments))]
            if protocol == :openai
                add_sse!(records, Dict("id" => "response-benchmark",
                    "choices" => [Dict("delta" => Dict("tool_calls" => [
                        Dict("index" => tool, "id" => "call-$(tool)",
                            "function" => Dict("name" => "perform", "arguments" => fragment))
                    ]))]))
            else
                add_sse!(records, Dict("type" => "content_block_delta", "index" => tool,
                    "delta" => Dict("type" => "input_json_delta", "partial_json" => fragment)))
            end
        end
        if protocol == :anthropic
            add_sse!(records, Dict("type" => "content_block_stop", "index" => tool))
        end
    end
    if protocol == :openai
        add_sse!(records, Dict("choices" => [Dict("finish_reason" => "tool_calls")]))
        push!(records, "data: [DONE]\n\n")
    else
        add_sse!(records, Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "tool_use")))
        add_sse!(records, Dict("type" => "message_stop"))
    end
    return (protocol, Vector{UInt8}(codeunits(join(records))), tools, !malformed)
end

const fixtures = Dict{String,Any}(name => build_fixture(protocol, tools, nbytes, chunk, malformed)
    for (name, protocol, tools, nbytes, chunk, malformed) in definitions)
fixtures["mixed/integration-two-provider-conversation"] =
    [fixtures["openai/medium-fragments"], fixtures["anthropic/medium-fragments"]]

function process_fixture(fixture)
    protocol_name, bytes, tools, valid = fixture
    protocol = protocol_name == :openai ?
        JuliaForever2.OpenAIChatProtocol() : JuliaForever2.AnthropicMessagesProtocol()
    context = JuliaForever2.ExecutionContext()
    state = JuliaForever2.ModelStreamState(JuliaForever2.ModelSpec(:test, "synthetic-tool-model"), context)
    decoder = JuliaForever2.SSEDecoder(event -> JuliaForever2.consume_model_event!(protocol, state, event))
    write(decoder, bytes)
    JuliaForever2.finish_protocol_stream!(protocol, state)
    JuliaForever2.finish_model_stream!(state)
    blocks = state.message["content"]
    close(context)
    length(blocks) == tools || error("Lost tool calls")
    if valid
        all(block -> haskey(block["arguments"], "payload"), blocks) || error("Tool arguments not decoded")
    end
    return blocks
end

function process_fixture(sequence::AbstractVector)
    session = JuliaForever2.Session(JuliaForever2.Kernel())
    blocks = Any[]
    for fixture in sequence
        outcome = process_fixture(fixture)
        append!(blocks, outcome)
        JuliaForever2.append_message!(session.conversation,
            JuliaForever2.Message(:assistant, JSON.json(outcome), :text))
    end
    length(JuliaForever2.history_snapshot(session).messages) == length(sequence) ||
        error("Conversation history processing failed")
    close(session)
    blocks
end

function result_digest(blocks)
    output = IOBuffer()
    for block in blocks
        print(output, block["id"], '|', block["name"], '|')
        arguments = block["arguments"]
        if haskey(arguments, "payload")
            print(output, arguments["payload"], '|', arguments["index"], '|', arguments["nested"]["accepted"])
        else
            print(output, "<unparsed>")
        end
        print(output, '\n')
    end
    return bytes2hex(sha256(take!(output)))
end

function measure(fixture)
    for _ in 1:8
        process_fixture(fixture)
    end
    GC.gc()
    times = Int[]
    for _ in 1:7
        started = time_ns()
        process_fixture(fixture)
        push!(times, time_ns() - started)
    end
    return Dict("times_ns" => times, "median_ns" => median(times),
        "allocated_bytes" => Base.@allocated(process_fixture(fixture)),
        "allocation_count" => Base.@allocations(process_fixture(fixture)),
        "digest" => result_digest(process_fixture(fixture)))
end

function profile_integration(fixture)
    name = side * "-integration-large"
    process_fixture(fixture)
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 400_000_000
        while time_ns() < deadline
            process_fixture(fixture)
        end
    end
    open(joinpath(evidence, name * "-cpu.txt"), "w") do output
        Profile.print(output; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.005 process_fixture(fixture)
    allocations = Profile.Allocs.fetch().allocs
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in allocations
        frame = isempty(allocation.stacktrace) ? nothing : first(allocation.stacktrace)
        for candidate in allocation.stacktrace
            if occursin("http_models", string(candidate.file))
                frame = candidate
                break
            end
        end
        site = isnothing(frame) ? "<unknown>" : string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, samples=value[1], sampled_bytes=value[2]) for (site, value) in sites]
    sort!(records; by=value -> value.sampled_bytes, rev=true)
    write(joinpath(evidence, name * "-allocations.json"),
        JSON.json((sample_rate=0.005, total_sampled=length(allocations), sites=records)))
    Profile.Allocs.clear()
end

fixture_info(fixture::Tuple) = Dict("sse_bytes" => length(fixture[2]), "tools" => fixture[3])
fixture_info(sequence::AbstractVector) = Dict(
    "sse_bytes" => sum(length(fixture[2]) for fixture in sequence),
    "tools" => sum(fixture[3] for fixture in sequence),
    "provider_roundtrips" => length(sequence))

const metadata = Dict(
    "side" => side, "pair" => pair, "julia_version" => string(VERSION),
    "threads" => Threads.nthreads(), "cpu" => Sys.CPU_NAME,
    "architecture" => string(Sys.ARCH), "logical_cpus" => Sys.CPU_THREADS,
    "json_version" => string(Base.pkgversion(JSON)),
    "juliaforever_version" => string(Base.pkgversion(JuliaForever2)),
    "project_path" => Base.active_project(), "package_path" => pkgdir(JuliaForever2),
    "packages" => Dict(string(uuid) => string(info.version) for (uuid, info) in Pkg.dependencies() if !isnothing(info.version)),
    "fixtures" => Dict(name => fixture_info(fixture) for (name, fixture) in fixtures), "repetitions" => 7, "warmup" => 8)
const results = Dict{String,Any}()
for name in sort!(collect(keys(fixtures)))
    results[name] = measure(fixtures[name])
    println(name, " ", side, " ", round(results[name]["median_ns"] / 1e6; digits=3), " ms")
    flush(stdout)
end
write(joinpath(evidence, "pair-$(lpad(pair, 2, '0'))-$(side).json"),
    JSON.json(Dict("metadata" => metadata, "results" => results)))
if get(ENV, "JF2_PROFILE", "") == "1"
    profile_integration(fixtures["openai/integration-large"])
end
