using JuliaForever2, BenchmarkTools, JSON, Profile, SHA, Statistics
import Pkg

# Include the exact baseline package from its detached worktree; its dependencies
# must be resolvable from the application's root project.
Pkg.activate(realpath(joinpath(@__DIR__, "..", "..")); io=devnull)
length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

const specs = Dict(
    "large" => (48, 24_000, :plain),
    "medium" => (32, 5_000, :plain),
    "mixed" => (26, 9_000, :plain),
    "escaped" => (24, 4_000, :escaped),
    "leading" => (20, 9_000, :leading),
    "short" => (72, 64, :short),
    "longword" => (20, 12_000, :longword))

function title_prompt(index::Int, bytes::Int, style::Symbol)
    prefix = style == :escaped ?
        "\e[34m   Explain \e[0m this 🐱 Julia module and check \u200e edge cases   " :
        style == :leading ? repeat(" \n\t", 600) * " Explain this long Julia request   " :
        style == :longword ? repeat("漢", 400) :
        "Please review this Julia code and explain its behavior   "
    tail = " Detailed implementation $(index): café; π=3.14; async locks, caller ownership. "
    style == :short && return "Please review this Julia code and explain its behavior $(index)."
    prefix * repeat(tail, cld(bytes, ncodeunits(tail)))
end

function histories(package, name)
    count, bytes, style = specs[name]
    [[package.Message(:assistant, "Earlier context for session $(index)."),
        package.Message(:user, title_prompt(index, bytes, style)),
        package.Message(:assistant, "Session history retained after title derivation.")]
        for index in 1:count]
end

const baseline_histories = Dict(name => histories(Baseline, name) for name in keys(specs))
const candidate_histories = Dict(name => histories(Candidate, name) for name in keys(specs))
fixture(package, name) = (package === Baseline ? baseline_histories : candidate_histories)[name]

"""Project many real native Message histories through the title service to a JSON response."""
function titles_response(package, name)
    service = package.SessionTitleService(; max_words=8, fallback_max_bytes=96)
    titles = [package.first_session_title(service, history) for history in fixture(package, name)]
    JSON.json(Dict("titles" => titles, "count" => length(titles),
        "named" => count(title -> !isnothing(title), titles)))
end

const json_payload = JSON.json(Dict("records" => [
    Dict("id" => index, "label" => "Current session $(index)",
        "active" => isodd(index), "role" => "user")
    for index in 1:750]))
function mixed_response(package)
    titles = JSON.parse(titles_response(package, "mixed"))
    recent = JSON.parse(json_payload)["records"]
    JSON.json(Dict("title_listing" => titles,
        "active_count" => count(row -> row["active"], recent),
        "last_session" => last(recent)["label"]))
end

const normalize_inputs = [
    "\e[31mA\u200e short 🦉 title\e[0m " * string(index) * " \t \n"
    for index in 1:160]
normalize_response(package) = JSON.json([
    package.normalize_session_title(text; max_bytes=120) for text in normalize_inputs])
parse_response(package) = begin
    rows = JSON.parse(json_payload)["records"]
    (length(rows), count(row -> row["active"], rows), rows[end]["label"])
end
no_user_response(package) = begin
    service = package.SessionTitleService(; max_words=8, fallback_max_bytes=96)
    [package.first_session_title(service,
        [package.Message(:assistant, "No user content $(index)")]) for index in 1:56]
end

const workloads = [
    (name="integration/large-48-session-titles-json", primary=true,
        scope="changed: derive fallback titles from 48 native histories with 24-kB first-user code prompts and serialize JSON list",
        work=package -> titles_response(package, "large")),
    (name="integration/medium-32-session-titles-json", primary=false,
        scope="changed: 32 native histories with 5-kB user messages and JSON serialization",
        work=package -> titles_response(package, "medium")),
    (name="integration/mixed-title-listing-and-json-processing", primary=false,
        scope="changed/mixed: 26 histories with 9-kB prompts, JSON title listing, parse 750 pre-existing inventory rows, serialize dashboard",
        work=package -> mixed_response(package)),
    (name="secondary/unicode-ansi-title-listing", primary=false,
        scope="changed: 24 title derivations with UTF-8, CSI, hidden bidi markers and terminal formatting",
        work=package -> titles_response(package, "escaped")),
    (name="secondary/leading-whitespace-title-listing", primary=false,
        scope="changed: long leading spaces and newline normalization before bounded title",
        work=package -> titles_response(package, "leading")),
    (name="secondary/long-unbroken-unicode-title", primary=false,
        scope="changed: multi-byte word exceeding byte budget, with long following text",
        work=package -> titles_response(package, "longword")),
    (name="secondary/short-title-listing", primary=false,
        scope="changed: 72 short native user prompts with little text to skip",
        work=package -> titles_response(package, "short")),
    (name="control/unchanged-normalization", primary=false,
        scope="unchanged: clean/title_prefix normalization uses the old vector based escape parser and does not call fallback_session_title",
        work=package -> normalize_response(package)),
    (name="control/no-user-title-service", primary=false,
        scope="unchanged: title service on assistant-only histories skips the changed fallback function",
        work=package -> no_user_response(package)),
    (name="control/unchanged-json-parser", primary=false,
        scope="unchanged: parse pre-existing JSON without title processing",
        work=package -> parse_response(package))
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
    "environment_match" => "same Julia process, runner, dependencies, Julia version, threads and input contents")
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

baseline_sha == "a35229790141395daa8618f8402a1002f3dea78c" ||
    error("Fresh baseline SHA mismatch")
VERSION == v"1.13.3" || error("Pinned Julia 1.13.3 required")
Threads.nthreads() == 2 || error("Expected 2 Julia threads")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Candidate source does not match checkout")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Root dependencies differ between exact baseline and candidate")
isempty(readchomp(Cmd(["git", "-C", baseline_directory, "diff", "HEAD", "--", "src"]))) ||
    error("Baseline source worktree is not clean")

function sample_inputs()
    tokens = ("alpha", "b", " ", "  ", "\t", "\n", "café", "世界", "🦉",
        "\e[31m", "\e[0m", "\e]1;hidden\a", "\e]2;hidden\e\\",
        "\u200e", "\u202e", "\u009b1;33m", "\u009dhidden\a", "\b", "\u2066")
    texts = String["", " ", "abc", "a b", "a  b \t c", "中文咖啡 😊", "\e",
        "\e[31m", "\e]still-open", "\e]hidden\e\\yes",
        "one two three four five six seven eight nine",
        repeat(" ", 7000) * "meaningful word",
        repeat("X", 30000) * " rest", "  \u200e \u202e a 🦉  world"]
    state = UInt64(0x93d8ab5d2a0163ee)
    for n in 1:180
        buffer = IOBuffer()
        for _ in 1:(n % 29 + 1)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            print(buffer, tokens[Int(mod(state, UInt64(length(tokens)))) + 1])
        end
        push!(texts, String(take!(buffer)))
    end
    texts
end

function verify_semantics()
    for name in keys(specs)
        base, new = fixture(Baseline, name), fixture(Candidate, name)
        length(base) == length(new) || error("Different history counts: $(name)")
        for (old_history, new_history) in zip(base, new)
            [item.content for item in old_history] == [item.content for item in new_history] ||
                error("Different fixture message content: $(name)")
            Baseline.first_session_title(Baseline.SessionTitleService(), old_history) ==
                Candidate.first_session_title(Candidate.SessionTitleService(), new_history) ||
                error("Native title service contract changed: $(name)")
        end
    end
    for text in sample_inputs(), words in (1, 2, 3, 8, 16), bytes in (1, 2, 3, 4, 7, 15, 32, 96, 120)
        old = Baseline.fallback_session_title(text; max_words=words, max_bytes=bytes)
        new = Candidate.fallback_session_title(text; max_words=words, max_bytes=bytes)
        old == new || error("Title mismatch for words=$(words), bytes=$(bytes), input=$(repr(text)): $(repr(old)) != $(repr(new))")
    end
    for workload in workloads
        lhs, rhs = workload.work(Baseline), workload.work(Candidate)
        lhs == rhs || error("Benchmark output contract mismatch: $(workload.name)")
    end
    write(joinpath(evidence_directory, "contracts.json"), JSON.json(Dict(
        "passed" => true, "workloads" => length(workloads),
        "native_history_cases" => length(specs), "fuzz_examples" => length(sample_inputs()),
        "fuzz_word_budgets" => 5, "fuzz_byte_budgets" => 9,
        "unicode_ansi_and_hidden_control_contracts" => true,
        "output_contracts_equal" => true)))
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
            if endswith(string(location.file), "session_titles.jl")
                frame = location
                break
            end
        end
        key = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, key, (0, 0))
        sites[key] = (old[1] + 1, old[2] + allocation.size)
    end
    rows = [Dict("site" => key, "count" => value[1], "bytes" => value[2])
        for (key, value) in sites]
    sort!(rows; by=row -> row["bytes"], rev=true)
    write(joinpath(evidence_directory, name * "-allocation-sites.json"),
        JSON.json(Dict("sample_rate" => 0.02, "sites" => first(rows, min(200, length(rows))))))
    Profile.Allocs.clear()
end

const results = Dict{String,Any}()
for workload in workloads
    baseline_work = () -> workload.work(Baseline)
    candidate_work = () -> workload.work(Candidate)
    for _ in 1:4
        baseline_work()
        candidate_work()
    end
    pairs = Any[]
    for iteration in 1:7
        GC.gc()
        if isodd(iteration)
            base = measured_trial(baseline_work)
            new = measured_trial(candidate_work)
        else
            new = measured_trial(candidate_work)
            base = measured_trial(baseline_work)
        end
        push!(pairs, Dict("pair" => iteration,
            "first" => isodd(iteration) ? "baseline" : "candidate",
            "baseline" => base, "candidate" => new))
    end
    improvements = [1.0 - pair["candidate"]["median_ns"] / pair["baseline"]["median_ns"]
        for pair in pairs]
    interval = paired_confidence(improvements)
    results[workload.name] = Dict("scope" => workload.scope,
        "primary" => workload.primary, "pairs" => pairs,
        "paired_improvements" => improvements, "median_improvement" => median(improvements),
        "confidence_lower" => interval.lower, "confidence_upper" => interval.upper)
    write(joinpath(evidence_directory, "raw-trials.json"),
        JSON.json(Dict("environment" => environment, "workloads" => results)))
    println(workload.name, " median ", round(100 * median(improvements); digits=2),
        "% lower95 ", round(100 * interval.lower; digits=2), "%")
    flush(stdout)
end

profile_work(() -> titles_response(Baseline, "large"), "baseline")
profile_work(() -> titles_response(Candidate, "large"), "candidate")
const primary = results["integration/large-48-session-titles-json"]
const passed = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory, "gate.json"), JSON.json(Dict(
    "passed" => passed, "primary_median" => primary["median_improvement"],
    "primary_lower95" => primary["confidence_lower"],
    "criterion" => "Primary median >=10%, paired 95% confidence lower >10%, no >=10% secondary slowdown, exact semantics",
    "slowdowns" => [Dict("workload" => name,
        "median_improvement" => row["median_improvement"])
        for (name, row) in results if row["median_improvement"] < 0])))
passed || error("Experimental gate FAILED; no pull request")