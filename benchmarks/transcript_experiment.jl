using JSON, JuliaForever2, Profile, SHA, Statistics

length(ARGS) == 2 || error("Usage: julia --project=benchmarks benchmarks/transcript_experiment.jl BASELINE_WORKTREE OUTPUT_DIRECTORY")
const baseline_dir = realpath(ARGS[1])
const output_dir = abspath(ARGS[2])
mkpath(output_dir)
const candidate_dir = realpath(joinpath(@__DIR__, ".."))
readchomp(`git -C $baseline_dir diff HEAD -- ext/terminal/transcript.jl`) == "" || error("Baseline worktree is dirty")
realpath(pkgdir(JuliaForever2)) == candidate_dir || error("Candidate package path mismatch")

module BaselineTranscript
    const TranscriptLine = Tuple{String,Symbol}
end
module CandidateTranscript
    const TranscriptLine = Tuple{String,Symbol}
end

# Load the original, production wrapping and transcript-layout functions from both
# worktrees. No handcrafted substitute is used for either implementation.
function include_layout!(module_value, directory)
    file = joinpath(directory, "ext", "terminal", "transcript.jl")
    source = read(file, String)
    wrap = first(split(source, "\nfunction wrap_markdown_spans"; limit=2))
    remainder = split(source, "\nfunction message_layout_key"; limit=2)[2]
    layout = first(split("\nfunction message_layout_key" * remainder, "\nfunction transcript_lines!"; limit=2))
    Base.include_string(module_value, wrap * "\n" * layout, file)
end
include_layout!(BaselineTranscript, baseline_dir)
include_layout!(CandidateTranscript, candidate_dir)

const ascii_message = repeat("Julia executes tools and renders transcript history; fast paths must retain exact whitespace. ", 7)
const unicode_message = repeat("Julia λ: 日本語 and cafe\u0301; a measured Unicode transcript still requires grapheme-aware layout. ", 7)
function history_fixture(content)
    messages = JuliaForever2.Message[]
    for index in 1:240
        role = index % 3 == 1 ? :user : index % 3 == 2 ? :assistant : :code_result
        push!(messages, role == :assistant ? JuliaForever2.Message(role, content, :code) : JuliaForever2.Message(role, content))
    end
    return messages
end
const ascii_history = history_fixture(ascii_message)
const unicode_history = history_fixture(unicode_message)
const ascii_long = repeat("x", 6000)
const punctuation = repeat("   abc  def ghijklmnop    abc def  ", 75)
const control = repeat("a\tb\rc\f", 120)

function make_cases(module_value)
    Dict(
        "transcript/ascii-240-messages" => () -> module_value.conversation_lines(ascii_history, 78),
        "transcript/unicode-240-messages" => () -> module_value.conversation_lines(unicode_history, 78),
        "wrap/ascii-long-word" => () -> module_value.wrap_conversation_line(ascii_long, 78),
        "wrap/ascii-whitespace" => () -> module_value.wrap_conversation_line(punctuation, 40),
        "wrap/unicode" => () -> module_value.wrap_conversation_line(unicode_message, 78),
        "wrap/control-characters" => () -> module_value.wrap_conversation_line(control, 33),
    )
end
const baseline_cases = make_cases(BaselineTranscript)
const candidate_cases = make_cases(CandidateTranscript)

function trial(f)
    GC.gc()
    durations = Int[]
    for _ in 1:19
        started = time_ns()
        f()
        push!(durations, time_ns() - started)
    end
    return (; times_ns=durations, median_ns=median(durations),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end

# Deterministic bootstrap of the independent, alternating paired medians;
# the minimum of all seven pair improvements must ALSO exceed 10%.
function lower_bootstrap_bound(improvements)
    state = UInt64(0x5a175bde)
    samples = Float64[]
    for _ in 1:10000
        drawn = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(drawn, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(samples, median(drawn))
    end
    return quantile(samples, 0.025)
end

function compare_cases()
    results = Dict{String,Any}()
    for name in sort!(collect(keys(baseline_cases)))
        original, changed = baseline_cases[name], candidate_cases[name]
        expected = original()
        isequal(expected, changed()) || error("Result differs for " * name)
        for _ in 1:30
            original(); changed()
        end
        original_trials = Any[]
        changed_trials = Any[]
        for index in 1:7
            if isodd(index)
                push!(original_trials, trial(original))
                push!(changed_trials, trial(changed))
            else
                push!(changed_trials, trial(changed))
                push!(original_trials, trial(original))
            end
        end
        reductions = [1.0 - changed_trials[i].median_ns / original_trials[i].median_ns for i in 1:7]
        median_reduction = median(reductions)
        lower_bound = lower_bootstrap_bound(reductions)
        results[name] = (; baseline=original_trials, candidate=changed_trials,
            paired_improvements=reductions, median_improvement=median_reduction,
            ci95_lower_improvement=lower_bound, minimum_pair_improvement=minimum(reductions),
            baseline_median_bytes=median(getproperty.(original_trials, :allocated_bytes)),
            candidate_median_bytes=median(getproperty.(changed_trials, :allocated_bytes)),
            baseline_median_allocations=median(getproperty.(original_trials, :allocation_count)),
            candidate_median_allocations=median(getproperty.(changed_trials, :allocation_count)),
            correctness="exact outputs match")
        println(name, ": median ", round(100 * median_reduction; digits=2),
            "%, bootstrap 95% lower ", round(100 * lower_bound; digits=2),
            "%, worst pair ", round(100 * minimum(reductions); digits=2), "%")
        flush(stdout)
    end
    return results
end

function profile_case(f, name)
    f()
    Profile.clear()
    Profile.@profile begin
        deadline = time_ns() + 400_000_000
        while time_ns() < deadline
            f()
        end
    end
    open(joinpath(output_dir, name * "-cpu.txt"), "w") do output
        Profile.print(output; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=1.0 f()
    allocations = Profile.Allocs.fetch().allocs
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(allocation -> !isempty(allocation.stacktrace), allocations)
        frame = first(allocation.stacktrace)
        for candidate in allocation.stacktrace
            if occursin("ext/terminal/transcript.jl", string(candidate.file))
                frame = candidate
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(; site, count=record[1], bytes=record[2]) for (site, record) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(joinpath(output_dir, name * "-allocations.json"), JSON.json((sample_rate=1.0, sites=records)))
    Profile.Allocs.clear()
end

const metadata = (baseline_commit=readchomp(`git -C $baseline_dir rev-parse HEAD`),
    candidate_commit=readchomp(`git -C $candidate_dir rev-parse HEAD`),
    julia_version=string(VERSION), julia_threads=Threads.nthreads(), cpu=Sys.CPU_NAME,
    logical_cpus=Sys.CPU_THREADS, architecture=string(Sys.ARCH),
    benchmark_project_sha256=bytes2hex(sha256(read(joinpath(candidate_dir, "benchmarks", "Project.toml")))),
    juliaforever_version=string(Base.pkgversion(JuliaForever2)),
    json_version=string(Base.pkgversion(JSON)), pairs=7, repetitions_per_pair_side=19,
    warmup_calls_per_case=30, pairing="AB,BA,AB,BA,AB,BA,AB",
    paired_ci_method="10,000 deterministic bootstrap resamples of paired sample medians",
    cpu_profile_ns=400_000_000,
    fixtures=(ascii_history_messages=length(ascii_history), unicode_history_messages=length(unicode_history),
        ascii_message_bytes=ncodeunits(ascii_message), unicode_message_bytes=ncodeunits(unicode_message)),
    no_network="deterministic local terminal transcript construction")
write(joinpath(output_dir, "environment.json"), JSON.json(metadata))
results = compare_cases()
write(joinpath(output_dir, "paired-raw.json"), JSON.json((; metadata, results)))
for (name, function_value) in (("baseline-transcript", baseline_cases["transcript/ascii-240-messages"]),
        ("candidate-transcript", candidate_cases["transcript/ascii-240-messages"]))
    profile_case(function_value, name)
end
representative = results["transcript/ascii-240-messages"]
passed = representative.median_improvement > 0.10 &&
    representative.ci95_lower_improvement > 0.10 &&
    representative.minimum_pair_improvement > 0.10 &&
    all(value -> value.median_improvement >= -0.05 && value.ci95_lower_improvement >= -0.10, values(results))
write(joinpath(output_dir, "gate.json"), JSON.json((; passed,
    representative_median=representative.median_improvement,
    representative_lower95=representative.ci95_lower_improvement,
    representative_minimum=representative.minimum_pair_improvement,
    no_material_regressions=all(value -> value.median_improvement >= -0.05 && value.ci95_lower_improvement >= -0.10, values(results)))))
println("PERFORMANCE_GATE=", passed ? "PASS" : "FAIL")
passed || error("No qualifying representative improvement; experimental candidate must not become a PR")
