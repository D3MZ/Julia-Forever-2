using JuliaForever2, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=test benchmarks/empty_scope_retirement_experiment.jl BASELINE_WORKTREE EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)

# Baseline and candidate execute within one Julia process, with the same loaded
# dependencies, hardware, thread settings, input bytes, and compiler warmup.
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

const deltas = ["Julia streaming part $(index): λ, 中文, and tool result updates.\n" for index in 1:8]
const frames = ["event: response.output_text.delta\ndata: " *
    JSON.json(Dict("delta" => delta)) * "\n\n" for delta in deltas]

# Real SSE -> application event routing -> conversation history -> resource
# retirement, repeated for independently scoped short assistant sessions.
function stream_sessions(package, count, parts; subscribed=false)
    total_bytes = 0
    total_messages = 0
    observed_replies = 0
    for _ in 1:count
        scope = package.ExtensionScope()
        if subscribed
            package.on!(event -> (observed_replies += 1; nothing), scope, :reply)
        end
        context = package.ExecutionContext(;
            event_sink=event -> package.dispatch_event!(scope, event.kind, event))
        buffer = IOBuffer()
        decoder = package.SSEDecoder(event -> write(buffer, JSON.parse(event.data)["delta"]))
        for frame in @view frames[1:parts]
            write(decoder, frame)
        end
        transcript = String(take!(buffer))
        package.emit!(context, package.HarnessEvent(:reply, transcript))
        conversation = package.Conversation()
        package.append_message!(conversation, package.Message(:assistant, transcript, :answer))
        snapshot = package.history_snapshot(conversation)
        total_bytes += ncodeunits(only(snapshot.messages).content)
        total_messages += length(snapshot.messages)
        close(context)
        close(scope)
    end
    return (total_bytes=total_bytes, messages=total_messages, observed=observed_replies)
end

function lifecycle(package, count; nested=false, resource=false)
    cleanups = Ref(0)
    for _ in 1:count
        scope = package.ExtensionScope()
        nested && package.ExtensionScope(scope)
        if resource
            package.own_resource!(scope, 1; cleanup=value -> (cleanups[] += value; nothing))
        end
        close(scope)
        isopen(scope) && error("Retired scope remains open")
    end
    return (retired=count, cleanups=cleanups[])
end

function unobserved_events(package, count)
    scope = package.ExtensionScope()
    for _ in 1:count
        package.dispatch_event!(scope, :no_listeners, 1)
    end
    close(scope)
    return count
end

const cases = [
    ("integration/96-scoped-sse-sessions-2-deltas", package -> stream_sessions(package, 96, 2)),
    ("integration/64-scoped-sse-sessions-8-deltas", package -> stream_sessions(package, 64, 8)),
    ("integration/48-scoped-sse-sessions-2-deltas-observed", package -> stream_sessions(package, 48, 2; subscribed=true)),
    ("lifecycle/empty-256", package -> lifecycle(package, 256)),
    ("lifecycle/nested-64", package -> lifecycle(package, 64; nested=true)),
    ("lifecycle/owned-40", package -> lifecycle(package, 40; resource=true)),
    ("dispatch/unobserved-240", package -> unobserved_events(package, 240)),
]

function measure(f)
    GC.gc()
    durations = Int[]
    for _ in 1:11
        start = time_ns()
        f()
        push!(durations, time_ns() - start)
    end
    return (times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

function bootstrap_bounds(improvements)
    state = UInt64(0x9ac7d025f315)
    medians = Float64[]
    for _ in 1:10000
        sampled = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(sampled, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(sampled))
    end
    return (lower=quantile(medians, 0.025), upper=quantile(medians, 0.975))
end

function profile_case(f, prefix)
    f()
    Profile.clear()
    Profile.@profile begin
        until = time_ns() + 400_000_000
        while time_ns() < until
            f()
        end
    end
    open(joinpath(evidence_directory, prefix * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        selected = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "extensions.jl")
                selected = location
                break
            end
        end
        key = string(selected.file, ":", selected.line, " ", selected.func)
        count, bytes = get(sites, key, (0, 0))
        sites[key] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(evidence_directory, prefix * "-allocation-sites.json"),
        JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const metadata = (;
    baseline_sha=readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"])),
    candidate_sha=readchomp(Cmd(["git", "-C", candidate_directory, "rev-parse", "HEAD"])),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "test/Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "test/Project.toml")))),
    manifest_sha256=isfile(joinpath(candidate_directory, "test/Manifest.toml")) ?
        bytes2hex(sha256(read(joinpath(candidate_directory, "test/Manifest.toml")))) : nothing,
    pairs=7, repetitions_per_side=11, warmup_calls_per_case=6,
    order="AB,BA,AB,BA,AB,BA,AB",
    ci="10,000 deterministic bootstrap resampled medians of paired improvements",
    integration="production SSEDecoder -> ExecutionContext -> ExtensionScope event routing -> Conversation history -> close(context) and close(scope)",
    frames_per_stream=length(frames), total_frame_bytes=sum(ncodeunits, frames),
    threads="JULIA_NUM_THREADS=1; OPENBLAS_NUM_THREADS=1")
write(joinpath(evidence_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for (name, factory) in cases
    baseline = () -> factory(Baseline)
    candidate = () -> factory(Candidate)
    expected = baseline()
    actual = candidate()
    isequal(expected, actual) || error("Baseline/candidate mismatch: $(name)")
    if startswith(name, "integration/")
        count = occursin("96-scoped", name) ? 96 : occursin("64-scoped", name) ? 64 : 48
        parts = occursin("8-deltas", name) ? 8 : 2
        expected.total_bytes == count * sum(ncodeunits, @view deltas[1:parts]) ||
            error("Wrong committed transcript length in $(name)")
        expected.messages == count || error("Missing conversation commit in $(name)")
        expected.observed == (occursin("observed", name) ? count : 0) ||
            error("Incorrect reply count in $(name)")
    end
    if name == "lifecycle/owned-40"
        expected.cleanups == 40 || error("Owned cleanup not invoked")
    end
    for _ in 1:6
        baseline()
        candidate()
    end
    baseline_samples = Any[]
    candidate_samples = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_samples, measure(baseline))
            push!(candidate_samples, measure(candidate))
        else
            push!(candidate_samples, measure(candidate))
            push!(baseline_samples, measure(baseline))
        end
    end
    improvements = [1 - candidate_samples[i].median_ns / baseline_samples[i].median_ns for i in 1:7]
    confidence = bootstrap_bounds(improvements)
    result = (; baseline=baseline_samples, candidate=candidate_samples,
        paired_improvements=improvements,
        median_improvement=median(improvements),
        ci95_lower_improvement=confidence.lower,
        ci95_upper_improvement=confidence.upper,
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_samples, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_samples, :allocation_count)),
        baseline_median_bytes=median(getproperty.(baseline_samples, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_samples, :allocated_bytes)),
        correctness="baseline and candidate results equal; integrated transcripts match")
    results[name] = result
    write(joinpath(evidence_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": improvement=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% allocations=", result.baseline_median_allocations, "->", result.candidate_median_allocations)
    flush(stdout)
end

profile_case(() -> stream_sessions(Baseline, 96, 2), "baseline-integrated")
profile_case(() -> stream_sessions(Candidate, 96, 2), "candidate-integrated")

flagship = results["integration/96-scoped-sse-sessions-2-deltas"]
no_regressions = all(value.median_improvement > -0.03 &&
    value.ci95_lower_improvement > -0.07 for (name, value) in results
    if name != "integration/96-scoped-sse-sessions-2-deltas")
accepted = flagship.median_improvement > 0.10 &&
    flagship.ci95_lower_improvement > 0.10 && no_regressions
gate = (accepted=accepted, flagship="integration/96-scoped-sse-sessions-2-deltas",
    median_improvement=flagship.median_improvement,
    lower95_improvement=flagship.ci95_lower_improvement,
    no_material_regressions=no_regressions)
write(joinpath(evidence_directory, "gate.json"), JSON.json(gate))
println("Acceptance gate: ", JSON.json(gate))
accepted || error("Performance gate failed: do not create a PR")
