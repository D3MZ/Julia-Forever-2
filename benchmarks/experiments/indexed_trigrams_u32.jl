using JuliaForever2, JSON, Profile, Statistics, SHA, UUIDs

length(ARGS) == 2 || error("Usage: julia --project=benchmarks benchmarks/experiments/indexed_trigrams_u32.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, "..", ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

# Both full package implementations share precisely the same Julia process and
# dependency versions; only source trees differ.
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2
const namespace = UUID("38b1763f-81d1-458c-8672-46c13080e901")

function fixture(label::String, sessions::Int, messages::Int, repeat_count::Int)
    directory = mktempdir()
    ascii_text = repeat("Julia FOREVER tool output: indexed transcript with structured decisions. ", repeat_count)
    unicode_text = repeat("Julia λ日本語🚀 transcript: Unicode cross-language response. ", max(1, repeat_count ÷ 3))
    for index in 1:sessions
        name = "session-$(lpad(index, 4, '0'))"
        id = uuid5(namespace, label * "-" * name)
        entries = [Dict(
            "role" => message_index % 3 == 0 ? "assistant" : "user",
            "kind" => message_index % 3 == 0 ? "answer" : "text",
            "content" => (message_index % 13 == 0 ? unicode_text : ascii_text) *
                " token-$(lpad(message_index, 5, '0')) session-$(lpad(index, 4, '0'))"
        ) for message_index in 1:messages]
        record = Dict(
            "format" => "JuliaForever2.session",
            "version" => 2,
            "name" => name,
            "working_directory" => directory,
            "messages" => entries,
            "lineage" => Dict("id" => string(id), "root_id" => string(id), "parent_id" => nothing))
        write(joinpath(directory, name * ".json"), JSON.json(record))
    end
    (; directory, sessions, messages, repeat_count)
end

const fixtures = Dict(
    "integration/large-persisted-index-search-json" => fixture("large", 24, 112, 12),
    "integration/medium-persisted-index-search-json" => fixture("medium", 12, 72, 8),
    "integration/small-persisted-index-search-json" => fixture("small", 5, 20, 2),
)
const queries = ["JULIA", "tool output", "structured decisions", "token-00007", "λ日本語", "unmatched-unique-pattern"]

function serialized_hits(package, searcher)
    JSON.json([(query=query, matches=package.search_history(searcher, query; limit=12)) for query in queries])
end

function run_integrated(package, item)
    () -> begin
        store = package.SessionStore(item.directory)
        index = package.SessionSearchIndex(store)
        serialized_hits(package, index)
    end
end

function run_mixed(package, item)
    () -> begin
        store = package.SessionStore(item.directory)
        index = package.SessionSearchIndex(store)
        indexed = serialized_hits(package, index)
        persisted = package.search_history(store, "λ日本語"; limit=5)
        JSON.json((indexed=indexed, persisted=persisted,
            summary=package.session_summary(store, "session-0001")))
    end
end

function run_cached(package, item)
    store = package.SessionStore(item.directory)
    index = package.SessionSearchIndex(store)
    () -> serialized_hits(package, index)
end

function run_unindexed(package, item)
    store = package.SessionStore(item.directory)
    () -> serialized_hits(package, store)
end

# Verify both full package versions against the independent persisted-session
# query path, including case folding, multiword matching, unicode fallback and
# absence. This is an output-contract check, not a PR-time quality workflow.
function verify_contract(package, item)
    store = package.SessionStore(item.directory)
    index = package.SessionSearchIndex(store)
    for query in queries
        expected = package.search_history(store, query; limit=12)
        actual = package.search_history(index, query; limit=12)
        isequal(actual, expected) || error("Indexed search diverged from durable search: " * query)
    end
    count = length(package.search_history(index, "λ日本語"; limit=12))
    count > 0 || error("Unicode fallback was not exercised")
    occursin("session-0001", serialized_hits(package, index)) ||
        error("Index output did not include its session identity")
    true
end

const large = fixtures["integration/large-persisted-index-search-json"]
const medium = fixtures["integration/medium-persisted-index-search-json"]
const small = fixtures["integration/small-persisted-index-search-json"]
const workloads = Dict(
    "integration/large-persisted-index-search-json" =>
        (run_integrated(Baseline, large), run_integrated(Candidate, large), :changed),
    "integration/medium-persisted-index-search-json" =>
        (run_integrated(Baseline, medium), run_integrated(Candidate, medium), :changed),
    "integration/small-persisted-index-search-json" =>
        (run_integrated(Baseline, small), run_integrated(Candidate, small), :changed),
    "integration/mixed-index-and-direct-session-processing" =>
        (run_mixed(Baseline, medium), run_mixed(Candidate, medium), :changed),
    "secondary/cached-index-query" =>
        (run_cached(Baseline, medium), run_cached(Candidate, medium), :changed),
    "control/unchanged-direct-persisted-search" =>
        (run_unindexed(Baseline, small), run_unindexed(Candidate, small), :unchanged),
)

function sample(f)
    GC.gc()
    durations = Int[]
    for _ in 1:5
        started = time_ns()
        f()
        push!(durations, time_ns() - started)
    end
    (; times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocations=Base.@allocations(f()))
end

function lower_confidence(improvements)
    state = UInt64(0x6b908e61072b8133)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(draw))
    end
    quantile(medians, 0.025)
end

function profile_case(f, prefix)
    f()
    Profile.clear()
    Profile.@profile begin
        until = time_ns() + 350_000_000
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
    for allocation in Iterators.filter(entry -> !isempty(entry.stacktrace), Profile.Allocs.fetch().allocs)
        location = first(allocation.stacktrace)
        for frame in allocation.stacktrace
            if endswith(string(frame.file), "session_query.jl")
                location = frame
                break
            end
        end
        key = string(location.file, ":", location.line, " ", location.func)
        count, bytes = get(sites, key, (0, 0))
        sites[key] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, count=entry[1], bytes=entry[2]) for (site, entry) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(output_directory, prefix * "-allocations.json"),
        JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const baseline_sha = readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"]))
const candidate_sha = readchomp(Cmd(["git", "-C", candidate_directory, "rev-parse", "HEAD"]))
const metadata = (;
    baseline_sha, candidate_sha,
    baseline_file=joinpath(baseline_directory, "src/core/session_query.jl"),
    candidate_file=joinpath(candidate_directory, "src/core/session_query.jl"),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS, architecture=string(Sys.ARCH),
    os=string(Sys.KERNEL), json_version=string(Base.pkgversion(JSON)),
    candidate_project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    manifest_sha256=isfile(joinpath(candidate_directory, "benchmarks/Manifest.toml")) ?
        bytes2hex(sha256(read(joinpath(candidate_directory, "benchmarks/Manifest.toml")))) : nothing,
    paired_samples=7, repetitions_per_pair_side=5, warmup_per_workload_side=3,
    order="AB BA AB BA AB BA AB", confidence="10,000 deterministic paired bootstrap medians",
    fixtures=Dict(name => (sessions=item.sessions, messages_per_session=item.messages,
        repeat_count=item.repeat_count) for (name, item) in fixtures),
    output_contract="full indexed results equal direct persisted search; baseline and candidate serialized output equal"
)
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

# Fail closed on semantic inconsistency, retaining the initialized environment artifact.
for (name, item) in fixtures
    verify_contract(Baseline, item)
    verify_contract(Candidate, item)
end
write(joinpath(output_directory, "contracts.json"), JSON.json((passed=true, queries, fixture_names=collect(keys(fixtures)))))

results = Dict{String,Any}()
for name in sort!(collect(keys(workloads)))
    baseline, candidate, scope = workloads[name]
    expected = baseline()
    actual = candidate()
    isequal(expected, actual) || error("Full output mismatch: " * name)
    for _ in 1:3
        baseline()
        candidate()
    end
    baseline_trials = Any[]
    candidate_trials = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, sample(baseline))
            push!(candidate_trials, sample(candidate))
        else
            push!(candidate_trials, sample(candidate))
            push!(baseline_trials, sample(baseline))
        end
    end
    improvements = [1.0 - candidate_trials[i].median_ns / baseline_trials[i].median_ns for i in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials, paired_improvements=improvements,
        median_improvement=median(improvements), ci95_lower_improvement=lower_confidence(improvements),
        minimum_pair_improvement=minimum(improvements), scope,
        median_baseline_allocated_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        median_candidate_allocated_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        median_baseline_allocations=median(getproperty.(baseline_trials, :allocations)),
        median_candidate_allocations=median(getproperty.(candidate_trials, :allocations)),
        contract="exact serialized output match")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((metadata=metadata, results=results)))
    println(name, ": median improvement=", round(100 * result.median_improvement; digits=2),
        "%, lower95=", round(100 * result.ci95_lower_improvement; digits=2), "%")
    flush(stdout)
end

profile_case(workloads["integration/large-persisted-index-search-json"][1], "baseline-large")
profile_case(workloads["integration/large-persisted-index-search-json"][2], "candidate-large")
profile_case(workloads["secondary/cached-index-query"][1], "baseline-cached")
profile_case(workloads["secondary/cached-index-query"][2], "candidate-cached")

representative = results["integration/large-persisted-index-search-json"]
no_material_regressions = all(result -> result.median_improvement > -0.10, values(results))
accepted = representative.median_improvement >= 0.10 &&
    representative.ci95_lower_improvement > 0.10 && no_material_regressions
write(joinpath(output_directory, "gate.json"), JSON.json((;
    accepted, no_material_regressions,
    representative_median=representative.median_improvement,
    representative_ci95_lower=representative.ci95_lower_improvement,
    baseline_sha, candidate_sha)))
println("PERFORMANCE_GATE=", accepted ? "PASS" : "FAIL")
accepted || error("Isolated performance acceptance gate failed; do not create a PR")
