module DSHBatchProjections

using Test
using JSON
using JuliaForever2

const DIRECTORY = @__DIR__
const CASES = JSON.parse(read(joinpath(DIRECTORY, "tool_batches.json"), String))

"""Replace fixture delays with rendezvous cohorts bounded by the declared concurrency limit."""
function rendezvous_peers(input)
    safe = Dict(tool["name"] => get(tool, "parallel", false) for tool in input["tools"])
    peers = [Int[] for _ in input["calls"]]
    pending = Int[]
    for (index, call) in enumerate(input["calls"])
        if get(safe, call["name"], false)
            push!(pending, index)
        end
        if !get(safe, call["name"], false) || length(pending) == input["max_parallel"]
            for member in pending
                peers[member] = copy(pending)
            end
            empty!(pending)
        end
    end
    for member in pending
        peers[member] = copy(pending)
    end
    return peers
end

"""Compare original PR #45 value, failure and repeated-registration projections without timing assumptions."""
function native_result(input)
    scope = JuliaForever2.ExtensionScope()
    monitor = ReentrantLock()
    entered = falses(length(input["calls"]))
    peers = rendezvous_peers(input)
    active = Ref(0)
    exclusive = Ref(0)
    peak = Ref(0)
    violated = Ref(false)
    for definition in input["tools"]
        safe = get(definition, "parallel", false)
        callback = let safe = safe
            arguments -> begin
                index = arguments["index"]
                lock(monitor) do
                    violated[] |= (safe && exclusive[] > 0) || (!safe && active[] > 0)
                    active[] += 1
                    safe || (exclusive[] += 1)
                    peak[] = max(peak[], active[])
                    entered[index] = true
                end
                # The timeout only bounds a broken scheduler; it never defines the expected peak.
                ready = timedwait(() -> lock(() -> all(entered[member] for member in peers[index]), monitor), 30)
                @test ready === :ok
                lock(monitor) do
                    active[] -= 1
                    safe || (exclusive[] -= 1)
                end
                return get(arguments, "fail", false) ?
                    ExecutionResult(false, "fixture failed") : arguments["value"]
            end
        end
        registered = JuliaForever2.register_tool!(scope,
            JuliaForever2.ToolSpec(Symbol(definition["name"]), Dict("type" => "object"), callback;
                concurrency_safe=safe))
        @test registered.ok
    end
    calls = JuliaForever2.ToolCall[
        JuliaForever2.ToolCall(Symbol(call["name"]),
            Dict("index" => index, "value" => call["value"], "fail" => get(call, "fail", false)))
        for (index, call) in enumerate(input["calls"])]
    context = ExecutionContext()
    results = if get(input, "session", false)
        kernel = Kernel()
        session = Session(kernel; executor=JuliaForever2.ToolExecutor(scope))
        overall = evaluate!(session, JuliaForever2.ToolBatch(calls; max_parallel=input["max_parallel"]); context)
        @test overall.ok == all(result.ok for result in overall.value)
        close(session)
        close(kernel)
        overall.value
    else
        JuliaForever2.invoke_tool_batch!(scope, calls; max_parallel=input["max_parallel"], context)
    end
    @test active[] == 0
    @test exclusive[] == 0
    close(scope)
    close(context)
    return JSON.parse(JSON.json(Dict("results" => [
        Dict("id" => string(index), "ok" => result.ok,
            "value" => result.ok ? result.value : nothing)
        for (index, result) in enumerate(results)],
        "peak" => peak[], "exclusiveOverlap" => violated[])))
end

"""Run the existing hash-checked pinned scheduler with the separate PR #45 projection group."""
function reference_results()
    command = Cmd([get(ENV, "DSH_NODE", "node"), "--disable-warning=ExperimentalWarning",
        joinpath(DIRECTORY, "oracle.mjs")])
    request = IOBuffer(JSON.json(Dict("kind" => "tool_batches", "cases" => CASES)) * "\n")
    return JSON.parse(read(pipeline(command; stdin=request), String))
end

end
