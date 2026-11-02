using Test,JSON
isdefined(@__MODULE__,:session_tool_fixture)||include("session_tool_renderers.jl")
isdefined(SRT,:SessionSyntaxRenderer)||Base.include(SRT,joinpath(@__DIR__,"../ext/terminal/session_syntax.jl"))
function session_syntax_fixture(capture,frame)
    fixture=only(filter(c->c["name"]==frame["fixture"],capture["cases"]))
    tool=SRJ.TimelineDisplayTool(source_entry_id="tool",call=Dict("id"=>"call","name"=>fixture["tool"],"arguments"=>fixture["args"]),result=frame["state"]["result"] ? Dict{String,Any}(fixture["result"]) : nothing)
    state=SRT.SessionDisplayState(expand_all=frame["state"]["expanded"],output_padding=frame["state"]["padding"])
    renderer=SRT.SessionSyntaxRenderer(phase=Symbol(frame["languagePhase"]))
    SRT.session_display_tool(tool,frame["width"],state,SRT.SessionBuiltinToolRenderers(cwd=capture["cwd"],syntax_renderer=renderer))
end
function check_session_syntax_capture(capture)
    @test capture["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test length(capture["snapshots"])==420
    for frame in capture["snapshots"]
        @testset "$(frame["id"]) @$(frame["width"])" begin
            rows=session_syntax_fixture(capture,frame)
            @test length(rows)==frame["rowCount"]
            @test session_render_digest(rows,frame["width"])==frame["visualCellsSha256"]
        end
    end
end
@testset "Native read syntax versus original eager and full grammar states" begin
    check_session_syntax_capture(JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi-session-syntax.json")))
end
@testset "Source lexing preserves source and never interprets it" begin
    syntax=SRT.SessionSyntaxRenderer()
    for extension in ("py","ts","js","json","md","sh","yaml","sql","html","rs","jl","unknown")
        for source in ("", "hello λ and 日本語", "\"quoted \\\" text\"", "x = 42\n# second", "\e]52;c;ZXZpbA==\aevil\e[31m")
            lines=syntax("/nonexistent/file."*extension,source).lines
            actual=join([join(span.content for span in line) for line in lines],"\n")
            @test actual==rstrip(SRT.session_display_safe(source),'\n')
        end
    end
    @test_throws ErrorException SRT.SessionSyntaxRenderer(phase=:untrusted)("file.py","text")
    @test length(SRT.SessionSyntaxRenderer(phase=:eager)("file.md","text\n").lines)==2
    @test length(syntax("file.md","text\n").lines)==1
    @test all(span->span.style.fg==SRT.session_tool_style(:output).fg,only(syntax("file.jl","x = 42").lines))
end

let T = SRT
@testset "Typed renderer boundaries" begin
 r=T.SessionBuiltinToolRenderers(home="/private/home",cwd="/tmp/project")
 path=Base.AnnotatedString("/private/home/notes.txt")
 @test T.session_tool_arg(path) isa String
 @test T.session_tool_path(Dict("path"=>path),r).content=="~/notes.txt"
 @test T.session_tool_path(Dict("path"=>missing),r).content=="[invalid arg]"
 @test T.session_tool_path(Dict("path"=>r"bad"),r).content=="[invalid arg]"
 @test T.session_tool_range(Dict("offset"=>"2","limit"=>"3"))==":2-4"
 @test T.session_tool_range(Dict("offset"=>"2","limit"=>"bad"))==""
 @test T.session_tool_range(Dict("offset"=>"2"))==":2"
 @test T.session_tool_size(42)=="42B"
 @test T.session_tool_size(42.5)=="42.5B"
 @test T.session_tool_size(missing)=="50.0KB"
 @test T.session_tool_size(r"bad")=="50.0KB"
 @test T.session_tool_size(1024)=="1.0KB"
 @test T.session_tool_size(1048576)=="1.0MB"
 @test T.SessionSyntaxRenderer()(path,Base.AnnotatedString("text")).lines[1][1].content=="text"
 state=T.SessionDisplayState(expand_all=true)
 bg=T.session_display_bg(:success)
 for diff in ("-1 before\n+1 after","-1 \n+1 ","not a diff","-line\n+line")
  @test !isempty(T.session_tool_diff(diff,60,state,bg))
 end
end
end
