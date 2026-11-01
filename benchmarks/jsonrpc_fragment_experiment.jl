using JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=benchmarks benchmarks/jsonrpc_fragment_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

# Both variants execute the actual repository transport source inside disjoint
# package namespaces, sharing the same JSON version and Julia process.
# The small surrounding package stub supplies only unrelated imports.
module BaselineHost
    module JuliaForever2
        using JSON
        struct ExecutionContext end
        cancelled(::Any) = false
        monotonic_seconds() = time_ns() / 1.0e9
        parse_json(text::AbstractString) = JSON.isvalidjson(text) ? JSON.parse(text) : nothing
    end
end
module CandidateHost
    module JuliaForever2
        using JSON
        struct ExecutionContext end
        cancelled(::Any) = false
        monotonic_seconds() = time_ns() / 1.0e9
        parse_json(text::AbstractString) = JSON.isvalidjson(text) ? JSON.parse(text) : nothing
    end
end
const baseline_file = joinpath(baseline_directory, "src/infrastructure/jsonrpc.jl")
const candidate_file = joinpath(candidate_directory, "src/infrastructure/jsonrpc.jl")
Base.include(BaselineHost.JuliaForever2, baseline_file)
Base.include(CandidateHost.JuliaForever2, candidate_file)
const baseline_api = BaselineHost.JuliaForever2
const candidate_api = CandidateHost.JuliaForever2

function encoded_notification(sequence, payload)
    return JSON.json(Dict("jsonrpc" => "2.0", "method" => "transcript/append",
        "params" => Dict("sequence" => sequence, "text" => payload))) * "\n"
end

function chunk_wire(wire, width)
    bytes = collect(codeunits(wire))
    return [bytes[offset:min(offset + width - 1, length(bytes))] for offset in 1:width:length(bytes)]
end

function fixture(count, payload, width; malformed=false)
    frames = [encoded_notification(index, payload * string(index)) for index in 1:count]
    wire = join(frames, "")
    malformed && (wire = frames[1] * "{malformed json}\n" * join(frames[2:end], ""))
    expected = [string(index, ":", payload, index) for index in 1:count]
    return (; chunks=chunk_wire(wire, width), expected,
        wire_bytes=ncodeunits(wire), chunk_bytes=width, frame_count=count)
end

const fixtures = Dict(
    # Representative end-to-end ingestion of 48 large, incrementally delivered
    # JSON-RPC transcript notifications; includes parsing, dispatch, drain.
    "integration/fragmented-transcript-48" => fixture(48, repeat("Julia tool output and streamed transcript: ", 275), 48),
    "integration/fragmented-unicode-24" => fixture(24, repeat("λ日本語🚀: parsed transport message; ", 180), 37),
    "integration/coalesced-transcript-48" => fixture(48, repeat("Julia tool output and streamed transcript: ", 275), 65536),
    "integration/small-notifications-400" => fixture(400, "short payload ", 128; malformed=true),
    "integration/partial-buffer-boundary-48" => fixture(48, repeat("response metadata ", 150), 2048),
)

function workload(api, data)
    return () -> begin
        received = String[]
        peer = api.JsonRpcPeer(IOBuffer(), IOBuffer();
            on_notification=(method, params) ->
                push!(received, string(params["sequence"], ":", params["text"])))
        for bytes in data.chunks
            api.feed!(peer, bytes)
        end
        api.drain!(peer)
        isempty(peer.buffer) || error("Unconsumed transport bytes")
        return received
    end
end

function trial(f)
    GC.gc()
    durations = Int[]
    for _ in 1:11
        started = time_ns()
        f()
        push!(durations, time_ns() - started)
    end
    return (; times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

function bootstrap_lower(values)
    seed = UInt64(0xa119b7e5)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(values)
            seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, values[Int(mod(seed, UInt64(length(values)))) + 1])
        end
        push!(medians, median(draw))
    end
    return quantile(medians, 0.025)
end

function profile_case(f, label)
    f()
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 350_000_000
        while time_ns() < deadline
            f()
        end
    end
    open(joinpath(output_directory, label * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=1.0 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if occursin("jsonrpc.jl", string(location.file))
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
    write(joinpath(output_directory, label * "-allocations.json"),
        JSON.json((sample_rate=1.0, sites=records)))
    Profile.Allocs.clear()
end

const baseline_sha = readchomp(`git -C $baseline_directory rev-parse HEAD`)
const candidate_sha = readchomp(`git -C $candidate_directory rev-parse HEAD`)
const metadata = (
    baseline_sha, candidate_sha, baseline_file, candidate_file,
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    architecture=string(Sys.ARCH), os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "benchmarks/Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "benchmarks/Project.toml")))),
    pairs=7, repetitions_per_pair_side=11, warmup_calls_per_case=8,
    alternating_order="AB,BA,AB,BA,AB,BA,AB",
    bootstrap="10,000 fixed-seed paired-median bootstrap draws, 2.5% lower quantile",
    transport="actual production feed! + JSON decode + notification dispatch + drain, local synthetic frames",
    fixtures=Dict(name => (wire_bytes=data.wire_bytes, chunk_bytes=data.chunk_bytes,
        frame_count=data.frame_count, chunk_count=length(data.chunks))
        for (name, data) in fixtures),
)
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))
results = Dict{String,Any}()
for name in sort!(collect(keys(fixtures)))
    data = fixtures[name]
    original = workload(baseline_api, data)
    candidate = workload(candidate_api, data)
    original() == data.expected || error("Baseline output mismatch: " * name)
    candidate() == data.expected || error("Candidate output mismatch: " * name)
    for _ in 1:8
        original()
        candidate()
    end
    baseline_trials = Any[]
    candidate_trials = Any[]
    for index in 1:7
        if isodd(index)
            push!(baseline_trials, trial(original))
            push!(candidate_trials, trial(candidate))
        else
            push!(candidate_trials, trial(candidate))
            push!(baseline_trials, trial(original))
        end
    end
    improvements = [1.0 - candidate_trials[index].median_ns / baseline_trials[index].median_ns for index in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=bootstrap_lower(improvements),
        minimum_pair_improvement=minimum(improvements),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocation_count)),
        correctness="exact notification outputs match")
    results[name] = result
    println(name, ": median improvement ", round(100 * result.median_improvement; digits=2),
        "%, lower 95% ", round(100 * result.ci95_lower_improvement; digits=2),
        "%, worst pair ", round(100 * result.minimum_pair_improvement; digits=2), "%")
    flush(stdout)
end
write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
profile_case(workload(baseline_api, fixtures["integration/fragmented-transcript-48"]), "baseline-integration")
profile_case(workload(candidate_api, fixtures["integration/fragmented-transcript-48"]), "candidate-integration")
representative = results["integration/fragmented-transcript-48"]
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
passed || error("Performance gate failed: do not create PR")
