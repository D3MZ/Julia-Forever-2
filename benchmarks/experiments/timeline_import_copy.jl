using JuliaForever2, JSON, Statistics, SHA, Profile

length(ARGS) == 2 || error("Expected baseline worktree and evidence directory")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

function fixture(count, id)
    directory = mktempdir()
    header = Dict{String,Any}("type"=>"session", "version"=>3,
        "id"=>id, "cwd"=>abspath(pwd()),
        "timestamp"=>"2026-11-01T20:00:00.000Z")
    entries = Dict{String,Any}[]
    parent = nothing
    for index in 1:count
        entry_id = "entry-" * string(index)
        content = repeat(isodd(index) ?
            "Persistent session reasoning and tool result λ. " :
            "Conversation context with nested metadata 🚀. ", 8)
        blocks = Any[
            Dict("type"=>"text", "text"=>content),
            Dict("type"=>"text", "text"=>content * " suffix " * string(index))]
        metadata = Dict("trace"=>[Dict("step"=>step, "flags"=>Any[true, false],
            "attrs"=>Dict("sequence"=>index, "provider"=>"synthetic"))
            for step in 1:4],
            "opaque"=>Dict("a"=>[index, index + 1], "b"=>"preserved"))
        push!(entries, Dict{String,Any}("type"=>"message", "id"=>entry_id,
            "parentId"=>parent, "timestamp"=>"2026-11-01T20:00:00.000Z",
            "message"=>Dict("role"=>"assistant", "content"=>blocks),
            "metadata"=>metadata))
        parent = entry_id
    end
    data = Dict("format"=>"JuliaForever2.timeline", "version"=>1,
        "header"=>header, "entries"=>entries, "leaf"=>parent)
    native = JSON.json(data) * "\n"
    write(joinpath(directory, id * ".timeline.json"), native)
    rows = Any[header; entries]
    jsonl = join(JSON.json.(rows), "\n") * "\n"
    (; directory, id, count, native, rows, jsonl)
end

const large = fixture(1800, "timeline-large")
const medium = fixture(520, "timeline-medium")
const small = fixture(72, "timeline-small")
const fixtures = (large, medium, small)

function response(package, timeline, count)
    sampled = [package.timeline_entry(timeline, "entry-" * string(index))
        for index in (1, cld(count, 2), count)]
    JSON.json(Dict("session"=>timeline.identity.id,
        "entries"=>length(timeline.indices), "leaf"=>package.timeline_leaf(timeline),
        "sampled"=>sampled))
end
function persisted(package, item)
    timeline = package.load_timeline(package.TimelineStore(item.directory), item.id)
    response(package, timeline, item.count)
end
function jsonl_import(package, item)
    timeline = package.parse_timeline_jsonl(item.jsonl)
    response(package, timeline, item.count)
end
function from_rows(package, item)
    timeline = package.timeline_from_rows(item.rows)
    response(package, timeline, item.count)
end
function mixed(package)
    native = package.load_timeline(package.TimelineStore(medium.directory), medium.id)
    restored = package.parse_timeline_jsonl(small.jsonl)
    branch = package.timeline_branch(restored)
    JSON.json(Dict("main"=>response(package, native, medium.count),
        "other"=>response(package, restored, small.count),
        "branch_size"=>length(branch),
        "last_text"=>last(branch)["message"]["content"][1]["text"]))
end
function decoder_control(package)
    decoded = JSON.parse(large.native)
    (length(decoded["entries"]), decoded["header"]["id"],
        last(decoded["entries"])["id"])
end
const baseline_prebuilt = Baseline.timeline_from_rows(medium.rows)
const candidate_prebuilt = Candidate.timeline_from_rows(medium.rows)
function branch_control(package)
    timeline = package === Baseline ? baseline_prebuilt : candidate_prebuilt
    branch = package.timeline_branch(timeline)
    (length(branch), first(branch)["id"], last(branch)["id"])
end

const workloads = [
    ("integration/persisted-reload-large-json", p -> persisted(p, large),
        "changed: native disk load, JSON parse, timeline migration and API JSON response"),
    ("integration/persisted-reload-medium-json", p -> persisted(p, medium),
        "changed: medium native persisted load and API JSON response"),
    ("integration/persisted-reload-small-json", p -> persisted(p, small),
        "changed: small native persisted load and API JSON response"),
    ("integration/jsonl-import-medium-json", p -> jsonl_import(p, medium),
        "changed: JSONL decode, graph validation, API JSON response"),
    ("integration/mixed-native-jsonl-branch", p -> mixed(p),
        "changed: mixed persisted load, JSONL import, branch projection"),
    ("secondary/preparsed-rows-large-json", p -> from_rows(p, large),
        "changed: direct row migration and ownership copy cost"),
    ("control/unchanged-native-json-decoder", p -> decoder_control(p),
        "unchanged: plain JSON decoding only"),
    ("control/unchanged-prebuilt-branch", p -> branch_control(p),
        "unchanged: branch snapshot on preconstructed sessions")
]

const baseline_sha = readchomp(Cmd(["git","-C",baseline_directory,"rev-parse","HEAD"]))
const candidate_sha = readchomp(Cmd(["git","rev-parse","HEAD"]))
const environment = (;
    baseline_sha, candidate_sha, julia_version=string(VERSION),
    threads=Threads.nthreads(), cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    os=string(Sys.KERNEL), arch=string(Sys.ARCH),
    json_version=string(Base.pkgversion(JSON)),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    candidate_project_sha256=bytes2hex(sha256(read("Project.toml"))),
    benchmark_project_sha256=bytes2hex(sha256(read("benchmarks/Project.toml"))),
    manifest_sha256=isfile("Manifest.toml") ? bytes2hex(sha256(read("Manifest.toml"))) : nothing,
    pairs=7, repetitions_per_side=5, warmups_per_side=4, order="AB BA AB BA AB BA AB",
    confidence="15000 deterministic paired-median bootstrap draws, 2.5% quantile",
    fixture_sizes=Dict(item.id=>item.count for item in fixtures),
    environment_match="same Julia process, inputs, packages, machine, threads, warmed-up operations"
)
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

function verify(package)
    for item in fixtures
        loaded = package.load_timeline(package.TimelineStore(item.directory), item.id)
        jsonl = package.parse_timeline_jsonl(item.jsonl)
        rows = package.timeline_from_rows(item.rows)
        actual = package.timeline_entries(loaded)
        isequal(actual, package.timeline_entries(jsonl)) ||
            error("Native/JSONL semantics differ for " * item.id)
        isequal(actual, package.timeline_entries(rows)) ||
            error("Native/rows semantics differ for " * item.id)
        length(actual) == item.count || error("Session entry count mismatch")
        isequal(actual, package.timeline_branch(loaded)) ||
            error("Persisted active branch mismatch")
    end
    external = deepcopy(small.rows)
    owned = package.timeline_from_rows(external)
    external[2]["message"]["content"][1]["text"] = "caller mutation"
    entry = package.timeline_entry(owned, "entry-1")
    entry["message"]["content"][1]["text"] != "caller mutation" ||
        error("Imported timeline retains caller-owned payload")
    entry["message"]["content"][1]["text"] = "accessor mutation"
    package.timeline_entry(owned, "entry-1")["message"]["content"][1]["text"] !=
        "accessor mutation" || error("Entry accessor leaks internal storage")
    legacy = deepcopy(small.rows)
    legacy[1]["version"] = 2
    package.timeline_from_rows(legacy).identity.fields["version"] == 3 ||
        error("Legacy migration did not normalize the version")
    nothing
end
verify(Baseline)
verify(Candidate)
for (name, work, _) in workloads
    isequal(work(Baseline), work(Candidate)) ||
        error("Initial output contract mismatch: " * name)
end
write(joinpath(evidence_directory, "contracts.json"), JSON.json(
    (passed=true, native_jsonl_rows_match=true, defensive_copy=true,
    accessor_isolation=true, legacy_version_two=true, all_workloads_equal=true)))

function trial(f)
    GC.gc()
    durations = Int[]
    for _ in 1:5
        start = time_ns()
        f()
        push!(durations, time_ns()-start)
    end
    (times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end
function lower_confidence(gains)
    state = UInt64(0x7c7adec033d551fa)
    medians = Float64[]
    for _ in 1:15000
        values = Float64[]
        for _ in eachindex(gains)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(values, gains[Int(mod(state, UInt64(length(gains))))+1])
        end
        push!(medians, median(values))
    end
    quantile(medians, 0.025)
end

const results = Dict{String,Any}()
for (name, work, scope) in workloads
    before = () -> work(Baseline)
    after = () -> work(Candidate)
    for _ in 1:4
        before()
        after()
    end
    original = Any[]
    optimized = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(original, trial(before))
            push!(optimized, trial(after))
        else
            push!(optimized, trial(after))
            push!(original, trial(before))
        end
    end
    isequal(before(), after()) || error("Post-run output mismatch: " * name)
    gains = [1 - optimized[i].median_ns/original[i].median_ns for i in 1:7]
    result = (; baseline=original, candidate=optimized, paired_gains=gains,
        median_improvement=median(gains), lower95=lower_confidence(gains),
        median_baseline_bytes=median(getproperty.(original, :allocated_bytes)),
        median_candidate_bytes=median(getproperty.(optimized, :allocated_bytes)),
        median_baseline_allocations=median(getproperty.(original, :allocation_count)),
        median_candidate_allocations=median(getproperty.(optimized, :allocation_count)),
        scope, contract="exact output matches before/after warm paired samples")
    results[name] = result
    write(joinpath(evidence_directory, "raw-pairs.json"), JSON.json((environment, results)))
    println(name, ": median=", round(100*result.median_improvement; digits=2),
        "% lower95=", round(100*result.lower95; digits=2), "%")
    flush(stdout)
end
function profile_case(f, label)
    f()
    Profile.clear()
    Profile.@profile begin
        until = time_ns() + 300_000_000
        while time_ns() < until
            f()
        end
    end
    open(joinpath(evidence_directory, label * "-cpu.txt"), "w") do output
        Profile.print(output; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    allocations = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        if !isempty(allocation.stacktrace)
            index = findfirst(frame -> endswith(string(frame.file), "session_timeline.jl"),
                allocation.stacktrace)
            frame = allocation.stacktrace[isnothing(index) ? 1 : index]
            label = string(frame.file, ":", frame.line, " ", frame.func)
            count, bytes = get(allocations, label, (0, 0))
            allocations[label] = (count+1, bytes+allocation.size)
        end
    end
    ranked = [(site=label, count=value[1], bytes=value[2])
        for (label, value) in allocations]
    sort!(ranked; by=record -> record.bytes, rev=true)
    write(joinpath(evidence_directory, label * "-allocations.json"),
        JSON.json((sample_rate=0.05, sites=ranked)))
    Profile.Allocs.clear()
end
profile_case(() -> persisted(Baseline, large), "baseline-persisted")
profile_case(() -> persisted(Candidate, large), "candidate-persisted")
profile_case(() -> from_rows(Baseline, large), "baseline-rows")
profile_case(() -> from_rows(Candidate, large), "candidate-rows")

primary = results["integration/persisted-reload-large-json"]
regressions = [(name, record.median_improvement)
    for (name, record) in results if record.median_improvement <= -0.10]
passed = primary.median_improvement >= 0.10 && primary.lower95 > 0.10 &&
    isempty(regressions)
write(joinpath(evidence_directory, "gate.json"), JSON.json((;
    passed, semantic_contracts=true, representative="integration/persisted-reload-large-json",
    primary_median=primary.median_improvement, primary_lower95=primary.lower95,
    regressions, baseline_sha, candidate_sha)))
println("PERFORMANCE_GATE=", passed ? "PASS" : "FAIL")
passed || error("Isolated performance gate failed; do not create a PR")
