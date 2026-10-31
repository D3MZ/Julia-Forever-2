using JET

@testset "JET package quality" begin
    JET.test_package(JuliaForever2; target_modules=(JuliaForever2,))
end
