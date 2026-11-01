using JuliaForever2, JSON, Profile, Statistics, SHA, UUIDs

length(ARGS) == 2 || error("Expected exact baseline worktree and evidence directory")
const baseline_dir = realpath(ARGS[1])
const evidence_dir = abspath(ARGS[2])
mkpath(evidence_dir)
module OriginalNamespace end
Base.include(OriginalNamespace, joinpath(baseline_dir, "src/JuliaForever2.jl"))
const Baseline = OriginalNamespace.JuliaForever2
const Candidate = JuliaForever2
const uuid_namespace = UUID("f5dd0c58-609b-4f35-9ebe-774d90e7c91d")

function make_fixture(label::String, sessions::Int, messages::Int, style::Symbol; version=2)
    directory = mktempdir()
    ids = [uuid5(uuid_namespace, "$(label)-$(i)") for i in 1:sessions]
    for i in 1:sessions
        name = "session-" * lpad(i, 5, '0')
        parent = i == 1 ? nothing :
            style == :chain ? ids[i-1] :
            style == :star ? ids[1] :
            style == :forest && i % 6 != 0 ? ids[i-1] : nothing
        content = "saved conversation transcript $(i), valid JSON and UTF-8: " *
            repeat("tools, messages, history, durable search, café λ. ", 4)
        data = Dict("format"=>"JuliaForever2.session","version"=>version,
            "name"=>name,"working_directory"=>directory,
            "messages"=>[Dict("role"=>isodd(j) ? "user" : "assistant",
                "kind"=>"text","content"=>content * " entry $(j)") for j in 1:messages],
            "lineage"=>Dict("id"=>string(ids[i]),
                "parent_id"=>isnothing(parent) ? nothing : string(parent),
                "root_id"=>string(ids[1])))
        write(joinpath(directory, name * ".json"), JSON.json(data))
    end
    return (;directory, ids, sessions, messages, root_name="session-00001")
end

const fixtures = Dict(
    "integration/children-chain-160x48" => make_fixture("big", 160, 48, :chain),
    "integration/children-star-100x24" => make_fixture("star", 100, 24, :star),
    "integration/children-forest-75x12" => make_fixture("forest", 75, 12, :forest),
    "integration/children-empty-75" => make_fixture("empty", 75, 0, :star),
    "integration/children-small-12x2" => make_fixture("small", 12, 2, :chain),
    "integration/children-legacy-v1-50" => make_fixture("legacy", 50, 12, :star; version=1),
    "query/lineage-single-heavy" => make_fixture("single-heavy", 1, 320, :chain),
    "query/lineage-single-empty" => make_fixture("single-empty", 1, 0, :chain),
    "control/load-full-record" => make_fixture("control", 1, 64, :chain),
)

function run_workload(package, name, item)
    store = package.SessionStore(item.directory)
    if startswith(name, "integration/")
        return package.session_descendants(store, item.ids[1]; include_self=true)
    elseif name == "control/load-full-record"
        record = package.saved_session_record(store, item.root_name)
        return (length(record.messages), record.lineage, record.directory)
    else
        return package.session_lineage(store, item.root_name)
    end
end

function measure(f)
    GC.gc()
    samples = Int[]
    for _ in 1:9
        started = time_ns()
        f()
        push!(samples, time_ns() - started)
    end
    return (times_ns=samples, median_ns=median(samples),
        allocated_bytes=Base.@allocated(f()), allocations=Base.@allocations(f()))
end

function confidence_interval(improvements)
    state = UInt64(0xbaf19dd131f5b9ad)
    medians = Float64[]
    for _ in 1:12000
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
        end_time = time_ns() + 300_000_000
        while time_ns() < end_time
            f()
        end
    end
    open(joinpath(evidence_dir, prefix * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "session_store.jl")
                frame = location
                break
            end
        end
        label = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, label, (0, 0))
        sites[label] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site,count=value[1],bytes=value[2]) for (site,value) in sites]
    sort!(records; by=x -> x.bytes, rev=true)
    write(joinpath(evidence_dir, prefix * "-allocation-sites.json"),
        JSON.json((sample_rate=0.05,sites=records)))
    Profile.Allocs.clear()
end

const metadata = (;
    baseline_sha=readchomp(Cmd(["git","-C",baseline_dir,"rev-parse","HEAD"])),
    candidate_sha=readchomp(Cmd(["git","rev-parse","HEAD"])),
    julia_version=string(VERSION),threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME,cpu_threads=Sys.CPU_THREADS,arch=string(Sys.ARCH),os=string(Sys.KERNEL),
    json_version=string(Base.pkgversion(JSON)),
    candidate_test_project_sha256=bytes2hex(sha256(read("test/Project.toml"))),
    baseline_test_project_sha256=bytes2hex(sha256(read(joinpath(baseline_dir,"test/Project.toml")))),
    paired_samples=7,repetitions=9,warmups_per_side=5,
    alternating_order="AB,BA,AB,BA,AB,BA,AB",
    ci_method="95% percentile bootstrap of seven matched paired relative improvements (12000 draws)",
    runner_match="same Julia process, packages, filesystem fixture, runner, threads=1; OPENBLAS_NUM_THREADS=1",
    workload="Durably stored JSON sessions, filesystem enumeration, JSON decoding, message and lineage extraction, UUID traversal, sorted descendants")
write(joinpath(evidence_dir,"environment.json"),JSON.json(metadata))

results = Dict{String,Any}()
for (name,item) in sort!(collect(fixtures);by=first)
    old = () -> run_workload(Baseline,name,item)
    new = () -> run_workload(Candidate,name,item)
    isequal(old(),new()) || error("Correctness mismatch for $(name)")
    for _ in 1:5
        old()
        new()
    end
    before,after = Any[],Any[]
    for pair in 1:7
        if isodd(pair)
            push!(before,measure(old))
            push!(after,measure(new))
        else
            push!(after,measure(new))
            push!(before,measure(old))
        end
    end
    improvements = [1 - after[i].median_ns / before[i].median_ns for i in 1:7]
    bounds = confidence_interval(improvements)
    result = (;baseline=before,candidate=after,paired_improvements=improvements,
        median_improvement=median(improvements),
        ci95_lower_improvement=bounds.lower,ci95_upper_improvement=bounds.upper,
        minimum_paired_improvement=minimum(improvements),
        baseline_median_ns=median(getproperty.(before,:median_ns)),
        candidate_median_ns=median(getproperty.(after,:median_ns)),
        baseline_median_allocations=median(getproperty.(before,:allocations)),
        candidate_median_allocations=median(getproperty.(after,:allocations)),
        baseline_median_bytes=median(getproperty.(before,:allocated_bytes)),
        candidate_median_bytes=median(getproperty.(after,:allocated_bytes)))
    results[name]=result
    write(joinpath(evidence_dir,"paired-raw.json"),JSON.json((;metadata,results)))
    println(name," gain=",round(100*result.median_improvement;digits=3),
        "% lower95=",round(100*result.ci95_lower_improvement;digits=3),
        "% bytes=",result.baseline_median_bytes,"->",result.candidate_median_bytes)
    flush(stdout)
end
flagship_name="integration/children-chain-160x48"
profile_case(() -> run_workload(Baseline,flagship_name,fixtures[flagship_name]),"baseline")
profile_case(() -> run_workload(Candidate,flagship_name,fixtures[flagship_name]),"candidate")
flagship=results[flagship_name]
no_regressions=all(r.median_improvement > -0.03 &&
    r.ci95_lower_improvement > -0.07 for (name,r) in results if name != flagship_name)
accepted=flagship.median_improvement > 0.10 &&
    flagship.ci95_lower_improvement > 0.10 &&
    flagship.minimum_paired_improvement > 0.10 && no_regressions
gate=(;accepted,flagship=flagship_name,median_improvement=flagship.median_improvement,
    ci95_lower_improvement=flagship.ci95_lower_improvement,
    no_material_regressions=no_regressions)
write(joinpath(evidence_dir,"gate.json"),JSON.json(gate))
println("Acceptance gate: ",JSON.json(gate))
accepted || error("Performance acceptance gate FAILED: do not create a pull request")
