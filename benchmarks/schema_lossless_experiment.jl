using JuliaForever2, JSON, Profile, SHA, Statistics

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const candidate_directory = realpath(joinpath(@__DIR__, ".."))
const output_directory = abspath(ARGS[2])
mkpath(output_directory)

module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

function schema(package)
    row = Dict("type" => "object", "properties" => Dict(
        "id" => Dict("type" => "integer"),
        "label" => Dict("type" => "string"),
        "tags" => Dict("type" => "array", "items" => Dict("type" => "string")),
        "detail" => Dict("type" => "object", "properties" => Dict(
            "weight" => Dict("type" => "number"), "enabled" => Dict("type" => "boolean")),
            "required" => ["weight", "enabled"], "additionalProperties" => true)),
        "required" => ["id", "label", "tags", "detail"], "additionalProperties" => true)
    return package.CheckedJSONSchema(Dict("type" => "object",
        "properties" => Dict("rows" => Dict("type" => "array", "items" => row)),
        "required" => ["rows"], "additionalProperties" => true))
end

function payload(n; invalid=:none)
    rows = [Dict{String,Any}("id" => i, "label" => "record-$i",
        "tags" => ["julia", "tool", "validation"],
        "detail" => Dict{String,Any}("weight" => Float64(i), "enabled" => isodd(i)))
        for i in 1:n]
    if invalid === :declared
        rows[end]["id"] = "invalid"
    elseif invalid === :additional
        rows[end]["unexpected"] = Dict("invalid" => NaN)
    elseif invalid === :missing
        rows[end]["detail"]["enabled"] = missing
    end
    return Dict{String,Any}("rows" => rows)
end

const samples = Dict(
    "integration/tool-20x192-rows" => payload(192),
    "integration/tool-16x64-rows" => payload(64),
    "integration/tool-16x8-rows" => payload(8),
    "validation/valid-192-rows" => payload(192),
    "validation/invalid-declared-192-rows" => payload(192; invalid=:declared),
    "validation/invalid-additional-192-rows" => payload(192; invalid=:additional),
    "validation/invalid-missing-192-rows" => payload(192; invalid=:missing),
    "validation/valid-8-rows" => payload(8),
)

function prepare(package)
    checked = schema(package)
    scope = package.ExtensionScope()
    result = package.register_tool!(scope,
        package.ToolSpec(:ingest_rows, checked,
            arguments -> sum(row["id"] for row in arguments["rows"])))
    result.ok || error("Tool registration failed")
    return (checked=checked, scope=scope)
end

const baseline_state = prepare(Baseline)
const candidate_state = prepare(Candidate)

function integration(package, scope, arguments, calls)
    conversation = package.Conversation()
    successes = 0
    for _ in 1:calls
        result = package.invoke_tool!(scope, :ingest_rows, arguments)
        successes += result.ok
        package.append_message!(conversation, package.Message(:code_result, result.text))
    end
    return (successes, [message.content for message in package.history_snapshot(conversation).messages])
end

function cases(package, state)
    output = Dict{String,Any}()
    for (name, argument) in samples
        if startswith(name, "integration/")
            calls = name == "integration/tool-20x192-rows" ? 20 : 16
            output[name] = () -> integration(package, state.scope, argument, calls)
        else
            output[name] = () -> package.tool_argument_violations(state.checked, argument)
        end
    end
    return output
end

const baseline_cases = cases(Baseline, baseline_state)
const candidate_cases = cases(Candidate, candidate_state)

function trial(f)
    GC.gc()
    times_ns = Int[]
    for _ in 1:9
        started = time_ns()
        f()
        push!(times_ns, time_ns() - started)
    end
    return (; times_ns, median_ns=median(times_ns),
        allocated_bytes=Base.@allocated(f()), allocations=Base.@allocations(f()))
end

function lower95(improvements)
    state = UInt64(0xc0ffee42abc91)
    medians = Float64[]
    for _ in 1:10000
        draw = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(draw, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(medians, median(draw))
    end
    return quantile(medians, 0.025)
end

function profile_case(f, name)
    f()
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 450_000_000
        while time_ns() < deadline
            f()
        end
    end
    open(joinpath(output_directory, name * "-cpu.txt"), "w") do output
        Profile.print(output; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Profile.Allocs.fetch().allocs
        isempty(allocation.stacktrace) && continue
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if occursin("tool_schemas.jl", string(location.file))
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
    write(joinpath(output_directory, name * "-allocations.json"),
        JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const metadata = (;
    baseline_sha=readchomp(`git -C $baseline_directory rev-parse HEAD`),
    candidate_sha=readchomp(`git -C $candidate_directory rev-parse HEAD`),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS,
    os=string(Sys.KERNEL), architecture=string(Sys.ARCH),
    json_version=string(Base.pkgversion(JSON)),
    candidate_project_sha256=bytes2hex(sha256(read(joinpath(candidate_directory, "test/Project.toml")))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_directory, "test/Project.toml")))),
    pairs=7, repetitions_per_side=9, warmup_calls=12,
    order="AB BA AB BA AB BA AB",
    ci95="10,000 deterministic percentile bootstrap resamples of seven paired medians",
    comparison="same Julia process, packages, runner, threads and deterministic fixture objects",
    workload="real registered checked-schema tool calls, task dispatch, completion and conversation append")
write(joinpath(output_directory, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for name in sort!(collect(keys(baseline_cases)))
    baseline = baseline_cases[name]
    candidate = candidate_cases[name]
    expected, observed = baseline(), candidate()
    isequal(expected, observed) || error("Baseline/candidate output mismatch: $name")
    for _ in 1:12
        baseline()
        candidate()
    end
    baseline_trials, candidate_trials = Any[], Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, trial(baseline))
            push!(candidate_trials, trial(candidate))
        else
            push!(candidate_trials, trial(candidate))
            push!(baseline_trials, trial(baseline))
        end
    end
    improvements = [1 - candidate_trials[i].median_ns / baseline_trials[i].median_ns for i in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=lower95(improvements),
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocations)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocations)),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        correctness="exact baseline/candidate output match")
    results[name] = result
    write(joinpath(output_directory, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": median ", round(100 * result.median_improvement; digits=2),
        "% lower95 ", round(100 * result.ci95_lower_improvement; digits=2),
        "% allocations ", result.baseline_median_allocations, " -> ", result.candidate_median_allocations)
    flush(stdout)
end

representative_name = "integration/tool-20x192-rows"
profile_case(baseline_cases[representative_name], "baseline-integration")
profile_case(candidate_cases[representative_name], "candidate-integration")
for name in ["validation/invalid-declared-192-rows", "validation/invalid-additional-192-rows"]
    label = replace(name, "/" => "-")
    profile_case(baseline_cases[name], "baseline-" * label)
    profile_case(candidate_cases[name], "candidate-" * label)
end

representative = results[representative_name]
no_regressions = all(value.median_improvement > -0.03 && value.ci95_lower_improvement > -0.07
    for (name, value) in results if name != representative_name)
accepted = representative.median_improvement > 0.10 &&
    representative.ci95_lower_improvement > 0.10 &&
    representative.minimum_pair_improvement > 0.10 && no_regressions
gate = (; accepted, representative_name, representative_median=representative.median_improvement,
    representative_lower95=representative.ci95_lower_improvement,
    minimum_paired_improvement=representative.minimum_pair_improvement, no_regressions)
write(joinpath(output_directory, "gate.json"), JSON.json(gate))
println("PERFORMANCE_GATE=", accepted ? "PASS" : "FAIL")
accepted || error("Performance gate failed; do not create a PR")
