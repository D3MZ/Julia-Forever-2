using JuliaForever2, BenchmarkTools, JSON, SHA, Statistics, Profile

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

"""Synthetic but valid v3 session archives with opaque nested payloads."""
function fixture(count::Int, active::Int)
    timestamp = "2026-11-02T00:00:00.000Z"
    header = Dict{String,Any}("type" => "session", "version" => 3,
        "id" => "benchmark-$(count)-$(active)", "cwd" => pwd(),
        "timestamp" => timestamp, "unknownHeader" => Dict("origin" => "benchmark"))
    entries = Dict{String,Any}[]
    for index in 1:count
        parent = index == 1 ? nothing :
            index == active + 1 && active < count ? "entry-$(div(active, 2))" :
            "entry-$(index - 1)"
        paragraph = repeat(isodd(index) ?
            "Unicode λ, session history, escaped quotes \" and backslash \\. " :
            "Assistant tool output and structured display payload. ", 12)
        message = Dict{String,Any}("role" => isodd(index) ? "user" : "assistant",
            "content" => Any[Dict("type" => "text", "text" => paragraph),
                Dict("type" => "text", "text" => paragraph * string(index))])
        opaque = Dict("trace" => [Dict("index" => step, "values" => Any[true, false, index],
                "details" => Dict("provider" => "local", "kind" => "fixture"))
            for step in 1:4], "labels" => Any["alpha", "βeta"])
        push!(entries, Dict{String,Any}("id" => "entry-$index",
            "parentId" => parent, "timestamp" => timestamp, "type" => "message",
            "message" => message, "opaque" => opaque))
    end
    (; header, entries, active, count, leaf = "entry-$active")
end

const fixtures = Dict(
    "large" => fixture(1100, 1100),
    "branched" => fixture(1600, 440),
    "medium" => fixture(420, 420),
    "small" => fixture(36, 36),
    "mixed" => fixture(240, 240))
const baseline_timelines = Dict(key =>
    Baseline.timeline_from_rows([item.header; item.entries]; leaf=item.leaf)
    for (key, item) in fixtures)
const candidate_timelines = Dict(key =>
    Candidate.timeline_from_rows([item.header; item.entries]; leaf=item.leaf)
    for (key, item) in fixtures)
get_timeline(package, key) = package === Baseline ?
    baseline_timelines[key] : candidate_timelines[key]
exported(package, key) =
    package.timeline_export_jsonl(get_timeline(package, key))

const reference_jsonl = exported(Baseline, "medium")
const reference_json = JSON.json(fixtures["large"].entries)
const workloads = [
    ("integration/large-jsonl-export", package -> exported(package, "large"),
        "changed: full 1100-entry active branch to complete interoperable JSONL", true),
    ("integration/medium-jsonl-export", package -> exported(package, "medium"),
        "changed: 420-entry export including header and nested opaque metadata", false),
    ("integration/branched-jsonl-export", package -> exported(package, "branched"),
        "changed: select 440-entry branch from 1600-entry archive and rewrite lineage", false),
    ("integration/export-import-roundtrip", package -> begin
        recovered = package.parse_timeline_jsonl(exported(package, "medium"))
        JSON.json(Dict("entries" => length(recovered.entries), "leaf" => recovered.leaf,
            "id" => recovered.identity.id))
    end, "changed: export followed by unchanged JSONL parsing, validation and response", false),
    ("integration/mixed-export-display", package -> begin
        text = exported(package, "medium")
        display = package.timeline_display_projection(
            package.timeline_entries(get_timeline(package, "mixed")); mode=:archive)
        JSON.json(Dict("jsonl_sha256" => bytes2hex(sha256(text)),
            "display_entries" => length(display.entries),
            "display_items" => length(display.items)))
    end, "changed: export plus unchanged display projection and JSON response", false),
    ("secondary/small-jsonl-export", package -> exported(package, "small"),
        "changed: short 36-entry export", false),
    ("control/unchanged-jsonl-import", package -> begin
        parsed = package.parse_timeline_jsonl(reference_jsonl)
        (length(parsed.entries), parsed.leaf, parsed.identity.id)
    end, "unchanged: parser/importer, never invokes the modified exporter", false),
    ("control/unchanged-json-decoder", package -> begin
        entries = JSON.parse(reference_json)
        (length(entries), entries[1]["id"], entries[end]["id"])
    end, "unchanged: JSON decoder without modified exporter", false),
]

const baseline_sha = readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"]))
const candidate_sha = readchomp(Cmd(["git", "rev-parse", "HEAD"]))
const environment = Dict(
    "baseline_sha" => baseline_sha, "candidate_sha" => candidate_sha,
    "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
    "cpu" => Sys.CPU_NAME, "logical_cpus" => Sys.CPU_THREADS,
    "arch" => string(Sys.ARCH), "os" => string(Sys.KERNEL),
    "benchmarktools_version" => string(Base.pkgversion(BenchmarkTools)),
    "json_version" => string(Base.pkgversion(JSON)),
    "baseline_project_sha256" => bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    "candidate_project_sha256" => bytes2hex(sha256(read("Project.toml"))),
    "benchmark_project_sha256" => bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs" => 7, "samples_per_trial" => 12, "evals" => 1,
    "seconds" => 5.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 deterministic paired-trial bootstrap median resamples",
    "environment_match" => "same Julia process, packages, runner, threads, fixtures",
    "fixtures" => Dict(key => [item.count, item.active] for (key, item) in fixtures))
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

baseline_sha == "4b4d586f674694bb4110f9c283bb89878343ae8a" ||
    error("Baseline is not fresh pinned main")
VERSION == v"1.13.3" || error("Julia version is not pinned to 1.13.3")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Baseline and candidate dependency declarations differ")
# The CI runner adds the package's direct source dependencies to this ephemeral
# benchmark environment so an independently included baseline can import them.
# Both variants still run in this same resolved environment.
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Loaded candidate does not match checked-out repository")
isempty(readchomp(Cmd(["git", "-C", baseline_directory, "diff", "HEAD", "--", "src"]))) ||
    error("Baseline has uncommitted source changes")

function canonical(value)
    if value isa AbstractString
        lines = split(chomp(value), '\n')
        return length(lines) > 1 ? [JSON.parse(line) for line in lines] : JSON.parse(value)
    end
    value
end

"""Check actual JSONL semantics, branch flattening, unchanged inputs and API contracts."""
function verify()
    for (name, work, _, _) in workloads
        left = canonical(work(Baseline))
        right = canonical(work(Candidate))
        isequal(left, right) || error("Output contract failed for $name")
    end
    timeline = get_timeline(Candidate, "large")
    original = deepcopy(timeline.entries)
    first_export = exported(Candidate, "large")
    first_export == exported(Candidate, "large") ||
        error("Repeated exports are not byte-stable")
    isequal(original, timeline.entries) || error("JSONL export modified caller archive")
    restored = Candidate.parse_timeline_jsonl(first_export)
    length(restored.entries) == 1100 || error("JSONL round-trip dropped entries")
    restored.leaf == "entry-1100" || error("JSONL round-trip changed active leaf")
    for (index, entry) in enumerate(restored.entries)
        entry["parentId"] == (index == 1 ? nothing : "entry-$(index - 1)") ||
            error("Exported parent chain is not linear")
        isequal(entry["opaque"], original[index]["opaque"]) ||
            error("Exporter changed opaque metadata")
    end
    branch = Candidate.parse_timeline_jsonl(exported(Candidate, "branched"))
    length(branch.entries) == 440 || error("Export selected incorrect branch")
    try
        Candidate.timeline_export_jsonl(timeline; leaf="missing-leaf")
        error("Unknown export leaf was accepted")
    catch e
        occursin("Unknown branch entry", sprint(showerror, e)) || rethrow()
    end
    write(joinpath(evidence_directory, "contracts.json"), JSON.json(Dict(
        "passed" => true, "workloads" => length(workloads),
        "semantic_outputs_equal" => true, "caller_archive_unchanged" => true,
        "export_determinism" => true, "roundtrip_and_lineage" => true,
        "unknown_leaf_rejected" => true)))
end
verify()

"""Run the BenchmarkTools engine, keeping every sample and GC measurement."""
function measured_trial(work)
    case = BenchmarkTools.@benchmarkable $(work)() samples=12 evals=1 seconds=5.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(case)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

"""Resample paired trial medians rather than treating within-trial samples as independent."""
function paired_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    medians = Float64[]
    for _ in 1:20000
        drawn = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(drawn, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(drawn))
    end
    (lower=quantile(medians, 0.025), upper=quantile(medians, 0.975))
end

"""Profile outside timed BenchmarkTools trials."""
function profile_work(work, tag)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:6
        work()
    end
    open(joinpath(evidence_directory, tag * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.025 work()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(a -> !isempty(a.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "session_timeline.jl")
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, site, (0, 0))
        sites[site] = (old[1] + 1, old[2] + allocation.size)
    end
    rows = [Dict("location" => name, "count" => value[1], "bytes" => value[2])
        for (name, value) in sites]
    sort!(rows; by=row -> row["bytes"], rev=true)
    write(joinpath(evidence_directory, tag * "-allocations.json"),
        JSON.json(Dict("sample_rate" => 0.025,
            "sites" => first(rows, min(length(rows), 150)))))
    Profile.Allocs.clear()
end

const results = Dict{String,Any}()
for (name, work, scope, primary) in workloads
    base_work = () -> work(Baseline)
    candidate_work = () -> work(Candidate)
    for _ in 1:4
        base_work()
        candidate_work()
    end
    pairs = Any[]
    for pair in 1:7
        GC.gc()
        if isodd(pair)
            base_trial = measured_trial(base_work)
            candidate_trial = measured_trial(candidate_work)
        else
            candidate_trial = measured_trial(candidate_work)
            base_trial = measured_trial(base_work)
        end
        push!(pairs, Dict("pair" => pair,
            "first" => isodd(pair) ? "baseline" : "candidate",
            "baseline" => base_trial, "candidate" => candidate_trial))
    end
    improvements = [1.0 - row["candidate"]["median_ns"] / row["baseline"]["median_ns"]
        for row in pairs]
    interval = paired_confidence(improvements)
    results[name] = Dict("scope" => scope, "primary" => primary,
        "pairs" => pairs, "paired_improvements" => improvements,
        "median_improvement" => median(improvements),
        "confidence_lower" => interval.lower, "confidence_upper" => interval.upper)
    write(joinpath(evidence_directory, "raw-trials.json"),
        JSON.json(Dict("environment" => environment, "workloads" => results)))
    println(name, ": median improvement=", round(100 * median(improvements); digits=2),
        "%, lower95=", round(100 * interval.lower; digits=2), "%")
    flush(stdout)
end

profile_work(() -> exported(Baseline, "large"), "baseline")
profile_work(() -> exported(Candidate, "large"), "candidate")
const primary = results["integration/large-jsonl-export"]
const accepted = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory, "gate.json"), JSON.json(Dict(
    "passed" => accepted,
    "primary_improvement" => primary["median_improvement"],
    "primary_lower95" => primary["confidence_lower"],
    "criterion" => "primary >=10% and lower95 >10%; secondary slowdowns <10%; exact semantic contract",
    "slowdowns" => [Dict("workload" => name, "improvement" => row["median_improvement"])
        for (name, row) in results if row["median_improvement"] < 0])))
accepted || error("Performance acceptance gate FAILED: no pull request")
