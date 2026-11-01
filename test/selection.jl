@testset "Test group selection" begin
    @test isempty(unknown_test_groups(["core", "tui"]))
    @test unknown_test_groups(["core", "typo"]) == ["typo"]
    @test selected_test_files(String[]) == TEST_FILES
    @test selected_test_files(["core"]) == ["kernel.jl", "agent.jl", "compaction.jl", "contracts.jl", "architecture.jl", "architecture_contracts.jl"]
    @test selected_test_files(["tui", "core", "tui"]) == ["kernel.jl", "agent.jl", "contracts.jl", "architecture.jl", "architecture_contracts.jl", "tui.jl"]
    @test selected_test_files(["lint"]) == ["lint_tests.jl"]
    @test selected_test_files(["quality"]) == ["aqua.jl", "jet.jl"]
    @test isempty(intersect(selected_test_files(["unit"]), selected_test_files(["quality", "lint"])))
    @test !("live_backbone.jl" in selected_test_files(["all"]))
    helpers = Set(["groups.jl", "lint.jl", "runtests.jl", "live_backbone.jl"])
    files = Set(filter(name -> endswith(name, ".jl") && !(name in helpers), readdir(@__DIR__)))
    @test files == Set(TEST_FILES)
    @test length(TEST_FILES) == length(unique(TEST_FILES))
    @test all(file -> file in TEST_FILES, Iterators.flatten(values(TEST_GROUPS)))
end
