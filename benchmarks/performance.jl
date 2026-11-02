using BenchmarkTools, JSON, JuliaForever2, Profile, SHA, Statistics

"""Read arguments: baseline directory, output JSON, seconds per trial, pairs, profiles, sample cap."""
function benchmark_options(arguments)
    baseline = abspath(get(arguments, 1, joinpath(@__DIR__, "..", "..", "Julia-Forever-2-baseline")))
    output = abspath(get(arguments, 2, joinpath(@__DIR__, "performance-results.json")))
    seconds = parse(Float64, get(arguments, 3, "0.3"))
    pairs = parse(Int, get(arguments, 4, "3"))
    profiles = get(arguments, 5, "true") == "true"
    samples = parse(Int, get(arguments, 6, "1000"))
    seconds > 0 && pairs > 0 && samples > 0 || error("Trial seconds, pair count, and sample cap must be positive.")
    isfile(joinpath(baseline, "src", "JuliaForever2.jl")) || error("Baseline source directory was not found.")
    return (; baseline, output, seconds, pairs, profiles, samples)
end

const OPTIONS = benchmark_options(ARGS)
const CANDIDATE_DIRECTORY = realpath(dirname(@__DIR__))
realpath(pkgdir(JuliaForever2)) == CANDIDATE_DIRECTORY || error("Loaded JuliaForever2 is not the candidate repository.")
const BASELINE_DIFF = readchomp(`git -C $(OPTIONS.baseline) diff HEAD -- src ext`)
isempty(BASELINE_DIFF) || error("Baseline src/ext differs from its recorded commit.")
module OriginalContainer end
Base.include(OriginalContainer, joinpath(OPTIONS.baseline, "src", "JuliaForever2.jl"))
const Original = OriginalContainer.JuliaForever2
module OriginalWrapping end
module CandidateWrapping end

"""Load the actual wrapping kernel and its leading helpers without loading the terminal extension."""
function load_wrapping!(destination, directory)
    path = joinpath(directory, "ext", "terminal", "transcript.jl")
    source = first(split(read(path, String), "\nfunction wrap_markdown_spans"; limit=2))
    Base.include_string(destination, source, path)
end
load_wrapping!(OriginalWrapping, OPTIONS.baseline)
load_wrapping!(CandidateWrapping, dirname(@__DIR__))

const ORIGINAL_API = (
    decoder=sink -> Original.SSEDecoder(sink),
    context=sink -> Original.ExecutionContext(; event_sink=sink),
    stream=(context, interval) -> Original.ChatGPTStream(context; progress_interval=interval),
    progress=text -> Original.protocol_progress(Original.CodeModePolicy(), text),
    provider=(directory, transport) -> Original.OpenAIProvider(directory, transport, reject_refresh; model="benchmark-model", catalog_ttl=Inf),
    request=() -> Original.model_request(Original.CodeModePolicy(), [Original.Message(:user, "Explain this Julia code.")]),
    respond=Original.respond,
    wrap=OriginalWrapping.wrap_conversation_line,
)
const CANDIDATE_API = (
    decoder=sink -> JuliaForever2.SSEDecoder(sink),
    context=sink -> JuliaForever2.ExecutionContext(; event_sink=sink),
    stream=(context, interval) -> JuliaForever2.ChatGPTStream(context; progress_interval=interval),
    progress=text -> JuliaForever2.protocol_progress(JuliaForever2.CodeModePolicy(), text),
    provider=(directory, transport) -> JuliaForever2.OpenAIProvider(directory, transport, reject_refresh; model="benchmark-model", catalog_ttl=Inf),
    request=() -> JuliaForever2.model_request(JuliaForever2.CodeModePolicy(), [JuliaForever2.Message(:user, "Explain this Julia code.")]),
    respond=JuliaForever2.respond,
    wrap=CandidateWrapping.wrap_conversation_line,
)

reject_refresh(arguments...) = error("Synthetic benchmark credentials unexpectedly requested refresh.")

"""Build deterministic valid SSE with Unicode, escapes, a completion event, and usage."""
function stream_fixture(content; delta_characters=48)
    response = JSON.json((kind="answer", content))
    characters = collect(response)
    deltas = [join(characters[index:min(index + delta_characters - 1, end)]) for index in 1:delta_characters:length(characters)]
    output = IOBuffer()
    for (index, delta) in enumerate(deltas)
        index % 16 == 0 && print(output, ": heartbeat\r\n")
        print(output, "event: response.output_text.delta\r\ndata: ",
            JSON.json((type="response.output_text.delta", delta)), "\r\n\r\n")
    end
    print(output, "data: ", JSON.json((type="response.completed",
        response=(usage=(input_tokens=512, output_tokens=256),))), "\r\n\r\ndata: [DONE]\r\n\r\n")
    return (; content, response, deltas, bytes=take!(output))
end

chunks(bytes, width) = [@view(bytes[index:min(index + width - 1, end)]) for index in 1:width:length(bytes)]

function write_chunks!(decoder, fragments)
    for fragment in fragments
        write(decoder, fragment)
    end
    return nothing
end

function sse_workload(make_decoder, fragments)
    events = Tuple{String,String,String}[]
    decoder = make_decoder(event -> push!(events, (event.event, event.data, event.id)))
    write_chunks!(decoder, fragments)
    return events
end

struct EventRecorder
    deltas::Vector{String}
    previews::Vector{Tuple{Symbol,String}}
end
EventRecorder() = EventRecorder(String[], Tuple{Symbol,String}[])
function (recorder::EventRecorder)(event)
    if event.kind == :provider_delta
        push!(recorder.deltas, event.data)
    elseif event.kind == :response_progress
        push!(recorder.previews, (event.data.progress.kind, event.data.progress.text))
    end
    return nothing
end

function pipeline_workload(api, fragments, interval)
    recorder = EventRecorder()
    context = api.context(recorder)
    stream = api.stream(context, interval)
    write_chunks!(api.decoder(stream), fragments)
    result = (completed=stream.completed, failed=stream.failed, text=String(take!(stream.text)),
        input_tokens=stream.usage.input_tokens, output_tokens=stream.usage.output_tokens,
        deltas=recorder.deltas, previews=recorder.previews)
    close(context)
    return result
end

struct ReplayTransport{C}
    fragments::C
    catalog::String
end
function (transport::ReplayTransport)(url, method, body, headers, context, sink)
    if method == "GET"
        (status=200, body=transport.catalog)
    else
        sink.sink.progress_interval = Inf
        write_chunks!(sink, transport.fragments)
        (status=200, body="")
    end
end

function provider_workload(api, provider, request)
    recorder = EventRecorder()
    context = api.context(recorder)
    response = api.respond(provider, request, context)
    close(context)
    return (kind=response.reply.kind, content=response.reply.content,
        input_tokens=response.usage.input_tokens, output_tokens=response.usage.output_tokens,
        deltas=recorder.deltas, previews=recorder.previews)
end

progress_value(::Nothing) = nothing
progress_value(progress) = (progress.kind, progress.text)

protocol_contents() = (ascii=repeat("Julia uses specialized methods and reusable buffers. ", 120), unicode=repeat("Julia λ ∑ 日本語 café e\u0301 🧪. ", 120), escapes=repeat("quoted \"text\"\n\tpath\\segment\r\n", 120))

function workloads(api, fixture, directory)
    cases = Dict{String,Any}()
    for width in (64, 1024, length(fixture.bytes))
        label = width == length(fixture.bytes) ? "full" : string(width)
        let fragments = chunks(fixture.bytes, width)
            cases["sse/chunk_" * label] = () -> sse_workload(api.decoder, fragments)
        end
    end
    for (name, content) in pairs(protocol_contents())
        response = JSON.json((kind="answer", content))
        cases["protocol/" * string(name)] = () -> progress_value(api.progress(response))
        cases["wrap/" * string(name)] = () -> api.wrap(content, 78)
    end
    fragments = chunks(fixture.bytes, 1024)
    cases["pipeline/coalesced"] = () -> pipeline_workload(api, fragments, Inf)
    cases["pipeline/every_delta"] = () -> pipeline_workload(api, fragments, 0.0)
    transport = ReplayTransport(fragments, JSON.json((models=[(visibility="list", slug="benchmark-model")],)))
    provider = api.provider(directory, transport)
    request = api.request()
    cases["provider/respond_coalesced"] = () -> provider_workload(api, provider, request)
    return cases
end

function trial_record(trial)
    durations = trial.times
    return (; minimum_ns=minimum(durations), median_ns=median(durations), p95_ns=quantile(durations, 0.95),
        bytes=trial.memory, allocations=trial.allocs, samples=length(durations),
        times_ns=durations, garbage_collection_ns=trial.gctimes)
end

function measure(function_value::F, options) where {F}
    return @benchmark $function_value() evals=1 seconds=options.seconds samples=options.samples
end

measurement_ratio(candidate, original) = original == 0 ? (candidate == 0 ? 1.0 : nothing) : candidate / original

function compare_workloads(original, candidate, options)
    results = Dict{String,Any}()
    for name in sort!(collect(keys(original)))
        original_function, candidate_function = original[name], candidate[name]
        expected = original_function()
        isequal(expected, candidate_function()) || error("Output mismatch for " * name)
        original_function(); candidate_function()
        original_trials, candidate_trials = Any[], Any[]
        for pair in 1:options.pairs
            if isodd(pair)
                push!(original_trials, trial_record(measure(original_function, options)))
                push!(candidate_trials, trial_record(measure(candidate_function, options)))
            else
                push!(candidate_trials, trial_record(measure(candidate_function, options)))
                push!(original_trials, trial_record(measure(original_function, options)))
            end
        end
        reductions = [1 - candidate_trials[index].median_ns / original_trials[index].median_ns for index in 1:options.pairs]
        results[name] = (; correctness="exact normalized outputs match", original=original_trials, candidate=candidate_trials,
            median_runtime_ratio=1 - median(reductions), median_runtime_reduction=median(reductions),
            minimum_pair_runtime_reduction=minimum(reductions), acceptance_threshold=0.10,
            all_pairs_meet_target=minimum(reductions) >= 0.10,
            bytes_ratio=measurement_ratio(median(getproperty.(candidate_trials, :bytes)), median(getproperty.(original_trials, :bytes))),
            allocations_ratio=measurement_ratio(median(getproperty.(candidate_trials, :allocations)), median(getproperty.(original_trials, :allocations))))
        println(name, ": ", round(100 * median(reductions); digits=2), "% median runtime reduction")
        flush(stdout)
    end
    return results
end

function profile_workload(function_value::F, path, seconds) where {F}
    function_value()
    Profile.clear()
    Profile.@profile begin
        started = time_ns()
        while (time_ns() - started) / 1.0e9 < seconds
            function_value()
        end
    end
    open(path * "-cpu.txt", "w") do output
        Profile.print(output; format=:flat, sortedby=:count, threads=Threads.threadid())
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=1.0 function_value()
    allocations = Profile.Allocs.fetch().allocs
    sites = Dict{String,Tuple{Int,Int}}()
    for allocation in allocations
        index = findfirst(frame -> occursin("Julia-Forever-2", string(frame.file)) && occursin("/src/", string(frame.file)), allocation.stacktrace)
        frame = isnothing(index) ? first(allocation.stacktrace) : allocation.stacktrace[index]
        site = string(frame.file, ":", frame.line, " ", frame.func, " [", allocation.type, "]")
        count, bytes = get(sites, site, (0, 0))
        sites[site] = (count + 1, bytes + allocation.size)
    end
    records = [(; site, count, bytes) for (site, (count, bytes)) in sites]
    sort!(records; by=record -> record.bytes, rev=true)
    write(path * "-allocations.json", JSON.json((sample_rate=1.0, sites=records)))
    open(path * "-allocations.txt", "w") do output
        for record in records
            println(output, record.bytes, " bytes\t", record.count, " allocations\t", record.site)
        end
    end
    Profile.Allocs.clear()
    return nothing
end

function run_benchmarks(options)
    fixture = stream_fixture(repeat("Julia λ combines specialized methods, reusable buffers, and exact streaming.\n", 96))
    mkpath(dirname(options.output))
    mktempdir() do directory
        JuliaForever2.save_credentials!(directory, :chatgpt, Dict("access_token" => "synthetic-benchmark-token", "expires_at" => time() + 86400))
        original = workloads(ORIGINAL_API, fixture, directory)
        candidate = workloads(CANDIDATE_API, fixture, directory)
        original["pipeline/coalesced"]().text == fixture.response || error("Fixture response was not reconstructed.")
        candidate["provider/respond_coalesced"]().content == fixture.content || error("Provider fixture was not decoded.")
        manifest_paths = unique(filter(isfile, [joinpath(directory, file) for directory in (dirname(Base.active_project()), dirname(@__DIR__))
            for file in ("Manifest.toml", "Manifest-v$(VERSION.major).$(VERSION.minor).toml")]))
        metadata = (julia=string(VERSION), threads=Threads.nthreads(:default), interactive_threads=Threads.nthreads(:interactive),
            cpu=Sys.CPU_NAME, logical_cpus=Sys.CPU_THREADS, architecture=string(Sys.ARCH),
            cpu_models=unique([information.model for information in Sys.cpu_info()]),
            kernel=string(Sys.KERNEL), word_size=Sys.WORD_SIZE, baseline_directory=options.baseline,
            package_versions=(BenchmarkTools=string(Base.pkgversion(BenchmarkTools)), JSON=string(Base.pkgversion(JSON)),
                Statistics=string(Base.pkgversion(Statistics)), JuliaForever2=string(Base.pkgversion(JuliaForever2))),
            manifest_sha256=Dict(path => bytes2hex(sha256(read(path))) for path in manifest_paths),
            baseline_commit=readchomp(`git -C $(options.baseline) rev-parse HEAD`),
            baseline_diff=BASELINE_DIFF, candidate_directory=CANDIDATE_DIRECTORY,
            candidate_commit=readchomp(`git -C $(dirname(@__DIR__)) rev-parse HEAD`),
            candidate_diff=readchomp(`git -C $(dirname(@__DIR__)) diff HEAD -- src ext`),
            fixture_bytes=length(fixture.bytes), fixture_deltas=length(fixture.deltas), delta_characters=48,
            response_bytes=ncodeunits(fixture.response), response_characters=length(fixture.response), sse_chunk_bytes=(64, 1024, length(fixture.bytes)),
            protocol_dimensions=Dict(string(name) => (characters=length(content), bytes=ncodeunits(content)) for (name, content) in pairs(protocol_contents())),
            wrap_columns=78, trial_seconds=options.seconds, alternating_pairs=options.pairs, evaluations_per_sample=1, samples_cap=options.samples,
            network="mock transport; no network I/O", provider_catalog="warm cache with infinite TTL; synthetic local credential reads",
            provider_previews="mock POST transport sets both actual streams to progress_interval=Inf for deterministic coalescing; all emitted previews compared")
        results = compare_workloads(original, candidate, options)
        write(options.output, JSON.json((; metadata, results)))
        if options.profiles
            stem = splitext(options.output)[1]
            for name in ("pipeline/coalesced", "protocol/unicode", "sse/full")
                workload = name == "sse/full" ? "sse/chunk_full" : name
                suffix = replace(name, '/' => '-')
                profile_workload(original[workload], stem * "-original-" * suffix, 0.3)
                profile_workload(candidate[workload], stem * "-candidate-" * suffix, 0.3)
            end
        end
    end
    println("Saved ", options.output)
end

run_benchmarks(OPTIONS)
