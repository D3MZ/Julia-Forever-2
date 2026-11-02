using Test, JuliaForever2
@testset "Maintained Julia syntax annotations remain inert and byte bounded" begin
    source="function greeting(λ)\n    # inert comment\n    text = \"\"\"first\n    second\"\"\"\n    true, 42, λ\nend"
    result=JuliaForever2.julia_source_highlight(source)
    @test result.status==:success
    @test result.language=="julia"
    @test Set(color.kind for color in result.colors) ⊇ Set((:keyword,:comment,:string,:number))
    @test all(color->1<=color.first<=color.last<=ncodeunits(source)&&isvalid(source,color.first)&&(color.last==ncodeunits(source)||isvalid(source,color.last+1)),result.colors)
    @test JuliaForever2.julia_source_highlight(source;max_bytes=0).status==:byte_budget
    @test isempty(JuliaForever2.julia_source_highlight(source;max_bytes=0).colors)
    @test JuliaForever2.julia_source_highlight(String(UInt8[0xff])).status==:invalid_source
    @test_throws ErrorException JuliaForever2.julia_source_highlight(source;max_bytes=-1)
    @test JuliaForever2.julia_source_highlight(SubString("x"*source,2)).colors==result.colors
    @test JuliaForever2.julia_source_highlight(Base.AnnotatedString(source)).colors==result.colors
    mktempdir() do directory
        target=joinpath(directory,"must-not-exist")
        hostile="write("*repr(target)*", \"never\")"
        @test JuliaForever2.julia_source_highlight(hostile).status==:success
        @test !ispath(target)
    end
    for fragment in ("function f(","\"\"\"unterminated\nλ", "#= unfinished", "@eval error(\"never\")")
        @test JuliaForever2.julia_source_highlight(fragment).status==:success
    end
end
