using JuliaForever2, BenchmarkTools, JSON, SHA, Statistics, Profile

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

# Exact native editor navigation reducer, shared between baseline and candidate.
module EditorNavigation
    include(joinpath(@__DIR__, "..", "..", "ext", "terminal", "editor_text_actions.jl"))
end

const primary_text = repeat("日本語 Julia λ-code 42, Καλημέρα! café naïve 😀👩‍💻 path/to/file—test.\n", 260)
const medium_text = repeat("日本語 Julia λ-code 42, Καλημέρα! café naïve 😀👩‍💻 path/to/file—test.\n", 105)
const emoji_text = repeat("🚀👩‍🚀 ZWJ👨‍👩‍👧‍👦, e\u0301 + 𝄞: हिन्दी 中文! test\n", 160)
const punctuation_text = repeat("words[]{}⇢测试; a+b=c, π/σ? punctuation\n", 230)
const short_text = repeat("café 中文 λ/β word! ", 18)
const input_json = JSON.json(Dict("text" => primary_text, "values" => collect(1:150)))
const baseline_messages = [Baseline.Message(isodd(index) ? :user : :assistant,
    repeat("Message $(index) about Unicode text and punctuation. ", 10))
    for index in 1:45]
const candidate_messages = [Candidate.Message(isodd(index) ? :user : :assistant,
    repeat("Message $(index) about Unicode text and punctuation. ", 10))
    for index in 1:45]

function editor_response(package, text)
    segments = package.WordSegmentation.segments(text)
    # This is the actual editor word-motion reducer on the ICU segments.
    atoms = [(; segment..., atomic=false) for segment in segments]
    forward = EditorNavigation.editor_word_distance(copy(atoms), 1, EditorNavigation.editor_input_space)
    backward = EditorNavigation.editor_word_distance(copy(atoms), -1, EditorNavigation.editor_input_space)
    joined = join(segment.text for segment in segments)
    JSON.json(Dict("forward_chars" => forward, "backward_chars" => backward,
        "segments" => length(segments), "words" => count(segment -> segment.word, segments),
        "text_sha256" => bytes2hex(sha256(joined)), "total_chars" => length(joined)))
end

function mixed_response(package, text)
    word_navigation = JSON.parse(editor_response(package, text))
    title = package.fallback_session_title(text)
    transcript = package.session_markdown([
        package.Message(:user, text), package.Message(:assistant, "Message received.")];
        title="Unicode conversation")
    JSON.json(Dict("navigation" => word_navigation, "title" => title,
        "transcript_sha256" => bytes2hex(sha256(transcript)),
        "transcript_bytes" => ncodeunits(transcript)))
end

const workloads = [
    (name="integration/unicode-editor-navigation-json", work=package -> editor_response(package, primary_text),
        scope="changed: ICU segmentation, actual editor word-distance reducer and JSON response on long multilingual input", primary=true),
    (name="integration/medium-editor-navigation-json", work=package -> editor_response(package, medium_text),
        scope="changed: representative medium Unicode navigation and JSON response", primary=false),
    (name="integration/emoji-combining-navigation", work=package -> editor_response(package, emoji_text),
        scope="changed: astral emoji, combining characters, ICU and editor navigation", primary=false),
    (name="integration/punctuation-navigation", work=package -> editor_response(package, punctuation_text),
        scope="changed: multilingual punctuation and word-selection processing", primary=false),
    (name="integration/mixed-navigation-title-markdown", work=package -> mixed_response(package, medium_text),
        scope="changed/mixed: ICU navigation, unchanged title formatting and Markdown transcript to JSON", primary=false),
    (name="secondary/short-unicode-navigation", work=package -> editor_response(package, short_text),
        scope="changed: short non-ASCII editor input", primary=false),
    (name="control/unchanged-json-decoder", work=package -> begin
        value = JSON.parse(input_json)
        (length(value["text"]), length(value["values"]), value["values"][end])
    end, scope="unchanged: JSON parser only; does not call ICU segmentation", primary=false),
    (name="control/unchanged-markdown-transcript", work=package -> begin
        records = package === Baseline ? baseline_messages : candidate_messages
        result = package.session_markdown(records; title="Unchanged history export")
        (ncodeunits(result), bytes2hex(sha256(result)))
    end, scope="unchanged: Markdown renderer only; no ICU segmentation", primary=false),
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
    "icu_jll_version" => string(Base.pkgversion(Candidate.WordSegmentation.ICU_jll)),
    "baseline_project_sha256" => bytes2hex(sha256(read(joinpath(baseline_directory,"Project.toml")))),
    "candidate_project_sha256" => bytes2hex(sha256(read("Project.toml"))),
    "benchmark_project_sha256" => bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs" => 7, "samples_per_trial" => 12, "evals" => 1,
    "seconds" => 4.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 deterministic paired-trial bootstrap resamples of 7 independent paired medians",
    "environment_match" => "same process, Julia binary, source dependencies, machine, threads, fixtures",
    "primary_characters" => length(primary_text),
    "medium_characters" => length(medium_text))
write(joinpath(evidence_directory, "environment.json"), JSON.json(environment))

baseline_sha == "b534b18caac44e377700b3939b48ddff04185143" ||
    error("Baseline is not the pinned latest main commit")
VERSION == v"1.13.3" || error("Julia is not pinned to 1.13.3")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Baseline and candidate source dependency declarations differ")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Loaded candidate does not match checkout")
isempty(readchomp(Cmd(["git","-C",baseline_directory,"diff","HEAD","--","src"]))) ||
    error("Baseline worktree has source changes")

function verify_semantics()
    values = [primary_text, medium_text, emoji_text, punctuation_text, short_text,
        "", "a", "\r\n", "👩‍🚀", "e\u0301", "\ufeffHello 🌍", "x\u00a0y\nz",
        SubString("x日本語 café😀z", 2, prevind("x日本語 café😀z", lastindex("x日本語 café😀z")))]
    for (index, value) in enumerate(values)
        left = Baseline.WordSegmentation.segments(value)
        right = Candidate.WordSegmentation.segments(value)
        isequal(left, right) || error("ICU segment contract differs on fixture $index")
        join(segment.text for segment in right) == String(value) ||
            error("ICU segments do not reconstruct fixture $index")
        for segment in right
            0 <= segment.start <= segment.stop <= length(value) ||
                error("ICU returned an invalid character interval")
            segment.text == String(first(chop(value; head=segment.start, tail=0),
                    segment.stop - segment.start)) ||
                error("ICU text does not match reported Unicode character interval")
        end
    end
    for item in workloads
        left, right = item.work(Baseline), item.work(Candidate)
        isequal(left, right) || error("Workload semantic contract failed for $(item.name)")
    end
    write(joinpath(evidence_directory,"contracts.json"), JSON.json(Dict(
        "passed" => true, "fixture_count" => length(values),
        "workloads" => length(workloads), "unicode_offsets" => true,
        "semantic_outputs_equal" => true, "zero_length_and_substring" => true,
        "editor_navigation" => true, "reconstruction" => true)))
end
try
    verify_semantics()
catch failure
    write(joinpath(evidence_directory,"contracts.json"), JSON.json(Dict(
        "passed" => false, "error" => sprint(showerror, failure))))
    rethrow()
end

"""Use BenchmarkTools for ALL performance timing and allocation measurements."""
function measured_trial(work)
    case = BenchmarkTools.@benchmarkable $(work)() samples=12 evals=1 seconds=4.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(case)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

"""Use paired medians as the independent unit, not individual BenchmarkTools samples."""
function paired_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    draws = Float64[]
    for _ in 1:20000
        sample = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(sample, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(draws, median(sample))
    end
    (lower=quantile(draws, 0.025), upper=quantile(draws, 0.975))
end

"""Profile CPU and allocation hotspots outside the timed BenchmarkTools trials."""
function profile_work(work, tag)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:5
        work()
    end
    open(joinpath(evidence_directory, tag * "-cpu.txt"),"w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.015 work()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(a -> !isempty(a.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for loc in allocation.stacktrace
            if endswith(string(loc.file), "word_segmentation.jl")
                frame = loc
                break
            end
        end
        site = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites, site, (0,0))
        sites[site] = (old[1]+1, old[2]+allocation.size)
    end
    rows = [Dict("location"=>key,"count"=>value[1],"bytes"=>value[2])
        for (key,value) in sites]
    sort!(rows;by=row->row["bytes"],rev=true)
    write(joinpath(evidence_directory,tag*"-allocation-sites.json"),
        JSON.json(Dict("sample_rate"=>0.015,"sites"=>first(rows,min(length(rows),150)))))
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
        push!(pairs, Dict("pair"=>pair, "first"=>isodd(pair) ? "baseline" : "candidate",
            "baseline"=>base_trial, "candidate"=>candidate_trial))
    end
    improvements = [1.0-row["candidate"]["median_ns"]/row["baseline"]["median_ns"] for row in pairs]
    interval = paired_confidence(improvements)
    results[workload.name] = Dict("scope"=>workload.scope,"primary"=>workload.primary,
        "pairs"=>pairs,"paired_improvements"=>improvements,
        "median_improvement"=>median(improvements),
        "confidence_lower"=>interval.lower,"confidence_upper"=>interval.upper)
    write(joinpath(evidence_directory,"raw-trials.json"),
        JSON.json(Dict("environment"=>environment,"workloads"=>results)))
    println(workload.name, ": improvement=",round(100*median(improvements);digits=2),
        "%, lower95=",round(100*interval.lower;digits=2),"%")
    flush(stdout)
end

profile_work(() -> editor_response(Baseline,primary_text), "baseline")
profile_work(() -> editor_response(Candidate,primary_text), "candidate")
const primary = results["integration/unicode-editor-navigation-json"]
const acceptable = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory,"gate.json"),JSON.json(Dict(
    "passed"=>acceptable,"primary_improvement"=>primary["median_improvement"],
    "primary_lower95"=>primary["confidence_lower"],
    "criterion"=>"primary median >=10% and paired bootstrap lower95 >10%; secondary median slowdowns strictly <10%; exact semantic equality",
    "slowdowns"=>[Dict("workload"=>name,"median_improvement"=>row["median_improvement"])
        for (name,row) in results if row["median_improvement"] < 0])))
acceptable || error("Experimental acceptance FAILED: no PR")
