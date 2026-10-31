@testset "JuliaForever2" begin
    @test greet("Julia") == "Hello, Julia!"
    @test greet("") == "Hello, !"
end
