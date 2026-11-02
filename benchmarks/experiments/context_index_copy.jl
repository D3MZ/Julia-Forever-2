using JuliaForever2, BenchmarkTools, JSON, Statistics, SHA, Profile

length(ARGS) == 2 || error("Expected baseline worktree and evidence directory")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

"""Deterministic rich Pi timelines, with inactive branches and legacy null entries."""
function fixture(count::Int, active::Int; null_at::Int=0)
    entries = Dict{String,Any}[]
    for index in 1:count
        parent = index == 1 ? nothing :
            index <= active ? "entry-" * string(index - 1) : "entry-" * string(active)
        text = repeat(isodd(index) ?
            "Assistant reasoning, tool calls and timeline provenance. " :
            "User prompts, Unicode λ and structured history context. ", 7)
        blocks = index == null_at ? nothing : Any[
            Dict("type"=>"text", "text"=>text),
            Dict("type"=>"text", "text"=>text * string(index))]
        metadata = Dict("trace"=>[Dict("step"=>step,
                "attrs"=>Dict("sequence"=>index,"flags"=>Any[true,false],"provider"=>"synthetic"))
                for step in 1:5],
            "source"=>Dict("kind"=>"session","version"=>3))
        push!(entries, Dict{String,Any}(
            "type"=>"message","id"=>"entry-" * string(index),
            "parentId"=>parent,"timestamp"=>"2026-11-01T20:00:00.000Z",
            "message"=>Dict{String,Any}("role"=>isodd(index) ? "user" : "assistant",
                "content"=>blocks),"metadata"=>metadata))
    end
    (; entries, count, active, leaf="entry-" * string(active),
        json=JSON.json(entries))
end

const branched = fixture(1200, 390)
const full = fixture(520, 520)
const medium = fixture(460, 240)
const small = fixture(64, 64)
const legacy = fixture(180, 180; null_at=80)

"""Full context selection, model-facing conversion and JSON serialization."""
function context_response(package, item)
    projection = package.timeline_projection(item.entries; leaf=item.leaf)
    JSON.json(Dict("entries"=>length(projection.entries),
        "messages"=>package.timeline_llm_messages(projection),
        "thinking"=>projection.thinking_level,"model"=>projection.model))
end

"""Raw display selection, record mapping and API-style JSON response."""
function display_response(package, item)
    projection = package.timeline_display_projection(item.entries; leaf=item.leaf)
    view = package.timeline_display_records(projection)
    JSON.json(Dict("entries"=>length(projection.entries),
        "items"=>[Dict("id"=>r.item.source_entry_id,"kind"=>String(r.item.kind),
            "payload"=>r.item.payload,"visible"=>r.visible) for r in view.records],
        "tools"=>length(view.tools)))
end

function mixed_response(package)
    context=package.timeline_projection(medium.entries;leaf=medium.leaf)
    display=package.timeline_display_projection(small.entries;leaf=small.leaf)
    records=package.timeline_display_records(display)
    JSON.json(Dict("messages"=>package.timeline_llm_messages(context),
        "display_items"=>length(records.records),
        "visible"=>count(r->r.visible,records.records),
        "last"=>last(context.messages)))
end

function unchanged_decode(package)
    decoded=JSON.parse(branched.json)
    (length(decoded),decoded[1]["id"],decoded[end]["id"])
end

const workloads = [
    ("integration/branched-context-to-json",p->context_response(p,branched),
        "changed: 1200 archived entries, 390 active, LLM context and JSON",true),
    ("integration/full-context-to-json",p->context_response(p,full),
        "changed: 520 active entries, LLM context and JSON",false),
    ("integration/branched-display-to-json",p->display_response(p,branched),
        "changed: display projection, rich records and JSON",false),
    ("integration/mixed-context-display",p->mixed_response(p),
        "changed: combined model/display projections and JSON",false),
    ("secondary/small-context",p->context_response(p,small),
        "changed: small active context",false),
    ("secondary/legacy-null-content",p->context_response(p,legacy),
        "changed: defensive-copy fallback for legacy null content",false),
    ("control/unchanged-json-decoder",p->unchanged_decode(p),
        "unchanged: JSON decoding without context projections",false),
]

const baseline_sha=readchomp(Cmd(["git","-C",baseline_directory,"rev-parse","HEAD"]))
const candidate_sha=readchomp(Cmd(["git","rev-parse","HEAD"]))
const environment=Dict(
    "baseline_sha"=>baseline_sha,"candidate_sha"=>candidate_sha,
    "julia_version"=>string(VERSION),"threads"=>Threads.nthreads(),
    "cpu"=>Sys.CPU_NAME,"logical_cpus"=>Sys.CPU_THREADS,"os"=>string(Sys.KERNEL),
    "arch"=>string(Sys.ARCH),"benchmarktools_version"=>string(Base.pkgversion(BenchmarkTools)),
    "json_version"=>string(Base.pkgversion(JSON)),
    "baseline_project_sha256"=>bytes2hex(sha256(read(joinpath(baseline_directory,"Project.toml")))),
    "candidate_project_sha256"=>bytes2hex(sha256(read("Project.toml"))),
    "benchmark_project_sha256"=>bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs"=>7,"samples_per_trial"=>16,"evals"=>1,"gctrial"=>true,"gcsample"=>false,
    "order"=>"AB BA AB BA AB BA AB",
    "confidence"=>"20000 seeded paired-trial bootstrap median resamples (2.5th percentile)",
    "fixtures"=>Dict("branched"=>[branched.count,branched.active],
        "full"=>[full.count,full.active],"legacy"=>[legacy.count,legacy.active]),
    "environment_match"=>"same Julia 1.13.3 process, machine, input, packages, and threads")
write(joinpath(evidence_directory,"environment.json"),JSON.json(environment))
baseline_sha=="6fc98e6e267548720be90cc0d88d282c725cbbf4" ||
    error("Baseline SHA differs from fresh pinned main")
read("Project.toml")==read(joinpath(baseline_directory,"Project.toml")) ||
    error("Baseline and candidate dependency declarations differ")

"""Assert strong semantic equivalence and preserve caller-owned graph isolation."""
function verify()
    for (name,work,_,_) in workloads
        left=work(Baseline)
        right=work(Candidate)
        equal=left isa AbstractString && right isa AbstractString ?
            isequal(JSON.parse(left),JSON.parse(right)) : isequal(left,right)
        equal || error("Semantic output mismatch: "*name)
    end
    owned=deepcopy(branched.entries)
    selected=Candidate.timeline_projection(branched.entries;leaf=branched.leaf)
    isequal(owned,branched.entries) || error("Context validation mutated caller")
    selected.messages[1]["content"][1]["text"]="mutated"
    isequal(owned,branched.entries) || error("Context result aliases caller")
    displayed=Candidate.timeline_display_projection(branched.entries;leaf=branched.leaf)
    displayed.items[1].payload["content"]="mutated"
    isequal(owned,branched.entries) || error("Display result aliases caller")
    repaired=Candidate.timeline_projection(legacy.entries;leaf=legacy.leaf)
    isempty(repaired.messages[80]["content"]) || error("Legacy null not repaired in output")
    isnothing(legacy.entries[80]["message"]["content"]) ||
        error("Legacy validation mutated caller")
    write(joinpath(evidence_directory,"contracts.json"),JSON.json(
        Dict("passed"=>true,"workloads"=>length(workloads),
            "full_outputs_equal"=>true,"caller_isolation"=>true,
            "legacy_repair_compatibility"=>true)))
end
verify()

"""BenchmarkTools owns timing, allocations and GC measurements."""
function measured_trial(work)
    case=BenchmarkTools.@benchmarkable $(work)() samples=16 evals=1 seconds=5.0 gctrial=true gcsample=false
    trial=BenchmarkTools.run(case)
    Dict("samples_ns"=>trial.times,"gc_ns"=>trial.gctimes,
        "median_ns"=>median(trial.times),"memory_bytes"=>trial.memory,
        "allocations"=>trial.allocs,"samples"=>length(trial.times))
end

function paired_confidence(improvements)
    state=UInt64(0x64df23a98bd9b3d7)
    medians=Float64[]
    for _ in 1:20000
        drawn=Float64[]
        for _ in eachindex(improvements)
            state=state*UInt64(6364136223846793005)+UInt64(1442695040888963407)
            push!(drawn,improvements[Int(mod(state,UInt64(length(improvements))))+1])
        end
        push!(medians,median(drawn))
    end
    (lower=quantile(medians,0.025),upper=quantile(medians,0.975))
end

"""Profile separately, never within BenchmarkTools measurement trials."""
function profile_work(work,tag)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:5
        work()
    end
    open(joinpath(evidence_directory,tag*"-cpu.txt"),"w") do io
        Profile.print(io;format=:flat,sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 work()
    sites=Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(a->!isempty(a.stacktrace),Profile.Allocs.fetch().allocs)
        frame=first(allocation.stacktrace)
        location=string(frame.file,":",frame.line," ",frame.func)
        old=get(sites,location,(0,0))
        sites[location]=(old[1]+1,old[2]+allocation.size)
    end
    rows=[Dict("location"=>name,"count"=>value[1],"bytes"=>value[2])
        for (name,value) in sites]
    sort!(rows;by=row->row["bytes"],rev=true)
    write(joinpath(evidence_directory,tag*"-allocations.json"),
        JSON.json(Dict("sample_rate"=>0.05,
            "sites"=>first(rows,min(length(rows),150)))))
    Profile.Allocs.clear()
end

const results=Dict{String,Any}()
for (name,work,scope,primary) in workloads
    baseline_work=()->work(Baseline)
    candidate_work=()->work(Candidate)
    for _ in 1:4
        baseline_work()
        candidate_work()
    end
    paired=Any[]
    for number in 1:7
        GC.gc()
        if isodd(number)
            baseline_result=measured_trial(baseline_work)
            candidate_result=measured_trial(candidate_work)
        else
            candidate_result=measured_trial(candidate_work)
            baseline_result=measured_trial(baseline_work)
        end
        push!(paired,Dict("pair"=>number,"first"=>isodd(number) ? "baseline" : "candidate",
            "baseline"=>baseline_result,"candidate"=>candidate_result))
    end
    improvements=[1.0-item["candidate"]["median_ns"]/item["baseline"]["median_ns"]
        for item in paired]
    bounds=paired_confidence(improvements)
    results[name]=Dict("scope"=>scope,"primary"=>primary,
        "median_improvement"=>median(improvements),
        "confidence_lower"=>bounds.lower,"confidence_upper"=>bounds.upper,
        "paired_improvements"=>improvements,"pairs"=>paired)
    write(joinpath(evidence_directory,"raw-trials.json"),
        JSON.json(Dict("environment"=>environment,"workloads"=>results)))
    println(name,": improvement=",round(100*median(improvements);digits=2),
        "%; lower95=",round(100*bounds.lower;digits=2),"%")
    flush(stdout)
end

profile_work(()->context_response(Baseline,branched),"baseline")
profile_work(()->context_response(Candidate,branched),"candidate")
const primary=results["integration/branched-context-to-json"]
const accepted=primary["median_improvement"]>=0.10 &&
    primary["confidence_lower"]>0.10 &&
    all(row["median_improvement"]> -0.10 for row in values(results))
write(joinpath(evidence_directory,"gate.json"),JSON.json(Dict(
    "passed"=>accepted,"criterion"=>"primary >=10%; lower95 >10%; all secondary medians above -10%; exact semantic outputs",
    "primary_improvement"=>primary["median_improvement"],
    "primary_lower95"=>primary["confidence_lower"],
    "regressions"=>[Dict("workload"=>name,"improvement"=>row["median_improvement"])
        for (name,row) in results if row["median_improvement"]<0])))
accepted || error("Performance gate failed; no pull request may be created")
