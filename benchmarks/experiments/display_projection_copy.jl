using JuliaForever2, BenchmarkTools, JSON, Statistics, SHA, Profile

length(ARGS) == 2 || error("Expected baseline worktree and evidence directory")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

"""Rich deterministic archived message histories with active and inactive branches."""
function fixture(count::Int, active::Int; null_at::Int=0)
    entries = Dict{String,Any}[]
    for index in 1:count
        parent = index == 1 ? nothing :
            index <= active ? "entry-$(index - 1)" : "entry-$active"
        text = repeat(isodd(index) ?
            "Assistant thinking, tool output and provenance for session display. " :
            "User prompts, Unicode λ and structured history context for display. ", 7)
        blocks = index == null_at ? nothing : Any[
            Dict("type" => "text", "text" => text),
            Dict("type" => "text", "text" => text * string(index))]
        metadata = Dict("trace" => [Dict("step" => step,
                "attrs" => Dict("sequence" => index, "flags" => Any[true, false],
                    "provider" => "synthetic")) for step in 1:5],
            "source" => Dict("kind" => "session", "version" => 3))
        push!(entries, Dict{String,Any}(
            "type" => "message", "id" => "entry-$index",
            "parentId" => parent, "timestamp" => "2026-11-02T00:00:00.000Z",
            "message" => Dict{String,Any}(
                "role" => isodd(index) ? "user" : "assistant",
                "content" => blocks),
            "metadata" => metadata))
    end
    (; entries, count, active, leaf = "entry-$active", json = JSON.json(entries))
end

const full = fixture(1250, 1250)
const branched = fixture(1500, 420)
const medium = fixture(560, 560)
const small = fixture(64, 64)
const legacy = fixture(180, 180; null_at=80)

"""Full display projection, record presentation and API-style JSON output."""
function display_response(package, item; mode=:pi)
    projection = package.timeline_display_projection(item.entries; leaf=item.leaf, mode)
    view = package.timeline_display_records(projection)
    JSON.json(Dict(
        "entries" => length(projection.entries),
        "items" => [Dict("id" => record.item.source_entry_id,
            "kind" => String(record.item.kind),
            "payload" => record.item.payload,
            "visible" => record.visible,
            "presentation" => String(record.presentation)) for record in view.records],
        "tools" => length(view.tools),
        "mode" => String(projection.mode)))
end

"""Mixed transcript display, model-context projection and serialized response."""
function mixed_response(package)
    display = package.timeline_display_projection(medium.entries; leaf=medium.leaf)
    records = package.timeline_display_records(display)
    context = package.timeline_projection(small.entries; leaf=small.leaf)
    JSON.json(Dict(
        "display" => [Dict("id" => record.item.source_entry_id,
            "payload" => record.item.payload,
            "visible" => record.visible) for record in records.records],
        "messages" => package.timeline_llm_messages(context),
        "thinking" => context.thinking_level,
        "tools" => length(records.tools)))
end

"""Unchanged model-context selection control: this does not call display projection."""
function context_control(package)
    projection = package.timeline_projection(medium.entries; leaf=medium.leaf)
    JSON.json(Dict("messages" => package.timeline_llm_messages(projection),
        "thinking" => projection.thinking_level))
end

"""Unchanged JSON decoder control: no source under modification is exercised."""
function json_control(package)
    result = JSON.parse(full.json)
    (length(result), result[1]["id"], result[end]["id"])
end

const workloads = [
    ("integration/full-display-to-json",
        package -> display_response(package, full; mode=:archive),
        "changed: 1250 entries, full display, record mapping and JSON", true),
    ("integration/branched-display-to-json",
        package -> display_response(package, branched),
        "changed: 1500 archived entries, 420 visible in selected branch", false),
    ("integration/medium-display-to-json",
        package -> display_response(package, medium),
        "changed: 560 active entries, display and JSON", false),
    ("integration/mixed-display-context",
        package -> mixed_response(package),
        "changed: display projection mixed with unchanged context projection and JSON", false),
    ("secondary/small-display",
        package -> display_response(package, small),
        "changed: small display projection", false),
    ("secondary/legacy-null-display",
        package -> display_response(package, legacy),
        "changed: legacy content repair during display projection", false),
    ("control/unchanged-context",
        package -> context_control(package),
        "unchanged: context projection and JSON without display projection", false),
    ("control/unchanged-json-decoder",
        package -> json_control(package),
        "unchanged: JSON parsing without display projection", false),
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
    "pairs" => 7, "samples_per_trial" => 16, "evals" => 1,
    "seconds" => 5.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 deterministic paired-trial bootstrap median resamples",
    "environment_match" => "same process, Julia packages, runner, threads, and fixtures",
    "fixtures" => Dict("full" => [full.count, full.active],
        "branched" => [branched.count, branched.active],
        "medium" => [medium.count, medium.active],
        "small" => [small.count, small.active]))
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))
baseline_sha == "9c87b78f717b52a505eddee0dc7737bace0d0ff2" ||
    error("Baseline is not the fresh pinned main")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Baseline and candidate dependency declarations differ")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Loaded JuliaForever2 is not the checked-out candidate")
isempty(readchomp(Cmd(["git", "-C", baseline_directory, "diff", "HEAD", "--", "src"]))) ||
    error("Baseline source tree has uncommitted changes")

"""Verify semantic equivalence, caller ownership and internal display isolation."""
function verify()
    for (name, work, _, _) in workloads
        baseline = work(Baseline)
        candidate = work(Candidate)
        equal = baseline isa AbstractString && candidate isa AbstractString ?
            isequal(JSON.parse(baseline), JSON.parse(candidate)) :
            isequal(baseline, candidate)
        equal || error("Semantic output mismatch: $name")
    end
    original = deepcopy(full.entries)
    projected = Candidate.timeline_display_projection(full.entries;
        leaf=full.leaf, mode=:archive)
    isequal(original, full.entries) || error("Display projection mutated caller")
    projected.entries[1]["message"]["content"][1]["text"] = "mutated entry"
    isequal(original, full.entries) || error("Projected source aliases caller")
    projected.items[1].payload["content"][1]["text"] == "mutated entry" &&
        error("Display items alias raw projected entries")
    projected.items[2].payload["content"][1]["text"] = "mutated item"
    projected.entries[2]["message"]["content"][1]["text"] == "mutated item" &&
        error("Projected raw entries alias display items")
    isequal(original, full.entries) || error("Projected display item aliases caller")
    repaired = Candidate.timeline_display_projection(legacy.entries; leaf=legacy.leaf)
    isempty(repaired.items[80].payload["content"]) ||
        error("Legacy null-content display was not repaired")
    isnothing(legacy.entries[80]["message"]["content"]) ||
        error("Legacy repair mutated original input")
    write(joinpath(evidence_directory, "contracts.json"),
        JSON.json(Dict("passed" => true, "workloads" => length(workloads),
            "semantic_outputs_equal" => true, "caller_isolation" => true,
            "internal_projection_isolation" => true,
            "legacy_repair_compatibility" => true)))
end
verify()

"""Use BenchmarkTools for all timing, allocation and GC trial measurements."""
function measured_trial(work)
    case = BenchmarkTools.@benchmarkable $(work)() samples=16 evals=1 seconds=5.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(case)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

"""Bootstrap the independent paired-trial medians, not individual benchmark samples."""
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

"""Capture CPU and sampled allocation call stacks outside timed BenchmarkTools trials."""
function profile_work(work, tag)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:5
        work()
    end
    open(joinpath(evidence_directory, tag * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 work()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(a -> !isempty(a.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        location = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, location, (0, 0))
        sites[location] = (old[1] + 1, old[2] + allocation.size)
    end
    rows = [Dict("location" => name, "count" => value[1], "bytes" => value[2])
        for (name, value) in sites]
    sort!(rows; by=row -> row["bytes"], rev=true)
    write(joinpath(evidence_directory, tag * "-allocations.json"),
        JSON.json(Dict("sample_rate" => 0.05,
            "sites" => first(rows, min(length(rows), 150)))))
    Profile.Allocs.clear()
end

const results = Dict{String,Any}()
for (name, work, scope, primary) in workloads
    baseline_work = () -> work(Baseline)
    candidate_work = () -> work(Candidate)
    for _ in 1:4
        baseline_work()
        candidate_work()
    end
    pairs = Any[]
    for pair in 1:7
        GC.gc()
        if isodd(pair)
            baseline_result = measured_trial(baseline_work)
            candidate_result = measured_trial(candidate_work)
        else
            candidate_result = measured_trial(candidate_work)
            baseline_result = measured_trial(baseline_work)
        end
        push!(pairs, Dict(
            "pair" => pair, "first" => isodd(pair) ? "baseline" : "candidate",
            "baseline" => baseline_result, "candidate" => candidate_result))
    end
    improvements = [1.0 - item["candidate"]["median_ns"] / item["baseline"]["median_ns"]
        for item in pairs]
    confidence = paired_confidence(improvements)
    results[name] = Dict(
        "scope" => scope, "primary" => primary, "pairs" => pairs,
        "paired_improvements" => improvements,
        "median_improvement" => median(improvements),
        "confidence_lower" => confidence.lower,
        "confidence_upper" => confidence.upper)
    write(joinpath(evidence_directory, "raw-trials.json"),
        JSON.json(Dict("environment" => environment, "workloads" => results)))
    println(name, ": improvement=", round(100 * median(improvements); digits=2),
        "%; lower95=", round(100 * confidence.lower; digits=2), "%")
    flush(stdout)
end

profile_work(() -> display_response(Baseline, full; mode=:archive), "baseline")
profile_work(() -> display_response(Candidate, full; mode=:archive), "candidate")
const primary_result = results["integration/full-display-to-json"]
const accepted = primary_result["median_improvement"] >= 0.10 &&
    primary_result["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory, "gate.json"), JSON.json(Dict(
    "passed" => accepted, "primary_improvement" => primary_result["median_improvement"],
    "primary_lower95" => primary_result["confidence_lower"],
    "criterion" => "primary median >=10%; paired-bootstrap lower95 >10%; all secondary medians >-10%; exact semantic contract",
    "regressions" => [Dict("workload" => name, "improvement" => row["median_improvement"])
        for (name, row) in results if row["median_improvement"] < 0])))
accepted || error("Performance acceptance gate failed; do not create a PR")
