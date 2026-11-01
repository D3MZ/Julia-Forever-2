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
end

@testset "Single-exit function contracts" begin
    for source in (
        "function f(x); x === nothing && return 0; x + 1; end",
        "function f(x); if x > 0; return x; end; -x; end",
        "f(x) = begin; x > 0 || return 0; x; end",
        "f = x -> begin; x > 0 && return x; 0; end",
        "function f(xs); for x in xs; x > 0 && return x; end; 0; end",
        "map(xs) do x; x > 0 && return x; 0; end",
        "function f(xs); for x in xs; x < 0 && continue; print(x); end; nothing; end",
        "function f(xs); for x in xs; x < 0 && break; print(x); end; nothing; end",
    )
        @test !isempty(forbidden_syntax(source))
    end
    for source in (
        "f(x) = x + 1",
        "function f(x); y = x + 1; y; end",
        "function f(x); y = x + 1; return y; end",
        "function f(x); if x > 0; x; else; -x; end; end",
        "function f(x); g(y) = y + 1; g(x); end",
        "function f(xs); map(xs) do x; return x + 1; end; end",
        "valid(x) = x isa Integer && x > 0",
        "struct Span; value::Int; Span(value) = value > 0 ? new(value) : error(\"invalid\"); end",
        "text = \"condition && return value\" # return is data here",
    )
        @test isempty(forbidden_syntax(source))
    end
    @test any(issue -> last(issue) == "early return", forbidden_syntax("function f(x)\n if x > 0\n return x\n end\n 0\nend"))
end

@testset "Repository source-style contract" begin
    issues = lint_repository(dirname(@__DIR__))
    foreach(issue -> println(join(issue, ":")), issues)
    @test isempty(issues)
end
