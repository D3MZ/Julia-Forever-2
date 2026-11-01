@testset "Pinned Pi differential contracts" begin
    runner = joinpath(@__DIR__, "..", "parity", "check.py")
    report = get(ENV, "PI_PARITY_REPORT", joinpath(mktempdir(), "pi-parity.json"))
    command = `python3 $runner --report $report`
    process = run(ignorestatus(command))
    @test success(process)
end
