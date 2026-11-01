using JSON
@testset "Pinned Pi differential contracts" begin
    runner = joinpath(@__DIR__, "..", "parity", "check.py")
    report = get(ENV, "PI_PARITY_REPORT", joinpath(mktempdir(), "pi-parity.json"))
    command = `python3 $runner --report $report`
    process = run(ignorestatus(command))
    @test success(process)
end


@testset "Pinned Pi footer source trace and token formatting" begin
    reference = get(ENV, "PI_REFERENCE", "")
    script = joinpath(@__DIR__, "..", "parity", "footer_trace.mjs")
    trace = JSON.parse(read(Cmd(["node", script, reference]), String))
    @test trace["commit"] == JSON.parse(read(joinpath(@__DIR__, "..", "parity", "pi-lock.json"), String))["commit"]
    @test trace["trace"]["context"] == "projected current session; null immediately after compaction"
    @test trace["trace"]["layout"] == "right-aligned selected model and thinking level"
    for case in trace["formats"]
        @test JuliaForever2.footer_tokens(case["value"]) == case["label"]
    end
end
