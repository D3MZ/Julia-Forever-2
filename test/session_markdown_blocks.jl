using Test, JuliaForever2, Tachikoma, CommonMark, JSON, SHA
const MBT=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function markdown_block_oracle()
    corpus=joinpath(@__DIR__,"../parity/fixtures/pi_markdown_fences_corpus.json")
    fallback=joinpath(@__DIR__,"../parity/fixtures/pi_markdown_fences.json")
    original=get(ENV,"PI_SOURCE_ROOT","")
    capture=if !isempty(original)
        mktemp() do path,io
            close(io)
            run(`node $(joinpath(@__DIR__,"../parity/pi_markdown_fences_oracle.mjs")) $corpus $path`)
            JSON.parsefile(path)
        end
    else
        JSON.parsefile(fallback)
    end
    capture
end
markdown_block_color(::Tachikoma.NoColor)=(0,-1)
markdown_block_color(c::Tachikoma.ColorRGB)=(50331648,Int(c.r)*65536+Int(c.g)*256+Int(c.b))
markdown_block_color(c::Tachikoma.Color256)=(16777216,Int(c.code))
function markdown_block_digest(rows,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(rows))))
    for (index,row) in enumerate(rows)
        MBT.draw_session_display_line!(buffer,1,index,width,row)
    end
    canonical=sprint() do io
        for index in eachindex(rows),column in 1:width
            cell=buffer.content[(index-1)*width+column];style=cell.style
            visible=cell.char=='\0' ? " " : string(cell.char,cell.suffix) # xterm getChars() is empty for a wide-cell continuation.
            values=(visible,markdown_block_color(style.fg)...,markdown_block_color(style.bg)...,Int(style.bold),Int(style.dim),Int(style.italic),Int(style.underline),Int(style.strikethrough))
            print(io,join(values,'\0'),'\n')
        end
    end
    bytes2hex(SHA.sha256(canonical))
end
function markdown_block_fixture(capture,frame)
    fixture=only(filter(c->c["id"]==frame["fixture"],capture["cases"]))
    text=fixture["text"];width=Int(frame["width"])
    if frame["kind"]=="assistant"
        MBT.session_display_assistant(Dict("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>text)],"stopReason"=>get(fixture,"stopReason","stop"),"errorMessage"=>get(fixture,"errorMessage","")),width,MBT.SessionDisplayState())
    else
        MBT.session_display_markdown(text,width,1)
    end
end
# Explicit residual inventories are not accepted as whole-renderer parity.
const MARKDOWN_PENDING_CASES=Set(("fence-controls",))
@testset "Original complete, incremental and interrupted Markdown rendering" begin
    previous_theme=MBT.ACTIVE_NATIVE_THEME[];previous_native_theme=Tachikoma.theme()
    # The source oracle explicitly renders Pi dark, not the most recent App system palette.
    fixture_theme=MBT.ThemeRuntime(MBT.theme_catalog("";preserve_extras=false);setting="dark")
    MBT.activate_theme_runtime!(fixture_theme)
    capture=markdown_block_oracle()
    @test capture["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    checked=0;pending=0
    for frame in capture["snapshots"]
        id=frame["fixture"];width=Int(frame["width"])
        expected_pending=id in MARKDOWN_PENDING_CASES
        if expected_pending
            pending+=1
        else
            rows=markdown_block_fixture(capture,frame)
            @testset "$(frame["id"]) @ $(width)" begin
                @test length(rows)==frame["rowCount"]
                @test markdown_block_digest(rows,width)==frame["cellsSha256"]
            end
            checked+=1
        end
    end
    @test checked+pending==length(capture["snapshots"])
    @test pending==6
    MBT.ACTIVE_NATIVE_THEME[]=previous_theme
    Tachikoma.set_theme!(previous_native_theme)
    @test MBT.ACTIVE_NATIVE_THEME[]===previous_theme
    @test Tachikoma.theme()===previous_native_theme
end
@testset "Whole-block highlighting, archival safety and fallback" begin
    calls=Tuple{String,String}[]
    highlighter=(language,text)->begin
        push!(calls,(language,text))
        [[Tachikoma.Span(String(line),Tachikoma.Style())] for line in split(text,'\n';keepempty=true)]
    end
    source="```custom\n  kept  \n\nlast\n\n```"
    rows=MBT.session_markdown_spans(source,40;highlighter)
    @test calls==[("custom","  kept  \n\nlast\n")]
    @test join([join(span.content for span in row) for row in rows],"\n")=="```custom\n    kept  \n  \n  last\n  \n```"
    @test source=="```custom\n  kept  \n\nlast\n\n```"
    empty!(calls)
    MBT.session_markdown_spans("```x\nbody\n``",40;highlighter)
    @test calls==[("x","body")]
    empty!(calls)
    MBT.session_markdown_spans("```x\nbody\n``\n",40;highlighter)
    @test calls==[("x","body\n``")]
    empty!(calls)
    MBT.session_markdown_spans("```x\nbody\n``\n```\nAfter",40;highlighter)
    @test calls==[("x","body\n``")]
    safe=MBT.session_markdown_spans("```text\n\e]52;c;ZXZpbA==\agood\e[31mred\e[0m\0\n```",40)
    flattened=join(span.content for row in safe for span in row)
    @test !occursin('\e',flattened)
    @test occursin("goodred�",flattened)
    for language in ("python","javascript","julia","../../untrusted")
        actual=MBT.SessionMarkdownSyntax(max_bytes=0)(language,"λ\n\n")
        @test join([join(span.content for span in row) for row in actual],"\n")=="λ\n\n"
        @test all(span.style==MBT.session_display_style(:codeblock) for row in actual for span in row)
    end
    @test_throws ErrorException MBT.SessionMarkdownSyntax(phase=:invalid)("julia","x")
    @test_throws ErrorException MBT.SessionMarkdownSyntax(max_bytes=-1)("python","x")
    # The four prior plain-renderer identity cases now use exact original framed-cell
    # assertions in pi_markdown_continuations: legacy-plain-*. Requested repairs
    # intentionally replace the old Tachikoma list markers and quote spacing.
    for text in ("```python\ntext = \"\"\"first\nsecond", "```javascript\nconst text = `first\nsecond", "```javascript\n/* first\nsecond")
        @test !isempty(MBT.session_markdown_spans(text,20))
    end
end
