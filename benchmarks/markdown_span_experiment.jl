using JuliaForever2, Tachikoma, CommonMark, JSON, Profile, Statistics, SHA

length(ARGS) == 2 || error("Usage: julia --project=test benchmarks/markdown_span_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_dir = realpath(ARGS[1])
const candidate_dir = realpath(joinpath(@__DIR__, ".."))
const output_dir = abspath(ARGS[2])
mkpath(output_dir)

# Load the production transcript functions into separate namespaces, with
# identical JuliaForever2/Tachikoma/CommonMark dependencies and styles.
module BaselineLayout
    using JuliaForever2, Tachikoma, CommonMark
    const TranscriptLine = Tuple{Union{String,Vector{Tachikoma.Span}},Symbol}
    function pi_style(style::Symbol)
        color = style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
            style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
            style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
        return Tachikoma.Style(; fg=color)
    end
end
module CandidateLayout
    using JuliaForever2, Tachikoma, CommonMark
    const TranscriptLine = Tuple{Union{String,Vector{Tachikoma.Span}},Symbol}
    function pi_style(style::Symbol)
        color = style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
            style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
            style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
        return Tachikoma.Style(; fg=color)
    end
end
function include_layout!(destination, directory)
    file = joinpath(directory, "ext/terminal/transcript.jl")
    source = read(file, String)
    # The leading portion contains the actual production wrap, markdown and
    # conversation_lines implementation; the rest requires the App runtime.
    functions = first(split(source, "\nfunction transcript_lines!"; limit=2))
    Base.include_string(destination, functions, file)
end
include_layout!(BaselineLayout, baseline_dir)
include_layout!(CandidateLayout, candidate_dir)

const markdown_article = join([
    "## Julia execution transcript",
    "The assistant has **completed** an evaluation, rendered its output, and formatted the response for a terminal display.",
    "A Julia program uses `mul!`, `map!`, and `@views` to avoid temporary allocations. [Details](https://julialang.org).",
    repeat("Progress update: formatting Markdown, inline code, status flags, and regular text into terminal spans. ", 9),
    "Next: print diagnostics and continue the conversation with complete, correctly wrapped output.",
], "\n")
const unicode_article = join([
    "## Unicode transcript",
    repeat("A Julia session emits λ日本語🚀, cafe\u0301, and ASCII words for terminal rendering. ", 9),
    "**Status:** still streaming the assistant response.",
], "\n")
const plain_article = repeat("A user asks Julia to compute a result, with lots of ordinary ASCII text and spaces. ", 7)

function history(content, count)
    return [JuliaForever2.Message(:assistant, content) for _ in 1:count]
end
function mixed_history()
    messages = JuliaForever2.Message[]
    for index in 1:96
        role = index % 3 == 0 ? :assistant : index % 3 == 1 ? :user : :code_result
        text = role === :assistant ? markdown_article : plain_article
        push!(messages, JuliaForever2.Message(role, text))
    end
    return messages
end
const markdown_history = history(markdown_article, 96)
const long_history = history(markdown_article * "\n" * markdown_article, 48)
const unicode_history = history(unicode_article, 72)
const mixed = mixed_history()
const default_style = Tachikoma.Style(; fg=Tachikoma.ColorRGB(222, 224, 225))
const bold_style = Tachikoma.Style(; fg=Tachikoma.ColorRGB(104, 183, 141), bold=true)
const ascii_spans = [Tachikoma.Span(repeat("ASCII Julia transcript text with spaces and formatting. ", 145), default_style),
    Tachikoma.Span(repeat("bold command output with lots of characters. ", 45), bold_style)]
const unicode_spans = [Tachikoma.Span(repeat("λ日本語🚀 and ascii text. ", 65), default_style),
    Tachikoma.Span("more output in ASCII ", bold_style)]

function workloads(module_value)
    Dict(
        # Entire production conversation layout: markdown parse, styling, wrap,
        # message assembly. Includes 96 representative assistant responses.
        "integration/markdown-96-messages" => () -> module_value.conversation_lines(markdown_history, 78),
        "integration/long-markdown-48-messages" => () -> module_value.conversation_lines(long_history, 112),
        "integration/mixed-96-messages" => () -> module_value.conversation_lines(mixed, 78),
        "integration/unicode-72-messages" => () -> module_value.conversation_lines(unicode_history, 78),
        "wrap/ascii-styled-spans" => () -> module_value.wrap_markdown_spans(ascii_spans, 78),
        "wrap/unicode-styled-spans" => () -> module_value.wrap_markdown_spans(unicode_spans, 78),
    )
end
const baseline_workloads = workloads(BaselineLayout)
const candidate_workloads = workloads(CandidateLayout)

# Stable comparison includes each span's text and style, not only total width.
function canonical(value)
    return [(role=role, lines=(line isa String ? line :
        [(content=span.content, style=repr(span.style)) for span in line]))
        for (line, role) in value]
end
canonical_spans(value) = [[(content=span.content, style=repr(span.style)) for span in row] for row in value]
function trial(f)
    GC.gc()
    times = Int[]
    for _ in 1:11
        before = time_ns()
        f()
        push!(times, time_ns() - before)
    end
    return (; times_ns=times, median_ns=median(times),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end
function bootstrap_lower(improvements)
    state = UInt64(0xcadecafe1251)
    draws = Float64[]
    for _ in 1:10000
        sample = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(sample, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(draws, median(sample))
    end
    return quantile(draws, 0.025)
end
function profile_case(f, name)
    f()
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 350_000_000
        while time_ns() < deadline
            f()
        end
    end
    open(joinpath(output_dir, name * "-cpu.txt"), "w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 f()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(allocation -> !isempty(allocation.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for location in allocation.stacktrace
            if occursin("transcript.jl", string(location.file))
                frame = location
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(; site, count=value[1], bytes=value[2]) for (site, value) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(output_dir, name * "-allocation-sites.json"), JSON.json((sample_rate=0.05, sites=records)))
    Profile.Allocs.clear()
end

const baseline_sha = readchomp(`git -C $baseline_dir rev-parse HEAD`)
const candidate_sha = readchomp(`git -C $candidate_dir rev-parse HEAD`)
const test_project = joinpath(candidate_dir, "test/Project.toml")
const baseline_project = joinpath(baseline_dir, "test/Project.toml")
const manifest = joinpath(candidate_dir, "test/Manifest.toml")
const metadata = (; baseline_sha, candidate_sha, baseline_dir, candidate_dir,
    julia_version=string(VERSION), julia_threads=Threads.nthreads(),
    cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS, architecture=string(Sys.ARCH),
    os=string(Sys.KERNEL), project_sha256=bytes2hex(sha256(read(test_project))),
    baseline_project_sha256=bytes2hex(sha256(read(baseline_project))),
    manifest_sha256=isfile(manifest) ? bytes2hex(sha256(read(manifest))) : nothing,
    tachikoma_version=string(Base.pkgversion(Tachikoma)),
    commonmark_version=string(Base.pkgversion(CommonMark)),
    pairs=7, repetitions_per_pair_side=11, warmup_calls_per_case=6,
    alternating_order="AB,BA,AB,BA,AB,BA,AB",
    bootstrap="10,000 fixed-seed paired median bootstrap draws, 2.5% lower quantile",
    integration="actual production conversation_lines: parse markdown, generate styled spans, wrap, assemble messages",
    workloads=sort!(collect(keys(baseline_workloads))))
write(joinpath(output_dir, "environment.json"), JSON.json(metadata))

results = Dict{String,Any}()
for name in sort!(collect(keys(baseline_workloads)))
    old = baseline_workloads[name]
    new = candidate_workloads[name]
    normalize = startswith(name, "wrap/") ? canonical_spans : canonical
    expected = normalize(old())
    isequal(expected, normalize(new())) || error("Candidate correctness mismatch: " * name)
    for _ in 1:6
        old(); new()
    end
    baseline_trials = Any[]
    candidate_trials = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, trial(old))
            push!(candidate_trials, trial(new))
        else
            push!(candidate_trials, trial(new))
            push!(baseline_trials, trial(old))
        end
    end
    improvements = [1.0 - candidate_trials[i].median_ns / baseline_trials[i].median_ns for i in 1:7]
    result = (; baseline=baseline_trials, candidate=candidate_trials,
        paired_improvements=improvements, median_improvement=median(improvements),
        ci95_lower_improvement=bootstrap_lower(improvements),
        minimum_pair_improvement=minimum(improvements),
        baseline_median_allocations=median(getproperty.(baseline_trials, :allocation_count)),
        candidate_median_allocations=median(getproperty.(candidate_trials, :allocation_count)),
        baseline_median_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_median_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        correctness="exact text, style and line boundaries match")
    results[name] = result
    write(joinpath(output_dir, "paired-raw.json"), JSON.json((; metadata, results)))
    println(name, ": median=", round(100 * result.median_improvement; digits=2),
        "%, lower95=", round(100 * result.ci95_lower_improvement; digits=2),
        "%, minimumPair=", round(100 * result.minimum_pair_improvement; digits=2), "%")
    flush(stdout)
end
profile_case(baseline_workloads["integration/markdown-96-messages"], "baseline-integration")
profile_case(candidate_workloads["integration/markdown-96-messages"], "candidate-integration")
profile_case(baseline_workloads["wrap/ascii-styled-spans"], "baseline-wrap")
profile_case(candidate_workloads["wrap/ascii-styled-spans"], "candidate-wrap")
representative = results["integration/markdown-96-messages"]
no_regressions = all(result -> result.median_improvement >= -0.05 &&
    result.ci95_lower_improvement >= -0.10, values(results))
passed = representative.median_improvement > 0.10 &&
    representative.ci95_lower_improvement > 0.10 &&
    representative.minimum_pair_improvement > 0.10 && no_regressions
write(joinpath(output_dir, "gate.json"), JSON.json((; passed, no_regressions,
    median_improvement=representative.median_improvement,
    ci95_lower_improvement=representative.ci95_lower_improvement,
    minimum_pair_improvement=representative.minimum_pair_improvement)))
println("PERFORMANCE_GATE=", passed ? "PASS" : "FAIL")
passed || error("Performance gate failed; do not open a PR")
