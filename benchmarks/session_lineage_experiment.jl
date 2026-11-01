using JuliaForever2, JSON, Profile, Statistics, SHA, UUIDs

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

const namespace = UUID("b333d3b3-e8ca-42d6-a409-458af9b54cb8")

function fixture(style::Symbol, count::Int)
    directory = mktempdir()
    ids = [uuid5(namespace, string(style, "-", count, "-", index)) for index in 1:count]
    for index in 1:count
        parent = index == 1 ? nothing :
            style == :chain ? ids[index - 1] :
            style == :star ? ids[1] :
            style == :forest ? (index % 7 == 0 ? nothing : ids[index - 1]) : nothing
        record = Dict("format" => "JuliaForever2.session", "version" => 2,
            "name" => "session-$(lpad(index, 5, '0'))",
            "working_directory" => directory,
            "messages" => [Dict("role" => "user", "kind" => "text", "content" => "sample $(index)")],
            "lineage" => Dict("id" => string(ids[index]),
                "parent_id" => isnothing(parent) ? nothing : string(parent),
                "root_id" => string(ids[1])))
        write(joinpath(directory, "session-$(lpad(index, 5, '0')).json"), JSON.json(record))
    end
    return (directory=directory, root=ids[1], count=count)
end

const fixtures = Dict(
    "integration/lineage-chain-1200" => fixture(:chain, 1200),
    "integration/lineage-chain-480" => fixture(:chain, 480),
    "integration/lineage-chain-80" => fixture(:chain, 80),
    "integration/lineage-star-1200" => fixture(:star, 1200),
    "integration/lineage-star-80" => fixture(:star, 80),
    "integration/lineage-forest-560" => fixture(:forest, 560),
)

function descendants(package, item)
    store = package.SessionStore(item.directory)
    return package.session_descendants(store, item.root; include_self=true)
end

function sample(f)
    GC.gc()
    samples = Int[]
    for _ in 1:9
        begin_ns = time_ns()
        f()
        push!(samples, time_ns() - begin_ns)
    end
    return (samples_ns=samples, median_ns=median(samples),
        allocated_bytes=Base.@allocated(f()), allocations=Base.@allocations(f()))
end

function conservative_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
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
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if endswith(string(location.file), "session_store.jl")
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(site=site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=entry -> entry.bytes, rev=true)
    write(joinpath(output_directory, prefix * "-allocation-sites.json"),
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
    pairs=7, repetitions_per_side=9, warmup_calls_per_case=4,
    order="AB,BA,AB,BA,AB,BA,AB",
    interval="two-sided 95% percentile bootstrap of paired per-trial improvements (10,000 resamples)",
    gate="median and lower95 >10%, all seven pairs >10%, no other case median <-3% or lower95 <-7%",
    environment="same process, runner, packages, JULIA_NUM_THREADS=1, OPENBLAS_NUM_THREADS=1",
    workload="Durably stored JSON sessions, full session_names enumeration, JSON parsing, UUID lineage traversal and sorted results")
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for (name, item) in sort!(collect(fixtures); by=first)
    baseline = () -> descendants(Baseline, item)
    candidate = () -> descendants(Candidate, item)
    expected = baseline()
    observed = candidate()
    expected == observed || error("Mismatch in $(name)")
    expected == sort(expected) || error("Unsorted results in $(name)")
    length(expected) >= 1 || error("Missing root in $(name)")
    if !occursin("forest", name)
        length(expected) == item.count || error("Wrong descendant count in $(name)")
    end
    for _ in 1:4
        baseline()
        candidate()
    end
    baseline_samples, candidate_samples = Any[], Any[]
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
    confidence = conservative_confidence(improvements)
    result = (; baseline=baseline_samples, candidate=candidate_samples,
        paired_improvements=improvements,
        median_improvement=median(improvements),
        ci95_lower_improvement=confidence.lower, ci95_upper_improvement=confidence.upper,
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_samples, :allocations)),
        candidate_median_allocations=median(getproperty.(candidate_samples, :allocations)),
        baseline_median_bytes=median(getproperty.(baseline_samples, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_samples, :allocated_bytes)),
        correctness="Exact sorted session identifiers match for the same durable JSON snapshot")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, " median=", round(100 * result.median_improvement; digits=2),
        "% lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "% allocations=", result.baseline_median_allocations, "->", result.candidate_median_allocations)
    flush(stdout)
end

flagship_name = "integration/lineage-chain-1200"
profile_case(() -> descendants(Baseline, fixtures[flagship_name]), "baseline-chain")
profile_case(() -> descendants(Candidate, fixtures[flagship_name]), "candidate-chain")
flagship = results[flagship_name]
nonregressed = all(value.median_improvement > -0.03 &&
    value.ci95_lower_improvement > -0.07 for (name, value) in results if name != flagship_name)
accepted = flagship.median_improvement > 0.10 &&
    flagship.ci95_lower_improvement > 0.10 &&
    flagship.minimum_pair_improvement > 0.10 && nonregressed
gate = (; accepted, flagship=flagship_name,
    median_improvement=flagship.median_improvement,
    ci95_lower_improvement=flagship.ci95_lower_improvement,
    all_pairs_above_ten_percent=flagship.minimum_pair_improvement > 0.10,
    no_material_regressions=nonregressed)
write(joinpath(output_directory, "gate.json"), JSON.json(gate))
println("Acceptance gate: ", JSON.json(gate))
accepted || error("Performance acceptance gate failed; do not create PR")
