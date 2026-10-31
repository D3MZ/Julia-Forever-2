using JuliaForever2
using Test
using Aqua
using JET

include("lint.jl")

@testset "Forbidden syntax lint" begin
    for source in ("throw(e)", "Base.throw(e)", "rethrow()", "Base.rethrow(e)", "@assert x", "Base.@assert x", "try f() catch e; g(e) end")
        @test !isempty(forbidden_syntax(source))
    end
    for source in ("# throw(e)\nx = \"@assert x\"", "@test x", "try f() finally g() end")
        @test isempty(forbidden_syntax(source))
    end
    @test !isempty(forbidden_syntax("function incomplete("))
    mktempdir() do root
        mkpath(joinpath(root, "nested"))
        write(joinpath(root, "nested", "example.jl"), "x = 1\nthrow(x)\n")
        @test lint_repository(root) == [(joinpath("nested", "example.jl"), 2, "throw")]
    end
    @test isempty(lint_repository(dirname(@__DIR__)))
end

@testset "JuliaForever2" begin
    @test greet("Julia") == "Hello, Julia!"
    @test greet("") == "Hello, !"
end

@testset "Package quality" begin
    Aqua.test_all(JuliaForever2)
    JET.test_package(JuliaForever2)
end
