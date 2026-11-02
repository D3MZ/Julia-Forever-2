using JuliaForever2, BenchmarkTools, JSON, Profile, SHA, Statistics
import Pkg

# The baseline is included as a separate module; its direct dependencies (YAML,
# TreeSitter, etc.) must resolve from the package project, not only benchmarks/.
Pkg.activate(realpath(joinpath(@__DIR__, "..", "..")); io=devnull)

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2
const STAMP = "2026-11-02T06:00:00.000Z"

function push_record!(entries, id, kind, data)
    parent = isempty(entries) ? nothing : last(entries)["id"]
    record = Dict{String,Any}("type" => kind, "id" => id,
        "parentId" => parent, "timestamp" => STAMP)
    merge!(record, data)
    push!(entries, record)
end

"""Build deterministic native message graphs and realistic active-label histories."""
function make_archive(package, messages::Int, revisions::Int, labeled::Bool)
    archive = package.SessionTimeline("/tmp/jf2-label-benchmark";
        id="source-$(messages)-$(revisions)-$(labeled)", timestamp=STAMP)
    entries = Dict{String,Any}[]
    for index in 1:messages
        push_record!(entries, "message-$(lpad(index, 5, '0'))", "message",
            Dict{String,Any}("message" => Dict{String,Any}(
                "role" => isodd(index) ? "user" : "assistant",
                "content" => "Archived Julia work $(index): Unicode 🐱 café; multi-step session",
                "metadata" => Dict("index" => index, "flag" => isodd(index)))))
    end
    if labeled
        for index in 1:messages
            push_record!(entries, "label-$(lpad(index, 5, '0'))", "label",
                Dict{String,Any}("targetId" => "message-$(lpad(index, 5, '0'))",
                    "label" => "Bookmark $(index)"))
        end
        for index in 1:revisions
            target = "message-$(lpad(1 + mod(index * 19, messages), 5, '0'))"
            push_record!(entries, "remove-$(lpad(index, 5, '0'))", "label",
                Dict{String,Any}("targetId" => target,
                    "label" => isodd(index) ? nothing : ""))
            if isodd(index)
                push_record!(entries, "restore-$(lpad(index, 5, '0'))", "label",
                    Dict{String,Any}("targetId" => target,
                        "label" => "Restored bookmark $(index)"))
            end
        end
    end
    archive.entries = entries
    archive.indices = package.timeline_index(entries)
    archive.leaf = last(entries)["id"]
    archive
end

const cases = Dict(
    "large" => (2000, 100, true), "medium" => (800, 35, true),
    "small" => (70, 6, true), "revisions" => (1150, 540, true),
    "mixed" => (1050, 75, true), "no-labels" => (1000, 0, false))
const base_cases = Dict(name => make_archive(Baseline, spec...) for (name, spec) in cases)
const new_cases = Dict(name => make_archive(Candidate, spec...) for (name, spec) in cases)
fixture(package, name) = (package === Baseline ? base_cases : new_cases)[name]

function clone_response(package, name; export_jsonl=false)
    clone = package.timeline_clone(fixture(package, name);
        id="cloned-session", timestamp=STAMP)
    active = package.timeline_labels(clone.entries)
    sorted = sort!(collect(active); by=first)
    exported_bytes = export_jsonl ? ncodeunits(package.timeline_export_jsonl(clone)) : 0
    JSON.json(Dict("id" => clone.identity.id,
        "messages" => count(entry -> entry["type"] == "message", clone.entries),
        "active_labels" => [(first(item), last(item)[1]) for item in sorted],
        "exported_bytes" => exported_bytes))
end

function mixed_response(package)
    clone_summary = JSON.parse(clone_response(package, "mixed"; export_jsonl=true))
    original_jsonl = package.timeline_export_jsonl(fixture(package, "mixed"))
    JSON.json(Dict("clone" => clone_summary, "original_bytes" => ncodeunits(original_jsonl),
        "original_header" => first(split(original_jsonl, '\n'))))
end

direct_order(package, name) = package.timeline_label_order(fixture(package, name).entries)
const control_json = JSON.json(Dict("records" => [
    Dict("id" => index, "text" => "record $(index)", "flag" => isodd(index))
    for index in 1:1900]))
const workloads = [
    (name="integration/large-clone-active-labels-json", primary=true,
        scope="changed: clone a 2,000-message/2,000-label native archive with relabel history and serialize active label view",
        work=package -> clone_response(package, "large")),
    (name="integration/mixed-clone-jsonl-json", primary=false,
        scope="changed/mixed: clone 1,050 messages/labels, export original and clone JSONL, serialize JSON response",
        work=package -> mixed_response(package)),
    (name="integration/medium-clone-json", primary=false,
        scope="changed: clone 800-message/label archive and serialize active labels",
        work=package -> clone_response(package, "medium")),
    (name="secondary/heavy-revisions", primary=false,
        scope="changed: 1,150 labels plus 540 remove/relabel events with clone and JSON",
        work=package -> clone_response(package, "revisions")),
    (name="secondary/small-clone", primary=false,
        scope="changed: clone small 70-message/label archive and serialize JSON",
        work=package -> clone_response(package, "small")),
    (name="diagnostic/direct-active-label-order", primary=false,
        scope="changed: active label ordering alone, diagnostic kernel (not acceptance primary)",
        work=package -> direct_order(package, "large")),
    (name="control/label-free-clone", primary=false,
        scope="empty-label branch: clone 1,000 messages; changed function invoked but skips label handling",
        work=package -> clone_response(package, "no-labels")),
    (name="control/unchanged-json-decoder", primary=false,
        scope="unchanged: standalone JSON parsing without the changed source",
        work=package -> begin
            parsed = JSON.parse(control_json)
            (length(parsed["records"]), parsed["records"][1]["id"],
                parsed["records"][end]["text"])
        end),
]

const baseline_sha = readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"]))
const candidate_sha = readchomp(Cmd(["git", "rev-parse", "HEAD"]))
const environment = Dict(
    "baseline_sha" => baseline_sha, "candidate_sha" => candidate_sha,
    "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
    "cpu" => Sys.CPU_NAME, "logical_cpus" => Sys.CPU_THREADS,
    "architecture" => string(Sys.ARCH), "os" => string(Sys.KERNEL),
    "benchmarktools_version" => string(Base.pkgversion(BenchmarkTools)),
    "json_version" => string(Base.pkgversion(JSON)),
    "source_project_sha256" => bytes2hex(sha256(read("Project.toml"))),
    "baseline_project_sha256" => bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    "benchmark_project_sha256" => bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs" => 7, "samples_per_trial" => 10, "evals" => 1,
    "seconds" => 5.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 paired-bootstrap resamples of seven independent paired trial medians",
    "environment_match" => "same process, machine, package versions, worktrees, Julia version, threads and fixtures",
    "primary_messages" => 2000, "primary_initial_labels" => 2000)
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

baseline_sha == "072eddefbbd6588d7eadcddf1e734e61f1542f0c" ||
    error("Fresh baseline SHA mismatch")
VERSION == v"1.13.3" || error("Pinned Julia 1.13.3 required")
Threads.nthreads() == 2 || error("Expected 2 Julia threads")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Candidate source does not match checkout")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Baseline and candidate packages differ")
isempty(readchomp(Cmd(["git","-C",baseline_directory,"diff","HEAD","--","src"]))) ||
    error("Baseline source worktree has changes")

function canonical_clone(package, archive)
    clone = package.timeline_clone(archive; id="cloned-session", timestamp=STAMP)
    generated = Dict{String,String}()
    for entry in clone.entries
        entry["type"] == "label" &&
            (generated[entry["id"]] = "generated-label-$(length(generated)+1)")
    end
    entries = deepcopy(clone.entries)
    for entry in entries
        entry["id"] = get(generated, entry["id"], entry["id"])
        parent = entry["parentId"]
        !isnothing(parent) && (entry["parentId"] = get(generated, parent, parent))
    end
    (header=package.timeline_header(clone), entries=entries,
        leaf=get(generated, clone.leaf, clone.leaf))
end

function verify_semantics()
    for name in keys(cases)
        base_cases[name].entries == new_cases[name].entries ||
            error("Mismatch between fixture inputs: $name")
        direct_order(Baseline, name) == direct_order(Candidate, name) ||
            error("Active label order differs: $name")
        canonical_clone(Baseline, base_cases[name]) ==
            canonical_clone(Candidate, new_cases[name]) ||
            error("Canonical full clone graph differs: $name")
        JSON.parse(clone_response(Baseline, name)) ==
            JSON.parse(clone_response(Candidate, name)) ||
            error("Cloned JSON differs: $name")
    end
    for workload in workloads
        lhs, rhs = workload.work(Baseline), workload.work(Candidate)
        lhs == rhs || error("Benchmark output contract mismatch: $(workload.name)")
    end
    source_before = deepcopy(new_cases["large"].entries)
    clone_response(Candidate, "large")
    new_cases["large"].entries == source_before ||
        error("Candidate mutated caller-owned source")
    for package in (Baseline, Candidate)
        clone = package.timeline_clone(fixture(package, "small");
            id="cloned-session", timestamp=STAMP)
        restored = package.parse_timeline_jsonl(package.timeline_export_jsonl(clone))
        length(restored.entries) == length(clone.entries) ||
            error("Clone JSONL roundtrip lost entries")
    end
    write(joinpath(evidence_directory, "contracts.json"), JSON.json(Dict(
        "passed" => true, "workloads" => length(workloads), "cases" => length(cases),
        "canonical_full_graph_equal" => true, "active_order_equal" => true,
        "generated_uuid_normalization" => true, "caller_isolation" => true,
        "jsonl_roundtrip" => true)))
end
try
    verify_semantics()
catch failure
    write(joinpath(evidence_directory, "contracts.json"),
        JSON.json(Dict("passed" => false, "error" => sprint(showerror, failure))))
    rethrow()
end

function measured_trial(work)
    benchmark = BenchmarkTools.@benchmarkable $(work)() samples=10 evals=1 seconds=5.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(benchmark)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

function paired_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    medians = Float64[]
    for _ in 1:20000
        draw = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(draw))
    end
    (lower=quantile(medians, 0.025), upper=quantile(medians, 0.975))
end

function profile_work(work, name)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:6
        work()
    end
    open(joinpath(evidence_directory, name * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.02 work()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(item -> !isempty(item.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "session_timeline.jl")
                frame = location
                break
            end
        end
        key = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, key, (0, 0))
        sites[key] = (old[1]+1, old[2]+allocation.size)
    end
    rows = [Dict("site" => key, "count" => value[1], "bytes" => value[2])
        for (key, value) in sites]
    sort!(rows; by=row -> row["bytes"], rev=true)
    write(joinpath(evidence_directory, name * "-allocation-sites.json"),
        JSON.json(Dict("sample_rate" => 0.02, "sites" => first(rows, min(200,length(rows))))))
    Profile.Allocs.clear()
end

const results = Dict{String,Any}()
for workload in workloads
    base_work = () -> workload.work(Baseline)
    new_work = () -> workload.work(Candidate)
    for _ in 1:4
        base_work()
        new_work()
    end
    pairs = Any[]
    for index in 1:7
        GC.gc()
        if isodd(index)
            a = measured_trial(base_work)
            b = measured_trial(new_work)
        else
            b = measured_trial(new_work)
            a = measured_trial(base_work)
        end
        push!(pairs, Dict("pair" => index,
            "first" => isodd(index) ? "baseline" : "candidate",
            "baseline" => a, "candidate" => b))
    end
    gains = [1.0 - pair["candidate"]["median_ns"]/pair["baseline"]["median_ns"]
        for pair in pairs]
    interval = paired_confidence(gains)
    results[workload.name] = Dict("scope" => workload.scope,
        "primary" => workload.primary, "pairs" => pairs,
        "paired_improvements" => gains, "median_improvement" => median(gains),
        "confidence_lower" => interval.lower, "confidence_upper" => interval.upper)
    write(joinpath(evidence_directory, "raw-trials.json"),
        JSON.json(Dict("environment" => environment, "workloads" => results)))
    println(workload.name, " median ", round(100*median(gains); digits=2),
        "% lower95 ", round(100*interval.lower; digits=2), "%")
    flush(stdout)
end

profile_work(() -> clone_response(Baseline, "large"), "baseline")
profile_work(() -> clone_response(Candidate, "large"), "candidate")
const primary = results["integration/large-clone-active-labels-json"]
const passed = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory, "gate.json"), JSON.json(Dict(
    "passed" => passed, "primary_median" => primary["median_improvement"],
    "primary_lower95" => primary["confidence_lower"],
    "criterion" => "Primary median >=10%, 95% confidence lower >10%, no >=10% secondary slowdown, exact semantics",
    "slowdowns" => [Dict("workload" => name,
        "median_improvement" => row["median_improvement"])
        for (name,row) in results if row["median_improvement"] < 0])))
passed || error("Experimental gate FAILED; no pull request")
