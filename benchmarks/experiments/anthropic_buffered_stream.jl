using JuliaForever2, JSON, Statistics, SHA, Profile

length(ARGS) == 2 || error("Expected baseline path and evidence directory")
const baseline_path = realpath(ARGS[1])
const evidence = abspath(ARGS[2])
mkpath(evidence)
module BaselineNamespace end
Base.include(BaselineNamespace, joinpath(baseline_path, "src/JuliaForever2.jl"))
const Baseline = BaselineNamespace.JuliaForever2
const Candidate = JuliaForever2

frame(data) = "data: " * JSON.json(data) * "\n\n"
function anthropic_frames(text, thinking; with_tool=false)
    frames = String[
        frame(Dict("type"=>"message_start", "message"=>Dict("id"=>"msg-1",
            "model"=>"synthetic-model", "usage"=>Dict("input_tokens"=>12, "output_tokens"=>0)))),
        frame(Dict("type"=>"content_block_start", "index"=>0, "content_block"=>
            Dict("type"=>"thinking", "thinking"=>"prefix:", "signature"=>"")))
    ]
    for delta in thinking
        push!(frames, frame(Dict("type"=>"content_block_delta", "index"=>0,
            "delta"=>Dict("type"=>"thinking_delta", "thinking"=>delta))))
    end
    push!(frames, frame(Dict("type"=>"content_block_delta", "index"=>0,
        "delta"=>Dict("type"=>"signature_delta", "signature"=>"signature-1"))))
    push!(frames, frame(Dict("type"=>"content_block_stop", "index"=>0)))
    push!(frames, frame(Dict("type"=>"content_block_start", "index"=>1,
        "content_block"=>Dict("type"=>"text", "text"=>"answer:"))))
    for delta in text
        push!(frames, frame(Dict("type"=>"content_block_delta", "index"=>1,
            "delta"=>Dict("type"=>"text_delta", "text"=>delta))))
    end
    push!(frames, frame(Dict("type"=>"content_block_stop", "index"=>1)))
    if with_tool
        push!(frames, frame(Dict("type"=>"content_block_start", "index"=>2,
            "content_block"=>Dict("type"=>"tool_use", "id"=>"call-1",
                "name"=>"lookup", "input"=>Dict{String,Any}()))))
        push!(frames, frame(Dict("type"=>"content_block_delta", "index"=>2,
            "delta"=>Dict("type"=>"input_json_delta", "partial_json"=>"{\"key\":\"value\"}"))))
        push!(frames, frame(Dict("type"=>"content_block_stop", "index"=>2)))
    end
    push!(frames, frame(Dict("type"=>"message_delta",
        "delta"=>Dict("stop_reason"=>"end_turn"), "usage"=>Dict("output_tokens"=>42))))
    push!(frames, frame(Dict("type"=>"message_stop")))
    frames
end
function openai_frames(text)
    frames = [frame(Dict("choices"=>[Dict("delta"=>Dict("content"=>delta),
        "finish_reason"=>nothing)])) for delta in text]
    push!(frames, frame(Dict("choices"=>[Dict("delta"=>Dict{String,Any}(),
        "finish_reason"=>"stop")])))
    frames
end
const long_text = [repeat(isodd(i) ? "tool dispatch and nested JSON output λ " :
    "session context message processing 🚀 ", 5) for i in 1:2400]
const long_thinking = [repeat(isodd(i) ? "reasoning λ " : "analysis 🚀 ", 6) for i in 1:1200]
const short_text = ["some text λ", "response text 🚀", "done"]
const short_thinking = ["step one", "step two"]
const long_wire = anthropic_frames(long_text, long_thinking)
const medium_wire = anthropic_frames(long_text[1:360], long_thinking[1:180])
const short_wire = anthropic_frames(short_text, short_thinking)
const tool_wire = anthropic_frames(short_text, short_thinking; with_tool=true)
const openai_wire = openai_frames([repeat("unchanged provider text. ", 6) for _ in 1:360])
const openai_short_wire = openai_frames(short_text)

function response(package, protocol, wire)
    events = String[]
    context = package.ExecutionContext(;
        event_sink=event -> (push!(events, String(event.data["type"])); nothing))
    transport = (url, method, body, headers, request_context, decoder) -> begin
        for part in wire
            write(decoder, part)
        end
        (status=200, reason="OK")
    end
    backend = package.HTTPModelBackend(protocol, "https://offline.invalid"; transport)
    request = package.ModelRequest([package.Message(:user, "hello")],
        "", nothing, nothing, nothing)
    result = package.respond_model(backend,
        package.ModelSpec(:synthetic, "synthetic-model"), request, context)
    output = (reply_kind=String(result.reply.kind), reply=result.reply.content,
        reason=result.message["stopReason"], blocks=result.message["content"],
        events=events, usage=result.message["usage"])
    close(context)
    output
end
anthropic(package, wire) = response(package, package.AnthropicMessagesProtocol(), wire)
openai(package, wire) = response(package, package.OpenAIChatProtocol(), wire)
json_response(output) = JSON.json(Dict("reply"=>output.reply, "kind"=>output.reply_kind,
    "reason"=>output.reason, "blocks"=>output.blocks,
    "events"=>output.events, "usage"=>output.usage))
function mixed(package)
    conversation = package.Conversation()
    first = anthropic(package, medium_wire)
    second = openai(package, openai_short_wire)
    package.append_message!(conversation, package.Message(:assistant, first.reply))
    package.append_message!(conversation, package.Message(:assistant, second.reply))
    snapshot = package.history_snapshot(conversation)
    (responses=(json_response(first), json_response(second)),
        history=[(String(msg.role), msg.content) for msg in snapshot.messages])
end

const workloads = [
    ("integration/anthropic-long-stream-json", p -> json_response(anthropic(p, long_wire))),
    ("integration/anthropic-medium-stream-json", p -> json_response(anthropic(p, medium_wire))),
    ("integration/anthropic-short-stream-json", p -> json_response(anthropic(p, short_wire))),
    ("integration/anthropic-tool-stream-json", p -> json_response(anthropic(p, tool_wire))),
    ("integration/mixed-provider-conversation", p -> mixed(p)),
    ("control/openai-long-stream-json", p -> json_response(openai(p, openai_wire))),
    ("control/openai-short-stream-json", p -> json_response(openai(p, openai_short_wire)))
]

function validate(package)
    result = anthropic(package, short_wire)
    result.reply == "answer:" * join(short_text) || error("text response mismatch")
    result.blocks[1]["thinking"] == "prefix:" * join(short_thinking) ||
        error("thinking response mismatch")
    result.blocks[1]["thinkingSignature"] == "signature-1" ||
        error("signature mismatch")
    result.reason == "stop" || error("finish reason mismatch")
    count(==("text_delta"), result.events) == length(short_text) ||
        error("text event count mismatch")
    count(==("thinking_delta"), result.events) == length(short_thinking) ||
        error("thinking event count mismatch")
    tool = anthropic(package, tool_wire)
    tool.blocks[3]["arguments"] == Dict("key"=>"value") ||
        error("tool argument mismatch")
    nothing
end
function trial(f)
    GC.gc()
    times = Int[]
    for _ in 1:5
        start = time_ns()
        f()
        push!(times, time_ns() - start)
    end
    (times_ns=times, median_ns=median(times),
        allocated_bytes=Base.@allocated(f()), allocation_count=Base.@allocations(f()))
end
function lower_bound(gains)
    state = UInt64(0x20261101)
    medians = Float64[]
    for _ in 1:10000
        values = Float64[]
        for _ in eachindex(gains)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            push!(values, gains[Int(mod(state, UInt64(length(gains)))) + 1])
        end
        push!(medians, median(values))
    end
    quantile(medians, 0.025)
end
function profile(f, prefix)
    f()
    Profile.clear()
    Profile.@profile begin
        until = time_ns() + 300_000_000
        while time_ns() < until
            f()
        end
    end
    open(joinpath(evidence, prefix * "-cpu.txt"), "w") do output
        Profile.print(output; format=:flat, sortedby=:count)
    end
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.02 f()
    sites = Dict{String,Tuple{Int,Int}}()
    allocations = Iterators.filter(allocation -> !isempty(allocation.stacktrace), Profile.Allocs.fetch().allocs)
    for allocation in allocations
        source_index = findfirst(location -> occursin("anthropic.jl", string(location.file)), allocation.stacktrace)
        frame = allocation.stacktrace[isnothing(source_index) ? firstindex(allocation.stacktrace) : source_index]
        label = string(frame.file, ":", frame.line, " ", frame.func)
        count, bytes = get(sites, label, (0, 0))
        sites[label] = (count+1, bytes+allocation.size)
    end
    rows = [(site=site, count=totals[1], bytes=totals[2])
        for (site, totals) in sites]
    sort!(rows; by=x -> x.bytes, rev=true)
    write(joinpath(evidence, prefix * "-allocations.json"),
        JSON.json((sample_rate=0.02, sites=rows)))
    Profile.Allocs.clear()
end
const baseline_sha = readchomp(Cmd(["git","-C",baseline_path,"rev-parse","HEAD"]))
const candidate_sha = readchomp(Cmd(["git","rev-parse","HEAD"]))
const environment = (baseline_sha=baseline_sha, candidate_sha=candidate_sha,
    julia_version=string(VERSION), threads=Threads.nthreads(), cpu=Sys.CPU_NAME,
    cpu_threads=Sys.CPU_THREADS, os=string(Sys.KERNEL), arch=string(Sys.ARCH),
    json_version=string(Base.pkgversion(JSON)),
    project_sha256=bytes2hex(sha256(read("benchmarks/Project.toml"))),
    baseline_project_sha256=bytes2hex(sha256(read(joinpath(baseline_path, "benchmarks/Project.toml")))),
    paired_samples=7, repetitions_per_side=5, warmups_per_side=4,
    order="AB BA AB BA AB BA AB",
    confidence="10,000 deterministic paired-median bootstrap draws, 2.5% quantile",
    matched="same Julia process, same packages, runner, threads, prebuilt wire frames")
write(joinpath(evidence, "environment.json"), JSON.json(environment))
validate(Baseline)
validate(Candidate)
results = Dict{String,Any}()
for (name, operation) in workloads
    before = () -> operation(Baseline)
    after = () -> operation(Candidate)
    isequal(before(), after()) || error("Output contract mismatch: " * name)
    for _ in 1:4
        before()
        after()
    end
    baseline_trials = Any[]
    candidate_trials = Any[]
    for pair in 1:7
        if isodd(pair)
            push!(baseline_trials, trial(before))
            push!(candidate_trials, trial(after))
        else
            push!(candidate_trials, trial(after))
            push!(baseline_trials, trial(before))
        end
    end
    isequal(before(), after()) || error("Post-run output mismatch: " * name)
    gains = [1 - candidate_trials[i].median_ns/baseline_trials[i].median_ns for i in 1:7]
    result = (baseline=baseline_trials, candidate=candidate_trials,
        paired_gains=gains, median_improvement=median(gains),
        confidence95_lower=lower_bound(gains),
        baseline_allocated_bytes=median(getproperty.(baseline_trials, :allocated_bytes)),
        candidate_allocated_bytes=median(getproperty.(candidate_trials, :allocated_bytes)),
        baseline_allocation_count=median(getproperty.(baseline_trials, :allocation_count)),
        candidate_allocation_count=median(getproperty.(candidate_trials, :allocation_count)))
    results[name] = result
    write(joinpath(evidence, "raw-paired-results.json"),
        JSON.json((environment=environment, results=results)))
    println(name, " median=", round(100*result.median_improvement,digits=2),
        "% lower95=",round(100*result.confidence95_lower,digits=2), "%")
    flush(stdout)
end
profile(() -> json_response(anthropic(Baseline, long_wire)), "baseline")
profile(() -> json_response(anthropic(Candidate, long_wire)), "candidate")
primary = results["integration/anthropic-long-stream-json"]
no_regressions = all(r -> r.median_improvement > -0.10, values(results))
accepted = primary.median_improvement > 0.10 &&
    primary.confidence95_lower > 0.10 && no_regressions
write(joinpath(evidence, "acceptance.json"), JSON.json(
    (passed=accepted, semantic_contracts=true, no_secondary_regressions=no_regressions,
    primary_improvement=primary.median_improvement,
    primary_confidence95_lower=primary.confidence95_lower)))
println("ACCEPTANCE_GATE=", accepted ? "PASS" : "FAIL")
accepted || error("Performance acceptance gate failed, do not create PR")
