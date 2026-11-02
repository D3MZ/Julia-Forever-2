using JuliaForever2, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=test benchmarks/extension_dispatch_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

# Load the unmodified baseline package source into a separate namespace.
# Both versions use the same Julia process, Julia environment, runner and packages.
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

const delta_parts = ["Delta $(index): Julia event routing handles λ, 中文 and UTF-8.\n" for index in 1:240]
const frames = ["event: response.output_text.delta\ndata: " *
    JSON.json(Dict("delta" => delta)) * "\n\n" for delta in delta_parts]
const expected_text = join(delta_parts)

# An integrated stream through production SSE decoding, ExecutionContext,
# extension event routing, one observed reply and Conversation commit.
function stream_session(package, count; subscribe_deltas=false)
    scope = package.ExtensionScope()
    committed = Ref("")
    forwarded = Ref(0)
    package.on!(event -> (committed[] = event.data; nothing), scope, :reply)
    if subscribe_deltas
        package.on!(event -> (forwarded[] += 1; nothing), scope, :provider_delta)
    end
    context = package.ExecutionContext(;
        event_sink=event -> package.dispatch_event!(scope, event.kind, event))
    output = IOBuffer()
    decoder = package.SSEDecoder(event -> begin
        delta = JSON.parse(event.data)["delta"]
        write(output, delta)
        package.emit!(context, package.HarnessEvent(:provider_delta, delta))
    end)
    for frame in @view frames[1:count]
        write(decoder, frame)
    end
    text = String(take!(output))
    package.emit!(context, package.HarnessEvent(:reply, text))
    conversation = package.Conversation()
    package.append_message!(conversation, package.Message(:assistant, text, :answer))
    content = only(package.history_snapshot(conversation).messages).content
    close(context)
    close(scope)
    return (content=content, observed_reply=committed[],
        forwarded=forwarded[], messages=length(conversation.messages))
end

function bare_events(package, count, mode; subscribed=false)
    scope = package.ExtensionScope()
    observed = Ref(0)
    subscribed && package.on!(value -> (observed[] += value; nothing), scope, :event)
    for _ in 1:count
        package.dispatch_event!(scope, :event, 1; mode)
    end
    close(scope)
    return observed[]
end

function waterfall_events(package, count)
    scope = package.ExtensionScope()
    invoked = Ref(0)
    for _ in 1:count
        package.dispatch_event!(scope, :unobserved,
            () -> (invoked[] += 1; nothing); mode=:waterfall)
    end
    close(scope)
    return invoked[]
end

const cases = [
    ("integration/sse-240-unobserved", package -> stream_session(package, 240)),
    ("integration/sse-80-unobserved", package -> stream_session(package, 80)),
    ("integration/sse-240-subscribed", package -> stream_session(package, 240; subscribe_deltas=true)),
    ("dispatch/unobserved-240-emit", package -> bare_events(package, 240, :emit)),
    ("dispatch/unobserved-240-parallel", package -> bare_events(package, 240, :parallel)),
    ("dispatch/observed-64-emit", package -> bare_events(package, 64, :emit; subscribed=true)),
    ("dispatch/waterfall-64", package -> waterfall_events(package, 64)),
]

function sample(f)
    GC.gc()
    times = Int[]
    for _ in 1:11
        before = time_ns()
        f()
        push!(times, time_ns() - before)
    end
    return (times_ns=times, median_ns=median(times),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

function bootstrap_bounds(improvements)
    seed = UInt64(0x7d11bdf8)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(improvements)
            seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, improvements[Int(mod(seed, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(draw))
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
    open(joinpath(output_directory, prefix * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(allocation -> !isempty(allocation.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "extensions.jl")
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(output_directory, prefix * "-allocation-sites.json"),
        JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const metadata = (;
    baseline_sha=readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"])),
    candidate_sha=readchomp(Cmd(["git", "-C", candidate_directory, "rev-parse", "HEAD"])),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(), cpu=Sys.CPU_NAME,
    logical_cpus=Sys.CPU_THREADS, architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "test/Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "test/Project.toml")))),
    manifest_sha256=isfile(joinpath(candidate_directory, "test/Manifest.toml")) ?
        bytes2hex(sha256(read(joinpath(candidate_directory, "test/Manifest.toml")))) : nothing,
    pairs=7, repetitions_per_side=11, warmup_calls_per_case=6,
    order="AB,BA,AB,BA,AB,BA,AB",
    ci="10,000 deterministic resampled medians over seven paired improvements",
    integration="real SSEDecoder, ExecutionContext event sink, ExtensionScope routing, reply listener, Conversation commit",
    frames=length(frames), bytes=sum(ncodeunits, frames), thread_configuration="JULIA_NUM_THREADS=1; OPENBLAS_NUM_THREADS=1")
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for (name, factory) in cases
    baseline = () -> factory(Baseline)
    candidate = () -> factory(Candidate)
    expected = baseline()
    actual = candidate()
    isequal(expected, actual) || error("Baseline/candidate mismatch in $(name)")
    if startswith(name, "integration/")
        count = occursin("sse-80", name) ? 80 : 240
        expected.content == join(@view delta_parts[1:count]) || error("Wrong committed content in $(name)")
        expected.observed_reply == expected.content || error("Reply listener was not invoked in $(name)")
        expected.forwarded == (endswith(name, "subscribed") ? count : 0) ||
            error("Incorrect delta listener count in $(name)")
        expected.messages == 1 || error("Missing conversation commit in $(name)")
    end
    for _ in 1:6
        baseline()
        candidate()
    end
    baseline_samples = Any[]
    candidate_samples = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_samples, sample(baseline))
            push!(candidate_samples, sample(candidate))
        else
            push!(candidate_samples, sample(candidate))
            push!(baseline_samples, sample(baseline))
        end
    end
    improvements = [1 - candidate_samples[i].median_ns / baseline_samples[i].median_ns for i in 1:7]
    confidence = bootstrap_bounds(improvements)
    result = (; baseline=baseline_samples, candidate=candidate_samples,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=confidence.lower, ci95_upper_improvement=confidence.upper,
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_samples, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_samples, :allocation_count)),
        baseline_median_bytes=median(getproperty.(baseline_samples, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_samples, :allocated_bytes)),
        correctness="exact results and final integration transcript match")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": median=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% allocations=", result.baseline_median_allocations, "->", result.candidate_median_allocations)
    flush(stdout)
end

profile_case(() -> stream_session(Baseline, 240), "baseline-stream-240")
profile_case(() -> stream_session(Candidate, 240), "candidate-stream-240")

flagship = results["integration/sse-240-unobserved"]
all_nonregressed = all(value.median_improvement > -0.03 &&
    value.ci95_lower_improvement > -0.07 for (name, value) in results if name != "integration/sse-240-unobserved")
accepted = flagship.median_improvement > 0.10 &&
    flagship.ci95_lower_improvement > 0.10 && all_nonregressed
gate = (accepted=accepted, flagship="integration/sse-240-unobserved",
    improvement=flagship.median_improvement, lower95=flagship.ci95_lower_improvement,
    no_material_regressions=all_nonregressed)
write(joinpath(output_directory, "gate.json"), JSON.json(gate))
println("Acceptance gate: ", JSON.json(gate))
accepted || error("Performance acceptance gate failed; do not create PR")
