include("lint.jl")

@testset "Forbidden syntax lint" begin
    for source in ("throw(e)", "Base.throw(e)", "rethrow()", "Base.rethrow(e)", "@assert x", "Base.@assert x", "try f() catch e; g(e) end",
        "try f() finally g() end", "try f() catch; g() finally h() end",
        "function nested(); try f() finally g() end; end", "quote; try f() finally g() end; end")
        @test !isempty(forbidden_syntax(source))
    end
    for source in ("# throw(e)\nx = \"@assert x\"", "@test x", "# try/finally is banned\nx = \"try f() finally g() end\"", "tryparse(Int, text)")
        @test isempty(forbidden_syntax(source))
    end
    @test !isempty(forbidden_syntax("function incomplete("))
    @test forbidden_syntax("try f() finally g() end") == [(1, "try")]
    mktempdir() do root
        mkpath(joinpath(root, "nested"))
        write(joinpath(root, "nested", "example.jl"), "x = 1\nthrow(x)\n")
        @test lint_repository(root) == [(joinpath("nested", "example.jl"), 2, "throw")]
    end
    @test isempty(lint_repository(dirname(@__DIR__)))
end
