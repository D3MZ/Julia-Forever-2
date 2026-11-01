module DSHBatchProjectionTests

using Test
include(joinpath(@__DIR__, "differential", "batch_projections.jl"))

@testset "Additional pinned DSH batch value and failure projections" begin
    expected = DSHBatchProjections.reference_results()
    @test length(expected) == length(DSHBatchProjections.CASES) == 12
    @testset "$(input["name"])" for (input, reference) in zip(DSHBatchProjections.CASES, expected)
        @test DSHBatchProjections.native_result(input) == reference
    end
end

end
