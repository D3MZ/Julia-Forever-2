using Test, JuliaForever2, Tachikoma, CommonMark, JSON, SHA
const SQLT=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function markdown_sql_oracle()
    corpus=joinpath(@__DIR__,"../parity/fixtures/pi_sql_literal_corpus.json")
    fallback=joinpath(@__DIR__,"../parity/fixtures/pi_sql_literals.json")
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
markdown_sql_color(::Tachikoma.NoColor)=(0,-1)
markdown_sql_color(c::Tachikoma.ColorRGB)=(50331648,Int(c.r)*65536+Int(c.g)*256+Int(c.b))
markdown_sql_color(c::Tachikoma.Color256)=(16777216,Int(c.code))
function markdown_sql_digest(rows,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(rows))))
    for (index,row) in enumerate(rows)
        SQLT.draw_session_display_line!(buffer,1,index,width,row)
    end
    canonical=sprint() do io
        for index in eachindex(rows),column in 1:width
            cell=buffer.content[(index-1)*width+column];style=cell.style
            visible=cell.char=='\0' ? " " : string(cell.char,cell.suffix) # xterm getChars() is empty for a wide-cell continuation.
            values=(visible,markdown_sql_color(style.fg)...,markdown_sql_color(style.bg)...,Int(style.bold),Int(style.dim),Int(style.italic),Int(style.underline),Int(style.strikethrough))
            print(io,join(values,'\0'),'\n')
        end
    end
    bytes2hex(SHA.sha256(canonical))
end
function markdown_sql_fixture(capture,frame)
    fixture=only(filter(c->c["id"]==frame["fixture"],capture["cases"]))
    text=fixture["text"];width=Int(frame["width"])
    if frame["kind"]=="assistant"
        SQLT.session_display_assistant(Dict("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>text)],"stopReason"=>get(fixture,"stopReason","stop"),"errorMessage"=>get(fixture,"errorMessage","")),width,SQLT.SessionDisplayState())
    else
        SQLT.session_display_markdown(text,width,1)
    end
end
@testset "Source-backed SQL literal case and role distinctions" begin
    previous_theme=SQLT.ACTIVE_NATIVE_THEME[];previous_native_theme=Tachikoma.theme()
    # The source oracle explicitly renders Pi dark, not the most recent App system palette.
    fixture_theme=SQLT.ThemeRuntime(SQLT.theme_catalog("";preserve_extras=false);setting="dark")
    SQLT.activate_theme_runtime!(fixture_theme)
    capture=markdown_sql_oracle()
    @test capture["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    checked=0;pending=0
    for frame in capture["snapshots"]
        rows=markdown_sql_fixture(capture,frame)
        @test length(rows)==frame["rowCount"]
        @test markdown_sql_digest(rows,Int(frame["width"]))==frame["cellsSha256"]
        checked+=1
    end
    @test checked==30
    @test pending==0
    SQLT.ACTIVE_NATIVE_THEME[]=previous_theme
    Tachikoma.set_theme!(previous_native_theme)
    @test SQLT.ACTIVE_NATIVE_THEME[]===previous_theme
    @test Tachikoma.theme()===previous_native_theme
end
