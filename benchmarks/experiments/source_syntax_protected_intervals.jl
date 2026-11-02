using JuliaForever2, BenchmarkTools, JSON, Profile, SHA, Statistics

length(ARGS) == 2 || error("Expected BASELINE_WORKTREE and EVIDENCE_DIRECTORY")
const baseline_directory = realpath(ARGS[1])
const evidence_directory = abspath(ARGS[2])
mkpath(evidence_directory)

module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_directory, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

function json_fixture(count)
    output = IOBuffer()
    print(output, '{')
    for index in 1:count
        index > 1 && print(output, ',')
        print(output, "\"item_", index, "\":{\"value\":", index,
            ",\"enabled\":", isodd(index) ? "true" : "false",
            ",\"text\":\"record ", index, "\"}")
    end
    print(output, '}')
    String(take!(output))
end

const primary_json = json_fixture(2800)
const medium_json = json_fixture(1150)
const small_json = json_fixture(65)
const nested_json = JSON.json(Dict(
    "records" => [Dict("id" => index, "value" => "entry $(index)", "ok" => iseven(index))
        for index in 1:1650]))
const python_source = join([
    "def transform_$(index)(items):\n    return [value * $(index % 11 + 1) for value in items if value > 0]\n"
    for index in 1:220], "\n")
const html_source = join([
    "<section class=\"row\"><script>const item$(index) = {value: $(index), ready: true};</script><p>item $(index)</p></section>"
    for index in 1:95], "\n")
const transcript_texts = [repeat("User request $(index): retain the highlighting contract. ", 4)
    for index in 1:36]
const baseline_messages = [Baseline.Message(isodd(index) ? :user : :assistant, content)
    for (index, content) in enumerate(transcript_texts)]
const candidate_messages = [Candidate.Message(isodd(index) ? :user : :assistant, content)
    for (index, content) in enumerate(transcript_texts)]

function syntax_response(package, language, source)
    result = package.source_syntax_highlight(language, source)
    JSON.json(Dict(
        "status" => String(result.status),
        "language" => result.language,
        "source_bytes" => ncodeunits(source),
        "colors" => [(item.first, item.last, String(item.kind), item.priority)
            for item in result.colors]))
end

function mixed_response(package)
    json_colors = JSON.parse(syntax_response(package, "json", medium_json))
    python_colors = JSON.parse(syntax_response(package, "python", python_source))
    messages = package === Baseline ? baseline_messages : candidate_messages
    transcript = package.session_markdown(messages; title="Syntax and transcript")
    JSON.json(Dict(
        "json_highlight" => json_colors,
        "python_highlight" => python_colors,
        "transcript" => transcript,
        "transcript_sha256" => bytes2hex(sha256(transcript))))
end

const workloads = [
    (name="integration/large-json-syntax-response", primary=true,
        scope="changed: full Tree-sitter JSON highlighting of 2,800 object records into JSON color response",
        work=package -> syntax_response(package, "json", primary_json)),
    (name="integration/medium-json-syntax-response", primary=false,
        scope="changed: medium JSON code highlighting and JSON response",
        work=package -> syntax_response(package, "json", medium_json)),
    (name="integration/nested-json-syntax-response", primary=false,
        scope="changed: nested object/array source highlighting and JSON response",
        work=package -> syntax_response(package, "json", nested_json)),
    (name="integration/mixed-syntax-and-transcript", primary=false,
        scope="changed/mixed: JSON and Python syntax highlighting, Markdown transcript and JSON response",
        work=package -> mixed_response(package)),
    (name="secondary/small-json-syntax-response", primary=false,
        scope="changed: small JSON inputs exercising protected capture lookup",
        work=package -> syntax_response(package, "json", small_json)),
    (name="secondary/python-syntax-response", primary=false,
        scope="changed shared syntax function, without JSON protected object-key spans",
        work=package -> syntax_response(package, "python", python_source)),
    (name="secondary/html-syntax-response", primary=false,
        scope="changed shared syntax function; HTML embedded-language injection",
        work=package -> syntax_response(package, "html", html_source)),
    (name="control/unchanged-json-decoder", primary=false,
        scope="unchanged: JSON parser only; never enters syntax highlighting",
        work=package -> begin
            value = JSON.parse(primary_json)
            (length(value), value["item_1"]["value"], value["item_2800"]["text"])
        end),
]

const baseline_sha = readchomp(Cmd(["git","-C",baseline_directory,"rev-parse","HEAD"]))
const candidate_sha = readchomp(Cmd(["git","rev-parse","HEAD"]))
const environment = Dict(
    "baseline_sha" => baseline_sha, "candidate_sha" => candidate_sha,
    "julia_version" => string(VERSION), "threads" => Threads.nthreads(),
    "cpu" => Sys.CPU_NAME, "logical_cpus" => Sys.CPU_THREADS,
    "architecture" => string(Sys.ARCH), "operating_system" => string(Sys.KERNEL),
    "benchmarktools_version" => string(Base.pkgversion(BenchmarkTools)),
    "json_version" => string(Base.pkgversion(JSON)),
    "source_project_sha256" => bytes2hex(sha256(read("Project.toml"))),
    "baseline_source_project_sha256" => bytes2hex(sha256(read(joinpath(baseline_directory, "Project.toml")))),
    "benchmark_project_sha256" => bytes2hex(sha256(read("benchmarks/Project.toml"))),
    "pairs" => 7, "samples_per_trial" => 12, "evals" => 1,
    "seconds" => 4.0, "gctrial" => true, "gcsample" => false,
    "order" => "AB BA AB BA AB BA AB",
    "confidence" => "20,000 deterministic paired-trial bootstrap resamples, one median per independent pair",
    "environment_match" => "same process, Julia binary, project dependencies, machine, threads, fixtures",
    "primary_bytes" => ncodeunits(primary_json),
    "medium_bytes" => ncodeunits(medium_json))
write(joinpath(evidence_directory,"environment.json"), JSON.json(environment))

baseline_sha == "1f176226e2c015d2496816bb11cfa7cd3c9ebc02" ||
    error("Baseline does not match fresh main")
VERSION == v"1.13.3" || error("Experimental Julia version must be 1.13.3")
Threads.nthreads() == 2 || error("Expected two Julia threads")
read("Project.toml") == read(joinpath(baseline_directory, "Project.toml")) ||
    error("Candidate and baseline source dependencies differ")
realpath(pkgdir(JuliaForever2)) == realpath(".") ||
    error("Candidate module does not match checked-out repository")
isempty(readchomp(Cmd(["git","-C",baseline_directory,"diff","HEAD","--","src"]))) ||
    error("Baseline worktree source has uncommitted changes")
ncodeunits(primary_json) <= 262_144 || error("Primary source exceeds syntax byte budget")

function verify_semantics()
    extra = [
        ("json", "{}"), ("json", "[]"),
        ("json", "{\"x\":\"a\\nb\", \"x\":false, \"a\":null}"),
        ("json", "{\"nested\":{\"wide\":[{\"x\":1},{\"y\":2}]}}"),
        ("json", "{\"unicode\":\"日本語 😀 café\", \"é\": [true,false]}"),
        ("json", "{\"broken\": 1, \"other\": "), ("json", json_fixture(180)),
        ("html", "<div data-x='42'><script>const x = 5;</script></div>"),
        ("html", "<!-- heading --><style>.x{color:red}</style>"),
        ("python", "@decorator\ndef f(x):\n    return x * 3\n"),
        ("python", "print('héllo')\n"), ("bash", "echo hello && printf 'ok'\n"),
        ("typescript", "const fn = <T>(value: T) => value;\n"),
        ("toml", "[section]\nlabel=\"value\"\n")]
    for (index, (language, source)) in enumerate(extra)
        left = syntax_response(Baseline, language, source)
        right = syntax_response(Candidate, language, source)
        isequal(left, right) || error("Syntax fixture output mismatch at $(index), $(language)")
    end
    for workload in workloads
        left, right = workload.work(Baseline), workload.work(Candidate)
        isequal(left, right) || error("Measured workload output contract differs: $(workload.name)")
    end
    JSON.parse(primary_json) isa AbstractDict ||
        error("Representative JSON fixture must be valid")
    write(joinpath(evidence_directory,"contracts.json"),JSON.json(Dict(
        "passed"=>true,"extra_fixtures"=>length(extra),"workloads"=>length(workloads),
        "exact_semantic_output_equality"=>true,"nested_intervals"=>true,
        "json_highlight_and_serialization"=>true,"mixed_workflow"=>true)))
end
try
    verify_semantics()
catch failure
    write(joinpath(evidence_directory,"contracts.json"),
        JSON.json(Dict("passed"=>false,"error"=>sprint(showerror,failure))))
    rethrow()
end

"""BenchmarkTools owns every timed measurement, sample and allocation count."""
function measured_trial(work)
    case = BenchmarkTools.@benchmarkable $(work)() samples=12 evals=1 seconds=4.0 gctrial=true gcsample=false
    trial = BenchmarkTools.run(case)
    Dict("samples_ns" => trial.times, "gc_ns" => trial.gctimes,
        "median_ns" => median(trial.times), "memory_bytes" => trial.memory,
        "allocations" => trial.allocs, "samples" => length(trial.times))
end

"""Independent paired trial medians, not samples within the BenchmarkTools trials."""
function paired_confidence(improvements)
    state = UInt64(0x64df23a98bd9b3d7)
    draws = Float64[]
    for _ in 1:20000
        resample = Float64[]
        for _ in eachindex(improvements)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(resample, improvements[Int(mod(state, UInt64(length(improvements)))) + 1])
        end
        push!(draws, median(resample))
    end
    (lower=quantile(draws,0.025),upper=quantile(draws,0.975))
end

function profile_work(work, name)
    work()
    Profile.clear()
    Profile.@profile for _ in 1:3
        work()
    end
    open(joinpath(evidence_directory,name * "-cpu.txt"),"w") do io
        Profile.print(io; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.01 work()
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in Iterators.filter(item -> !isempty(item.stacktrace), Profile.Allocs.fetch().allocs)
        frame = first(allocation.stacktrace)
        for loc in allocation.stacktrace
            if endswith(string(loc.file), "source_syntax.jl")
                frame = loc
                break
            end
        end
        key = string(frame.file, ":", frame.line, " ", frame.func)
        old = get(sites,key,(0,0))
        sites[key] = (old[1] + 1, old[2] + allocation.size)
    end
    rows = [Dict("location"=>key,"count"=>value[1],"bytes"=>value[2])
        for (key,value) in sites]
    sort!(rows; by=row->row["bytes"],rev=true)
    write(joinpath(evidence_directory,name*"-allocation-sites.json"),
        JSON.json(Dict("sample_rate"=>0.01,"sites"=>first(rows,min(length(rows),200)))))
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
        push!(pairs,Dict("pair"=>pair,"first"=>isodd(pair) ? "baseline" : "candidate",
            "baseline"=>base_trial,"candidate"=>candidate_trial))
    end
    improvements = [1.0 - row["candidate"]["median_ns"]/row["baseline"]["median_ns"] for row in pairs]
    interval = paired_confidence(improvements)
    results[workload.name] = Dict("scope"=>workload.scope,"primary"=>workload.primary,
        "pairs"=>pairs,"paired_improvements"=>improvements,
        "median_improvement"=>median(improvements),
        "confidence_lower"=>interval.lower,"confidence_upper"=>interval.upper)
    write(joinpath(evidence_directory,"raw-trials.json"),
        JSON.json(Dict("environment"=>environment,"workloads"=>results)))
    println(workload.name, ": median improvement=",round(100 * median(improvements);digits=2),
        "% lower95=",round(100 * interval.lower;digits=2),"%")
    flush(stdout)
end

profile_work(() -> syntax_response(Baseline, "json", primary_json),"baseline")
profile_work(() -> syntax_response(Candidate, "json", primary_json),"candidate")
const primary = results["integration/large-json-syntax-response"]
const passed = primary["median_improvement"] >= 0.10 &&
    primary["confidence_lower"] > 0.10 &&
    all(row["median_improvement"] > -0.10 for row in values(results))
write(joinpath(evidence_directory,"gate.json"),JSON.json(Dict(
    "passed"=>passed,"primary_median"=>primary["median_improvement"],
    "primary_lower95"=>primary["confidence_lower"],
    "criterion"=>"primary >=10% median and paired-bootstrap 95% lower bound >10%; each secondary median slowdown <10%; exact semantic equality",
    "slowdowns"=>[Dict("workload"=>name,"median_improvement"=>row["median_improvement"])
        for (name,row) in results if row["median_improvement"] < 0])))
passed || error("Experimental acceptance gate FAILED: no PR")
