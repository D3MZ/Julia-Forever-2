using JuliaForever2, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=test benchmarks/protocol_utf8_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

# Run actual production streaming code in disjoint namespaces, with shared
# runtime/dependencies and identical input data.
module BaselineStreaming
    import JuliaForever2: CodeModePolicy, ExecutionContext, HarnessEvent, cancelled, emit!, operation_id
end
module CandidateStreaming
    import JuliaForever2: CodeModePolicy, ExecutionContext, HarnessEvent, cancelled, emit!, operation_id
end
const baseline_file = joinpath(baseline_directory, "src/features/code_mode/streaming.jl")
const candidate_file = joinpath(candidate_directory, "src/features/code_mode/streaming.jl")
Base.include(BaselineStreaming, baseline_file)
Base.include(CandidateStreaming, candidate_file)

const policy = JuliaForever2.CodeModePolicy()
const ascii_text = repeat("Julia assistant reported a normal result and processed tool output. ", 62)
const unicode_text = repeat("Julia agent: λ日本語🚀, café, Ελληνικά, мир, ไทย, हिंदी. ", 62)
const escaped_text = repeat("Julia agent: λ日本語🚀; path=C:\\temp\\data; output=\"ready\"\n", 62)
const mixed_text = repeat("The Julia model answers: αβγ 🚀 中文 assistant code output. ", 55)

function cumulative_frames(content, count)
    wire = collect(codeunits("{\"kind\":\"answer\",\"content\":" * JSON.json(content) * "}"))
    prefix_bytes = ncodeunits("{\"kind\":\"answer\",\"content\":\"")
    indices = unique!(round.(Int, range(prefix_bytes + 1, length(wire); length=count)))
    last(indices) == length(wire) || push!(indices, length(wire))
    return [String(copy(@view wire[1:index])) for index in indices]
end

const fixtures = Dict(
    "integration/unicode-stream-220-updates" => cumulative_frames(unicode_text, 220),
    "integration/escaped-stream-220-updates" => cumulative_frames(escaped_text, 220),
    "integration/ascii-stream-220-updates" => cumulative_frames(ascii_text, 220),
    "integration/mixed-stream-180-updates" => cumulative_frames(mixed_text, 180),
    "decoder/full-unicode-response" => cumulative_frames(unicode_text, 1),
    "decoder/full-ascii-response" => cumulative_frames(ascii_text, 1),
)

# End-to-end code-mode response updates: decode, emit through the production
# ExecutionContext, consume events, commit final message to Conversation.
function integration(decoder_module, frames)
    return () -> begin
        events = JuliaForever2.HarnessEvent[]
        context = JuliaForever2.ExecutionContext(; event_sink=event -> push!(events, event))
        for partial in frames
            decoder_module.emit_protocol_progress!(policy, partial, context)
        end
        close(context)
        answers = [(event.data.progress.kind, event.data.progress.text) for event in events]
        conversation = JuliaForever2.Conversation()
        isempty(answers) || JuliaForever2.append_message!(conversation,
            JuliaForever2.Message(:assistant, last(answers)[2], :answer))
        snapshot = JuliaForever2.history_snapshot(conversation)
        content = isempty(snapshot.messages) ? "" : last(snapshot.messages).content
        return (; answers, content)
    end
end

function workload(decoder_module, name, frames)
    if startswith(name, "integration/")
        return integration(decoder_module, frames)
    end
    return () -> begin
        preview = decoder_module.protocol_progress(policy, last(frames))
        return isnothing(preview) ? nothing : (preview.kind, preview.text)
    end
end

function trial(f)
    GC.gc()
    times = Int[]
    for _ in 1:11
        start = time_ns()
        f()
        push!(times, time_ns() - start)
    end
    return (; times_ns=times, median_ns=median(times),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

function bootstrap_lower(improvements)
    seed = UInt64(0xd9b0aee9)
    medians = Float64[]
    for _ in 1:10000
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
    Profile.@profile begin
        until = time_ns() + 350_000_000
        while time_ns() < until
            f()
        end
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
            if endswith(string(location.file), "streaming.jl")
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
    baseline_sha, candidate_sha, baseline_file, candidate_file,
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "test/Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "test/Project.toml")))),
    manifest_sha256=isfile(joinpath(candidate_directory, "test/Manifest.toml")) ?
        bytes2hex(sha256(read(joinpath(candidate_directory, "test/Manifest.toml")))) : nothing,
    pairs=7, repetitions_per_pair_side=11, warmup_calls_per_case=6,
    alternating_order="AB,BA,AB,BA,AB,BA,AB",
    bootstrap="10,000 deterministic paired median bootstrap draws; lower 2.5% quantile",
    integration="production code-mode stream decoding, context event dispatch, and conversation commit",
    fixtures=Dict(name => (updates=length(frames), last_frame_bytes=ncodeunits(last(frames)))
        for (name, frames) in fixtures))
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for name in sort!(collect(keys(fixtures)))
    frames = fixtures[name]
    baseline = workload(BaselineStreaming, name, frames)
    candidate = workload(CandidateStreaming, name, frames)
    expected = baseline()
    isequal(candidate(), expected) || error("Output mismatch in: " * name)
    if startswith(name, "integration/")
        exact = name == "integration/unicode-stream-220-updates" ? unicode_text :
            name == "integration/escaped-stream-220-updates" ? escaped_text :
            name == "integration/ascii-stream-220-updates" ? ascii_text : mixed_text
        expected.content == exact || error("Incorrect final transcript: " * name)
    end
    for _ in 1:6
        baseline()
        candidate()
    end
    baseline_trials = Any[]
    candidate_trials = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, trial(baseline))
            push!(candidate_trials, trial(candidate))
        else
            push!(candidate_trials, trial(candidate))
            push!(baseline_trials, trial(baseline))
        end
    end
    improvements = [1.0 - candidate_trials[index].median_ns / baseline_trials[index].median_ns for index in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=bootstrap_lower(improvements),
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocation_count)),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        correctness="exact previews, event ordering, and committed transcript match")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": median=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% minimumPair=", round(100 * result.minimum_pair_improvement; digits=2), "%")
    flush(stdout)
end
profile_case(integration(BaselineStreaming, fixtures["integration/unicode-stream-220-updates"]), "baseline-unicode-integration")
profile_case(integration(CandidateStreaming, fixtures["integration/unicode-stream-220-updates"]), "candidate-unicode-integration")
profile_case(integration(BaselineStreaming, fixtures["integration/ascii-stream-220-updates"]), "baseline-ascii-control")
profile_case(integration(CandidateStreaming, fixtures["integration/ascii-stream-220-updates"]), "candidate-ascii-control")
representative = results["integration/unicode-stream-220-updates"]
no_regressions = all(result -> result.median_improvement >= -0.05 &&
    result.ci95_lower_improvement >= -0.10, values(results))
passed = representative.median_improvement > 0.10 &&
    representative.ci95_lower_improvement > 0.10 &&
    representative.minimum_pair_improvement > 0.10 && no_regressions
write(joinpath(output_directory, "gate.json"), JSON.json((; passed, no_regressions,
    median_improvement=representative.median_improvement,
    ci95_lower_improvement=representative.ci95_lower_improvement,
    minimum_pair_improvement=representative.minimum_pair_improvement)))
println("PERFORMANCE_GATE=", passed ? "PASS" : "FAIL")
passed || error("Performance acceptance failed; do not open a PR")
