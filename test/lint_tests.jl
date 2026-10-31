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
