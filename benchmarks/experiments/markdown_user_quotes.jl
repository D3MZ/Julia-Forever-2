using JuliaForever2, BenchmarkTools, JSON, SHA, Statistics, Profile

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)

module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

function user_text(index, lines)
    repeat("Session $(index): explain a Julia transform 🐱 café 日本語.\r\n" *
        "Keep this second line with a literal backtick \` and punctuation.\n" *
        "\tIndented text; preserve all whitespace.\r" *
        "Fourth line: Σ = ∑ and no dropped content.\n", lines) * "\n\n"
end

function assistant_text(index, lines)
    repeat("Answer $(index): preserve the generated transcript.\n" *
        "The next line is \`Julia\` code and remains unchanged.\n", lines)
end

function make_messages(package, count, user_lines)
    [package.Message(isodd(index) ? :user : :assistant,
        isodd(index) ? user_text(index, user_lines) :
            assistant_text(index, max(1, div(user_lines, 3))))
        for index in 1:count]
end

const input_cases = Dict(
    "large" => (360, 18),
    "medium" => (156, 10),
    "small" => (12, 2),
    "unicode-crlf" => (90, 14),
    "mixed" => (170, 8),
    "short" => (260, 0),
)
const baseline_cases = Dict(name => make_messages(Baseline, size...)
    for (name, size) in input_cases)
const candidate_cases = Dict(name => make_messages(Candidate, size...)
    for (name, size) in input_cases)
const baseline_assistant = [Baseline.Message(:assistant, assistant_text(index, 10))
    for index in 1:240]
const candidate_assistant = [Candidate.Message(:assistant, assistant_text(index, 10))
    for index in 1:240]
const json_input = JSON.json(Dict("records" => [Dict("id" => index,
    "text" => "valid message $(index)", "flag" => isodd(index))
    for index in 1:900]))

function get_messages(package, name)
    package === Baseline ? baseline_cases[name] : candidate_cases[name]
end

function transcript_response(package, name)
    messages = get_messages(package, name)
    markdown = package.session_markdown(messages; title="Archived conversation",
        source_path="/workspace/sessions/archive-file.json")
    JSON.json(Dict("markdown" => markdown, "bytes" => ncodeunits(markdown),
        "messages" => length(messages)))
end

function mixed_response(package)
    messages = get_messages(package, "mixed")
    title = package.fallback_session_title(messages[1].content)
    markdown = package.session_markdown(messages; title,
        source_path="/workspace/session-latest.json")
    JSON.json(Dict("title" => title, "markdown" => markdown,
        "digest" => bytes2hex(sha256(markdown)), "messages" => length(messages)))
end

function assistant_response(package)
    messages = package === Baseline ? baseline_assistant : candidate_assistant
    markdown = package.session_markdown(messages; title="Assistant-only control")
    JSON.json(Dict("markdown" => markdown, "messages" => length(messages)))
end

const workloads = [
    (name="integration/large-transcript-markdown-json", primary=true,
        scope="changed: 360-turn user/assistant multiline session Markdown export and full JSON response",
        work=package -> transcript_response(package, "large")),
    (name="integration/medium-transcript-markdown-json", primary=false,
        scope="changed: medium 156-turn session Markdown and JSON response",
        work=package -> transcript_response(package, "medium")),
    (name="integration/mixed-title-transcript-json", primary=false,
        scope="changed/mixed: first-user fallback title, multiline transcript and JSON serialization",
        work=package -> mixed_response(package)),
    (name="integration/unicode-crlf-transcript-json", primary=false,
        scope="changed: 90-turn Unicode/CRLF/bare-CR transcript and serialized JSON output",
        work=package -> transcript_response(package, "unicode-crlf")),
    (name="secondary/short-messages", primary=false,
        scope="changed: many zero-length user messages and short assistant messages",
        work=package -> transcript_response(package, "short")),
    (name="secondary/small-transcript", primary=false,
        scope="changed: small transcript output with user quoting",
        work=package -> transcript_response(package, "small")),
    (name="control/assistant-only-markdown-json", primary=false,
        scope="unchanged: assistant-only markdown path; no changed user quoting method",
        work=package -> assistant_response(package)),
    (name="control/unchanged-json-parser", primary=false,
        scope="unchanged: JSON parser alone; no Markdown renderer",
        work=package -> begin
            value = JSON.parse(json_input)
            (length(value["records"]), value["records"][1]["text"],
                value["records"][end]["id"])
        end),
]

const baseline_sha = readchomp(Cmd(["git", "-C", baseline_directory, "rev-parse", "HEAD"]))
const candidate_sha = readchomp(Cmd(["git", "rev-parse", "HEAD"]))
const environment = Dict(
    "baseline_sha" => baseline_sha, "candidate_sha" => candidate_sha,
    "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
    "cpu" => Sys.CPU_NAME, "logical_cpus" => Sys.CPU_THREADS,
    "architecture" => string(Sys.ARCH), "operating_system" => string(Sys.KERNEL),
    "benchmarktools_version" => string(Base.pkgversion(BenchmarkTools)),
    "json_version" => string(Base.pkgversion(JSON)),
    "baseline_project_sha256" => bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    "candidate_project_sha256" => bytes2hex(sha256(read("Project.toml"))),
    "benchmark_project_sha256" => bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs" => 7, "samples_per_trial" => 12, "evals" => 1,
    "seconds" => 4.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 deterministic bootstrap resamples of seven independent paired-trial medians",
    "environment_match" => "same runner, process, Julia version, packages, machine, threads and fixtures",
    "primary_messages" => 360, "primary_user_lines_per_entry" => 18)
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

baseline_sha == "7d68c621d63bdb5fe3b44586d1e31588d4975787" ||
    error("Baseline must be the fresh main SHA")
VERSION == v"1.13.3" || error("Julia must be exactly 1.13.3")
Threads.nthreads() == 2 || error("Expected two threads")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Loaded candidate does not match checkout")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Source dependencies must match")
isempty(readchomp(Cmd(["git","-C",baseline_directory,"diff","HEAD","--","src"]))) ||
    error("Baseline source worktree differs from commit")

function verify_semantics()
    direct = String[
        "", "a", "\n", "\r", "\r\n", "\n\n", "a\n", "a\n\n", "a\r\n",
        "a\rb", "\ra", "\r\nfirst\n\nsecond\r\n", "\n\nleading",
        "trailing\n\n \n", " \n\t\n", "\n\t", "\n\t\n",
        "日本語\rcafé\n😀", "é\u0301\n👩‍💻", "> quoted\n\nraw",
        "\0 embedded", "\e[31mcolored\e[0m\r\n",
        repeat("x\n\n", 700), repeat("Julia 🔥\r\n   \n", 100)]
    for (index, sample) in enumerate(direct)
        left = Baseline.session_markdown_entry(Baseline.Message(:user, sample))
        right = Candidate.session_markdown_entry(Candidate.Message(:user, sample))
        isequal(left, right) || error("Direct user Markdown fixture mismatch: $(index)")
    end
    for workload in workloads
        left, right = workload.work(Baseline), workload.work(Candidate)
        isequal(left, right) || error("Measured output contract mismatch: $(workload.name)")
    end
    # Verify the caller retains its message contents.
    before = get_messages(Candidate, "large")[1].content
    transcript_response(Candidate, "large")
    get_messages(Candidate, "large")[1].content == before ||
        error("Markdown renderer mutated caller-owned message")
    write(joinpath(evidence_directory, "contracts.json"), JSON.json(Dict(
        "passed" => true, "fixtures" => length(direct),
        "workloads" => length(workloads), "exact_semantic_equality" => true,
        "caller_message_unchanged" => true,
        "line_endings_and_unicode" => true, "mixed_workflow" => true)))
end

try
    verify_semantics()
catch failure
    write(joinpath(evidence_directory, "contracts.json"), JSON.json(Dict(
        "passed" => false, "error" => sprint(showerror, failure))))
    rethrow()
end

"""Collect all timed samples and allocation counts using BenchmarkTools."""
function measured_trial(work)
    benchmark = BenchmarkTools.@benchmarkable $(work)() samples=12 evals=1 seconds=4.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(benchmark)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

"""Compute a 95% percentile interval over independent paired-trial medians."""
function paired_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    draws = Float64[]
    for _ in 1:20000
        selected = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(selected, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(draws, median(selected))
    end
    (lower=quantile(draws, 0.025), upper=quantile(draws, 0.975))
end

function profile_work(work, name)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:12
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
            if endswith(string(location.file), "session_markdown.jl")
                frame = location
                break
            end
        end
        key = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, key, (0, 0))
        sites[key] = (old[1] + 1, old[2] + allocation.size)
    end
    rows = [Dict("location" => key, "count" => value[1], "bytes" => value[2])
        for (key, value) in sites]
    sort!(rows; by=row -> row["bytes"], rev=true)
    write(joinpath(evidence_directory, name * "-allocation-sites.json"),
        JSON.json(Dict("sample_rate" => 0.02,
            "sites" => first(rows, min(length(rows), 200)))))
    Profile.Allocs.clear()
end

const results = Dict{String,Any}()
for workload in workloads
    base_work = () -> workload.work(Baseline)
    candidate_work = () -> workload.work(Candidate)
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
    results[workload.name] = Dict(
        "scope" => workload.scope, "primary" => workload.primary,
        "pairs" => pairs, "paired_improvements" => improvements,
        "median_improvement" => median(improvements),
        "confidence_lower" => interval.lower, "confidence_upper" => interval.upper)
    write(joinpath(evidence_directory, "raw-trials.json"),
        JSON.json(Dict("environment" => environment, "workloads" => results)))
    println(workload.name, ": median=", round(100 * median(improvements); digits=2),
        "% lower95=", round(100 * interval.lower; digits=2), "%")
    flush(stdout)
end

profile_work(() -> transcript_response(Baseline, "large"), "baseline")
profile_work(() -> transcript_response(Candidate, "large"), "candidate")
const primary = results["integration/large-transcript-markdown-json"]
const passed = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory, "gate.json"), JSON.json(Dict(
    "passed" => passed,
    "primary_median" => primary["median_improvement"],
    "primary_lower95" => primary["confidence_lower"],
    "criterion" => "primary median >=10%, bootstrap 95% lower >10%, no secondary >=10% slowdown and exact outputs",
    "slowdowns" => [Dict("workload" => name,
        "median_improvement" => row["median_improvement"])
        for (name, row) in results if row["median_improvement"] < 0])))
passed || error("Experimental acceptance gate FAILED: no PR")
