using Test, JSON, SHA, JuliaForever2, Tachikoma, CommonMark
const SPRJ=JuliaForever2
const SPRT=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
for (name,file) in ((:SessionTimeline,"session_timeline.jl"),(:TimelineContextProjection,"session_context.jl"),(:TimelineDisplayOverlay,"session_display.jl"))
    isdefined(SPRJ,name)||Base.include(SPRJ,joinpath(@__DIR__,"../src/core",file))
end
for (name,file) in ((:SessionDisplayState,"session_display_render.jl"),(:SessionBuiltinToolRenderers,"session_tool_renderers.jl"),(:SessionSyntaxRenderer,"session_syntax.jl"),(:SessionParserSyntaxRenderer,"session_syntax_parser.jl"))
    isdefined(SPRT,name)||Base.include(SPRT,joinpath(@__DIR__,"../ext/terminal",file))
end
session_parser_color(::Tachikoma.NoColor)=(0,-1)
session_parser_color(c::Tachikoma.ColorRGB)=(50331648,Int(c.r)*65536+Int(c.g)*256+Int(c.b))
session_parser_color(c::Tachikoma.Color256)=(16777216,Int(c.code))
function session_parser_digest(rows,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(rows))))
    for (index,row) in enumerate(rows)
        SPRT.draw_session_display_line!(buffer,1,index,width,row)
    end
    canonical=sprint() do io
        for index in eachindex(rows),column in 1:width
            cell=buffer.content[(index-1)*width+column]
            style=cell.style
            values=(string(cell.char,cell.suffix),session_parser_color(style.fg)...,session_parser_color(style.bg)...,
                Int(style.bold),Int(style.dim),Int(style.italic),Int(style.underline),Int(style.strikethrough))
            print(io,join(values,'\0'),'\n')
        end
    end
    bytes2hex(SHA.sha256(canonical))
end
function session_parser_fixture(capture,frame)
    fixture=only(filter(c->c["name"]==frame["fixture"],capture["cases"]))
    tool=SPRJ.TimelineDisplayTool(source_entry_id="tool",call=Dict("id"=>"call","name"=>fixture["tool"],"arguments"=>fixture["args"]),result=frame["state"]["result"] ? Dict{String,Any}(fixture["result"]) : nothing)
    state=SPRT.SessionDisplayState(expand_all=frame["state"]["expanded"],output_padding=frame["state"]["padding"])
    renderer=SPRT.SessionParserSyntaxRenderer(phase=Symbol(frame["languagePhase"]))
    SPRT.session_display_tool(tool,frame["width"],state,SPRT.SessionBuiltinToolRenderers(cwd=capture["cwd"],syntax_renderer=renderer))
end
const SESSION_PARSER_VERIFIED_CASES=Set(split("read-c read-cpp read-cs read-go read-java read-rb read-php read-fish read-css read-sass read-toml read-r read-ex read-ml read-graphql read-hcl read-py read-js read-ts read-rs read-md read-json read-html read-sh read-xml"))
@testset "Native parser retains the original eager/full 420-frame contract" begin
    original=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi-session-syntax.json"))
    @test length(original["snapshots"])==420
    for frame in original["snapshots"]
        rows=session_parser_fixture(original,frame)
        @test length(rows)==frame["rowCount"]
        @test session_parser_digest(rows,frame["width"])==frame["visualCellsSha256"]
    end
end
@testset "Native grammar broad corpus exact source-defined subset" begin
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures/pi-native-syntax.json"))
    @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test length(original["sourceHashes"])==513
    checked=0
    for frame in original["snapshots"]
        if frame["fixture"] in SESSION_PARSER_VERIFIED_CASES
            rows=session_parser_fixture(original,frame)
            @test length(rows)==frame["rowCount"]
            @test session_parser_digest(rows,frame["width"])==frame["visualCellsSha256"]
            checked+=1
        end
    end
    @test checked==50
    @test length(original["snapshots"])-checked==36 # explicitly unresolved families, not accepted parity
end
@testset "Native parser has an explicit grammar registry and inert source boundary" begin
    renderer=SPRT.SessionParserSyntaxRenderer()
    source="\"日本語 λ 👩‍💻\"\n# __import__('os').system('false')\nfoo(unterminated\n"
    for extension in keys(SPRT.SESSION_PARSER_EXTENSIONS)
        rows=renderer("/no/such/path/source."*extension,source).lines
        reconstructed=join([join(span.content for span in row) for row in rows],"\n")
        @test rstrip(reconstructed,'\n')==rstrip(source,'\n')
    end
    for language in keys(SPRT.SESSION_PARSER_MODULES)
        grammar=SPRT.session_parser_grammar(language)
        @test isempty(grammar.parser.injections)
        @test grammar===SPRT.session_parser_grammar(language)
    end
    @test_throws ErrorException SPRT.SessionParserSyntaxRenderer(phase=:invalid)("source.py","x")
    @test_throws ErrorException SPRT.SessionParserSyntaxRenderer(max_bytes=-1)("source.py","x")
    for source in ("", "x = 42\n", "日本語\n", repeat("()",10000))
        rows=SPRT.SessionParserSyntaxRenderer(max_bytes=0)("source.py",source).lines
        @test join([join(span.content for span in row) for row in rows],"\n")==source
        @test all(span.style==SPRT.session_display_style(:codeblock) for row in rows for span in row)
    end
    rows=renderer("source.py","good\e]52;c;ZXZpbA==\a\e[31mred\e[0m").lines
    @test join(span.content for row in rows for span in row)=="goodred"
    @test !haskey(SPRT.SESSION_PARSER_GRAMMARS,"../../arbitrary")
    for phase in (:eager,:full)
        unknown=renderer("source.jl","function example() end").lines
        @test all(span.style.fg==SPRT.session_tool_style(:output).fg for row in unknown for span in row)
    end
end

@testset "Core native syntax budget, denial and thread reuse" begin
    @test SPRJ.source_syntax_highlight("../../arbitrary", "inert").status==:unsupported
    @test SPRJ.source_syntax_highlight("python", "x=42";max_bytes=0).status==:byte_budget
    @test isempty(SPRJ.source_syntax_highlight("python", "x=42";max_bytes=0).colors)
    @test SPRJ.source_syntax_highlight("python", String(UInt8[0xff])).status==:invalid_source
    @test SPRJ.source_syntax_highlight("css", "a{}";phase=:eager).status==:unavailable
    @test SPRJ.source_syntax_highlight("python", "x=42").status==:success
    expected=SPRJ.source_syntax_highlight("python", "def greet(name): return f'Hi {name}'").colors
    tasks=[Threads.@spawn(SPRJ.source_syntax_highlight("python", "def greet(name): return f'Hi {name}'")) for _ in 1:8]
    @test all(fetch(task).colors==expected for task in tasks)
end

@testset "Native syntax typed parser and nullable fields" begin
    grammar=SPRJ.session_parser_grammar("python")
    for text in ("", "def ", "class ", "def greet(name):\n    return name\n")
        Base.@lock grammar.lock begin
            tree=parse(grammar.parser,text;injections=false)
            node=SPRJ.TreeSitter.root(tree)
            colors=SPRJ.SessionSourceColor[]
            @test isnothing(SPRJ.session_parser_field(node,"absent"))
            @test SPRJ.session_parser_type(nothing)==""
            @test isnothing(SPRJ.session_parser_header!(colors,node,text,"python"))
            @test SPRJ.session_parser_nodes!(colors,tree,text,"python") isa Vector{Tuple{Int,Int}}
            @test SPRJ.session_parser_colors(grammar,"python",text) isa Vector{SPRJ.SessionSourceColor}
        end
    end
    language=SubString("!python",2)
    source=SubString("!x = 42",2)
    @test SPRJ.source_syntax_highlight(language,source).colors==SPRJ.source_syntax_highlight("python","x = 42").colors
end
