using JuliaForever2, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Expected baseline worktree and output directory")
const baseline_dir = realpath(ARGS[1])
const output_dir = abspath(ARGS[2])
mkpath(output_dir)

module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_dir, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

frame(event, payload) = "event: " * event * "\ndata: " * JSON.json(payload) * "\n\n"

function make_fixture(kind::String, count::Int; unicode=false,
        initial="", stop=true, status=200, cancel=false)
    start = Dict("type" => "message_start", "message" => Dict(
        "id" => "msg_anthropic_perf", "model" => "offline-model",
        "usage" => Dict("input_tokens" => 18, "output_tokens" => 0)))
    opening = Dict("type" => "content_block_start", "index" => 0,
        "content_block" => Dict("type" => kind, kind => initial))
    frames = String[frame("message_start", start), frame("content_block_start", opening)]
    fragments = [unicode ? (isodd(index) ?
        repeat("λ 日本語 🚀 ", 13) : repeat("pure Julia ", 15)) :
        repeat("native Julia stream delta with repeated transcript text; ", 4) *
        string(mod(index, 10)) for index in 1:count]
    for fragment in fragments
        push!(frames, frame("content_block_delta", Dict(
            "type" => "content_block_delta", "index" => 0,
            "delta" => Dict("type" => kind * "_delta", kind => fragment))))
    end
    push!(frames, frame("content_block_stop", Dict("type" => "content_block_stop", "index" => 0)))
    push!(frames, frame("message_delta", Dict("type" => "message_delta",
        "delta" => Dict("stop_reason" => "end_turn"),
        "usage" => Dict("output_tokens" => 64))))
    stop && push!(frames, frame("message_stop", Dict("type" => "message_stop")))
    return (; kind, count, frames, expected=initial * join(fragments), status, cancel,
        wire_bytes=sum(ncodeunits, frames))
end

const fixtures = [
    "integration/anthropic-text-960" => make_fixture("text", 960),
    "integration/anthropic-thinking-720" => make_fixture("thinking", 720),
    "integration/anthropic-unicode-text-240" => make_fixture("text", 240; unicode=true),
    "integration/anthropic-short-text-24" => make_fixture("text", 24),
    "control/one-text-delta" => make_fixture("text", 1),
    "control/one-thinking-delta" => make_fixture("thinking", 1),
    "control/empty-initial" => make_fixture("text", 0; initial="initial text λ"),
    "control/no-message-stop" => make_fixture("text", 16; stop=false),
    "control/http-error" => make_fixture("text", 16; status=502),
    "control/cancelled" => make_fixture("text", 16; cancel=true),
]

function streamed_workload(package, data)
    return () -> begin
        events = package.HarnessEvent[]
        context = package.ExecutionContext(; event_sink=event -> push!(events, event))
        transport = (url, method, body, headers, request_context, decoder) -> begin
            for fragment in data.frames
                write(decoder, fragment)
            end
            data.cancel && package.cancel!(request_context)
            return (status=data.status, reason=data.status == 200 ? "OK" : "Synthetic HTTP error")
        end
        backend = package.HTTPModelBackend(package.AnthropicMessagesProtocol(),
            "https://offline.invalid"; transport)
        request = package.ModelRequest([package.Message(:user, "Produce a long response")],
            "", nothing, nothing, nothing)
        completion = package.respond_model(backend,
            package.ModelSpec(:synthetic, "offline-model"), request, context)
        conversation = package.Conversation()
        package.append_message!(conversation, package.Message(:assistant,
            completion.reply.content, completion.reply.kind))
        result = (reply=(completion.reply.kind, completion.reply.content),
            blocks=[(block["type"], get(block, block["type"], nothing))
                for block in completion.message["content"]],
            events=[event.data["type"] for event in events if event.kind == :model_stream],
            history=[(message.role, message.kind, message.content)
                for message in conversation.messages],
            stop_reason=completion.message["stopReason"],
            error=get(completion.message, "errorMessage", nothing))
        close(context)
        return result
    end
end

function sample(f)
    GC.gc()
    durations = Int[]
    for _ in 1:31
        started = time_ns()
        f()
        push!(durations, time_ns() - started)
    end
    return (times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocations=Base.@allocations(f()))
end

function bootstrap_limits(values)
    state = UInt64(0x616e7468726f7069)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(values)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, values[Int(mod(state, UInt64(length(values)))) + 1])
        end
        push!(medians, median(draw))
    end
    return (lower=quantile(medians, 0.025), upper=quantile(medians, 0.975))
end

function profile_case(f, label)
    f()
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 450_000_000
        while time_ns() < deadline
            f()
        end
    end
    open(joinpath(output_dir, label * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.1 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if occursin("anthropic.jl", string(location.file)) ||
                    occursin("backend.jl", string(location.file))
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=entry -> entry.bytes, rev=true)
    write(joinpath(output_dir, label * "-allocations.json"),
        JSON.json((sample_rate=0.1, sites=records)))
    Profile.Allocs.clear()
end

const metadata = (;
    baseline_sha=readchomp(Cmd(["git", "-C", baseline_dir, "rev-parse", "HEAD"])),
    candidate_sha=readchomp(Cmd(["git", "rev-parse", "HEAD"])),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    candidate_project_sha256=bytes2hex(sha256(read("test/Project.toml"))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_dir, "test/Project.toml")))),
    pairs=9, repetitions_per_pair_side=31, warmup_calls_per_case=4,
    order="AB,BA,AB,BA,AB,BA,AB,BA,AB",
    confidence="95% percentile bootstrap of paired trial median improvements; 10,000 fixed-seed resamples",
    input="actual Anthropic SSE protocol, JSON framing, event dispatch, model completion and conversation commit",
    environment="same Julia process, runner, test project, packages, single Julia thread",
    fixtures=[(; name, item.kind, item.count, item.wire_bytes,
        item.status, item.cancel) for (name, item) in fixtures])
write(joinpath(output_dir, "environment.json"), JSON.json(metadata))
results = Dict{String,Any}()
for (name, data) in fixtures
    old = streamed_workload(Baseline, data)
    new = streamed_workload(Candidate, data)
    expected = old()
    observed = new()
    isequal(expected, observed) || error("Baseline/candidate semantic mismatch on " * name)
    actual = only(filter(item -> item[1] == data.kind, observed.blocks))[2]
    actual == data.expected || error("Content changed on " * name)
    for _ in 1:4
        old()
        new()
    end
    baseline_trials, candidate_trials = Any[], Any[]
    for pair in 1:9
        if isodd(pair)
            push!(baseline_trials, sample(old))
            push!(candidate_trials, sample(new))
        else
            push!(candidate_trials, sample(new))
            push!(baseline_trials, sample(old))
        end
    end
    improvements = [1.0 - candidate_trials[pair].median_ns /
        baseline_trials[pair].median_ns for pair in 1:9]
    ci = bootstrap_limits(improvements)
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=ci.lower, ci95_upper_improvement=ci.upper,
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocations)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocations)),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)))
    results[name] = result
    write(joinpath(output_dir, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, " median=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% allocations=", result.baseline_median_allocations,
        "->", result.candidate_median_allocations)
    flush(stdout)
end

maincase = "integration/anthropic-text-960"
mainresult = results[maincase]
profile_case(streamed_workload(Baseline, first(fixtures).second), "baseline-anthropic")
profile_case(streamed_workload(Candidate, first(fixtures).second), "candidate-anthropic")
no_regressions = all(value.median_improvement > -0.03 &&
    value.ci95_lower_improvement > -0.07 for (key, value) in results if key != maincase)
accepted = mainresult.median_improvement > 0.10 &&
    mainresult.ci95_lower_improvement > 0.10 &&
    mainresult.minimum_pair_improvement > 0.10 && no_regressions
gate = (; accepted, representative=maincase, no_regressions,
    median_improvement=mainresult.median_improvement,
    ci95_lower_improvement=mainresult.ci95_lower_improvement,
    minimum_pair_improvement=mainresult.minimum_pair_improvement)
write(joinpath(output_dir, "gate.json"), JSON.json(gate))
println("PERFORMANCE_GATE=", JSON.json(gate))
accepted || error("Performance acceptance gate failed: no PR")
