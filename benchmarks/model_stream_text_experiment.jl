using JuliaForever2, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=test benchmarks/model_stream_text_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

# Load the identical production model backend and OpenAI streaming protocol in
# two disjoint namespaces. Both use the same Julia process, dependencies and
# production ExecutionContext, SSEDecoder, Conversation and JSON parser.
module BaselineModel
    using JSON
    import JuliaForever2: ExecutionContext, HarnessEvent, emit!, cancelled, UsageReport,
        Message, Reply, ModelRequest, ModelSpec, SSEDecoder, SSEEvent, parse_json,
        decode_reply, HTTPTransport, wire_content
end
module CandidateModel
    using JSON
    import JuliaForever2: ExecutionContext, HarnessEvent, emit!, cancelled, UsageReport,
        Message, Reply, ModelRequest, ModelSpec, SSEDecoder, SSEEvent, parse_json,
        decode_reply, HTTPTransport, wire_content
end

for (destination, directory) in ((BaselineModel, baseline_directory),
        (CandidateModel, candidate_directory))
    Base.include(destination, joinpath(directory, "src/providers/http_models/backend.jl"))
    Base.include(destination, joinpath(directory, "src/providers/http_models/openai_chat.jl"))
end

const model_spec = JuliaForever2.ModelSpec(:benchmark, "synthetic-openai")
const model_request = JuliaForever2.ModelRequest(JuliaForever2.Message[], "", nothing, nothing, nothing)
const large_ascii_text = repeat("Julia assistant processed streamed data, emitted events, and committed transcript. ", 1540)
const medium_ascii_text = repeat("A Julia response with repeated streaming updates. ", 100)
const unicode_parts = ["Julia λ🚀 ไทย Ελληνικά 中文 stream ", "café résumé 日本語\n", "مرحبا κόσμε "] 
const medium_unicode_text = join(repeat(unicode_parts, 68))
const thinking_parts = repeat(["Let me analyze step ", "λ ", "carefully. "], 35)
const answer_parts = repeat(["The Julia assistant completed ", "the requested analysis. "], 45)

function ascii_chunks(text, size)
    return [String(SubString(text, index, min(index + size - 1, ncodeunits(text))))
        for index in 1:size:ncodeunits(text)]
end

function model_frames(items)
    frames = String[]
    for (field, delta) in items
        choice = Dict("delta" => Dict(field => delta), "finish_reason" => nothing)
        push!(frames, "data: " * JSON.json(Dict("choices" => [choice])) * "\n\n")
    end
    finish = Dict("choices" => [Dict("delta" => Dict{String,Any}(), "finish_reason" => "stop")])
    push!(frames, "data: " * JSON.json(finish) * "\n\n")
    return frames
end

const fixtures = Dict{String,Vector{String}}(
    "integration/long-ascii-1600-events" => model_frames([("content", value)
        for value in ascii_chunks(large_ascii_text, 74)]),
    "integration/medium-ascii" => model_frames([("content", value)
        for value in ascii_chunks(medium_ascii_text, 72)]),
    "integration/medium-unicode" => model_frames([("content", part)
        for part in repeat(unicode_parts, 68)]),
    "integration/interleaved-thinking" => model_frames(vcat(
        [("reasoning_content", part) for part in thinking_parts],
        [("content", part) for part in answer_parts])),
    "control/short-ascii" => model_frames([("content", "Hello "), ("content", "world.")]),
    "control/single-unicode" => model_frames([("content", "Julia λ🚀 中文 response.")]),
)
const expected_text = Dict(
    "integration/long-ascii-1600-events" => large_ascii_text,
    "integration/medium-ascii" => medium_ascii_text,
    "integration/medium-unicode" => medium_unicode_text,
    "integration/interleaved-thinking" => join(answer_parts),
    "control/short-ascii" => "Hello world.",
    "control/single-unicode" => "Julia λ🚀 中文 response.",
)

# Full fake HTTP transport -> production SSEDecoder -> OpenAI event parser ->
# model stream context dispatch -> response finalization -> Conversation commit.
function workload(implementation::Module, frames)
    transport = function (url, method, body, headers, context, sink)
        for frame in frames
            write(sink, frame)
        end
        return (status=200, reason="OK")
    end
    backend = implementation.HTTPModelBackend(implementation.OpenAIChatProtocol(),
        "https://example.invalid"; transport)
    return () -> begin
        events = JuliaForever2.HarnessEvent[]
        context = JuliaForever2.ExecutionContext(; event_sink=event -> push!(events, event))
        result = implementation.respond_model(backend, model_spec, model_request, context)
        close(context)
        history = JuliaForever2.Conversation()
        JuliaForever2.append_message!(history,
            JuliaForever2.Message(:assistant, result.reply.content, :answer))
        snapshot = JuliaForever2.history_snapshot(history)
        return (result=result, events=events, committed=last(snapshot.messages).content)
    end
end

function canonical(run)
    message = deepcopy(run.result.message)
    delete!(message, "timestamp")
    delete!(message, "durationMs")
    return (reply_kind=run.result.reply.kind, reply_text=run.result.reply.content,
        message, events=[(event.kind, event.data) for event in run.events],
        committed=run.committed)
end

function trial(f)
    GC.gc()
    times = Int[]
    for _ in 1:7
        started = time_ns()
        f()
        push!(times, time_ns() - started)
    end
    return (times_ns=times, median_ns=median(times),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

function bootstrap_lower(improvements)
    seed = UInt64(0x66c2b4f912e3)
    medians = Float64[]
    for _ in 1:20000
        sample = Float64[]
        for _ in eachindex(improvements)
            seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(sample, improvements[Int(mod(seed, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(sample))
    end
    return quantile(medians, 0.025)
end

function profile_case(f, label)
    f()
    Profile.clear()
    Profile.@profile for _ in 1:8
        f()
    end
    open(joinpath(output_directory, label * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "backend.jl")
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(; site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(output_directory, label * "-allocation-sites.json"),
        JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const baseline_sha = readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"]))
const candidate_sha = readchomp(Cmd(["git", "-C", candidate_directory, "rev-parse", "HEAD"]))
const metadata = (;
    baseline_sha, candidate_sha, julia_version=string(VERSION),
    threads=Threads.nthreads(), cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    julia_project=Base.active_project(),
    json_version=string(Base.pkgversion(JSON)),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "test/Project.toml")))),
    candidate_project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "test/Project.toml")))),
    manifest_sha256=isfile(joinpath(candidate_directory, "test/Manifest.toml")) ?
        bytes2hex(sha256(read(joinpath(candidate_directory, "test/Manifest.toml")))) : nothing,
    pairs=7, timed_repetitions_per_side=7, warmups_per_side=6,
    order="AB,BA,AB,BA,AB,BA,AB",
    bootstrap="20,000 deterministic paired-median bootstrap draws; lower 2.5% quantile",
    integration="production OpenAI HTTP model adapter -> streamed SSE decoder -> event sink -> committed conversation",
    fixtures=Dict(name => (frames=length(frames),
        wire_bytes=sum(ncodeunits, frames)) for (name, frames) in fixtures))
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for name in sort!(collect(keys(fixtures)))
    frames = fixtures[name]
    baseline = workload(BaselineModel, frames)
    candidate = workload(CandidateModel, frames)
    baseline_check = canonical(baseline())
    candidate_check = canonical(candidate())
    isequal(candidate_check, baseline_check) || error("Baseline/candidate output mismatch in " * name)
    baseline_check.committed == expected_text[name] || error("Incorrect conversation result in " * name)
    for _ in 1:6
        baseline()
        candidate()
    end
    baseline_trials, candidate_trials = Any[], Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, trial(baseline))
            push!(candidate_trials, trial(candidate))
        else
            push!(candidate_trials, trial(candidate))
            push!(baseline_trials, trial(baseline))
        end
    end
    improvements = [1 - candidate_trials[index].median_ns / baseline_trials[index].median_ns for index in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        improvements, median_improvement=median(improvements),
        ci95_lower_improvement=bootstrap_lower(improvements),
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocation_count)),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        correctness="exact final reply, committed history, event stream and message payload")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": median=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% minimumPair=", round(100 * result.minimum_pair_improvement; digits=2), "%")
    flush(stdout)
end
profile_case(workload(BaselineModel, fixtures["integration/long-ascii-1600-events"]), "baseline-long-integration")
profile_case(workload(CandidateModel, fixtures["integration/long-ascii-1600-events"]), "candidate-long-integration")
profile_case(workload(BaselineModel, fixtures["control/short-ascii"]), "baseline-short-control")
profile_case(workload(CandidateModel, fixtures["control/short-ascii"]), "candidate-short-control")
representative = results["integration/long-ascii-1600-events"]
no_regressions = all(result -> result.median_improvement >= -0.05 &&
    result.ci95_lower_improvement >= -0.10, values(results))
passed = representative.median_improvement > 0.10 &&
    representative.ci95_lower_improvement > 0.10 &&
    representative.minimum_pair_improvement > 0.10 && no_regressions
gate = (; passed, no_regressions, median_improvement=representative.median_improvement,
    ci95_lower_improvement=representative.ci95_lower_improvement,
    minimum_pair_improvement=representative.minimum_pair_improvement)
write(joinpath(output_directory, "gate.json"), JSON.json(gate))
println("PERFORMANCE_GATE=", passed ? "PASS" : "FAIL")
passed || error("Performance acceptance failed; do not open a PR")
