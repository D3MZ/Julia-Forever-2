using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const GraphemeOwner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const GRAPHEME_TEST_CAPTURES=Dict{String,Any}()

@testset "Strict complete-frame grapheme emission boundary" begin
    T=GraphemeOwner
    frame(text)="\e[?2026h"*text*"\e[?2026l"
    transform(text;kwargs...)=T.fullscreen_grapheme_frame(text;width=24,height=4,kwargs...)
    original=frame("\e[1;1H👩‍💻X")
    corrected=transform(original)
    @test corrected.status==:corrected && corrected.corrections==1
    @test corrected.text==frame("\e[1;1H👩‍💻\e[1;5HX")
    for text in (frame("\e[1;1Hplain text"),frame("\e[1;1H界X"),frame("\e[1;1H🙂X"),frame("\e[1;1HéX"),frame("\e[1;1H👩‍💻\e[1;3HX"))
        @test transform(text).text===text
        @test transform(text).status==:unchanged
    end
    for (style,close) in (("\e[31m","\e[39m"),("\e[1;38;2;10;20;30m","\e[0m"),("\e]8;;https://example.invalid/👩‍💻\a","\e]8;;\a"))
        actual=transform(frame("\e[1;1H👩‍💻"*style*"X"*close))
        @test actual.status==:corrected
        @test actual.text==frame("\e[1;1H👩‍💻"*style*"\e[1;5HX"*close)
    end
    for packet in ("\e_Gf=100,a=T;👩‍💻\e\\","\ePq👩‍💻\e\\","\e^private 👩‍💻\e\\","\eXopaque 👩‍💻\e\\")
        text=frame("\e[1;1H👩‍💻X\e[2;1H"*packet*"\e[3;1H👩‍💻X")
        actual=transform(text)
        @test actual.status==:corrected && actual.corrections==2
        @test occursin(packet,actual.text)
        @test replace(actual.text,"\e[1;5H"=>"","\e[3;5H"=>"")==text
    end
    for text in ("\e[1;1H👩‍💻X",frame("\e[1;1H👩‍💻X\e[3A"),frame("\e[1;1H👩‍💻X\e]unterminated"),frame("\e[1;1H👩‍💻X\e"),frame("\e[1;1H👩‍💻X\n"),frame("\e[1;1H👩‍💻X\u0085"),frame("\e[1;1H👩‍💻X\e[?2026h"),frame("\e[99;1H👩‍💻X"),frame("\e[1;1H👩‍💻X\e[99999999999999999999999;1H"))
        actual=transform(text)
        @test actual.status==:unsupported
        @test actual.text===text && actual.corrections==0
    end
    for position in eachindex(original)
        prefix=original[1:prevind(original,position)]
        @test transform(prefix).text===prefix
    end
    @test transform(original;max_bytes=1).text===original
    @test T.fullscreen_grapheme_frame(original;width=0,height=4).status==:unsupported
    invalid=String(UInt8[0x1b,0x5b,0x3f,0x32,0x30,0x32,0x36,0x68,0xff,0x1b,0x5b,0x3f,0x32,0x30,0x32,0x36,0x6c])
    @test transform(invalid).text===invalid
end

function grapheme_fixture_rows(step)
    # Text colors are fixture-owned. This adapter never parses arbitrary message ANSI.
    raw=String(step["text"]);colored=startswith(raw,"\e[38;2;230;30;20m")
    text=colored ? replace(raw,"\e[38;2;230;30;20m"=>"","\e[39m"=>"") : raw
    style=colored ? Tachikoma.Style(;fg=Tachikoma.ColorRGB(230,30,20)) : Tachikoma.Style()
    isempty(text) ? Vector{Tachikoma.Span}[] : [[Tachikoma.Span(String(line),style)] for line in split(text,'\n')]
end

@testset "Native wrapping uses original grapheme columns" begin
    T=GraphemeOwner
    original=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi_grapheme_frames.json"))
    @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    for item in original["wraps"]
        rows=T.session_display_text_rows(item["text"],Int(item["width"]),Int(item["padding"]))
        lines=[join(span.content for span in row) for row in rows]
        @test lines==item["lines"]
        @test all(line->T.menu_search_width(line)==item["width"],lines)
    end
end

@testset "Actual PresentationIO draw and update transitions" begin
    T=GraphemeOwner
    original=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi_grapheme_frames.json"))
    native=Any[]
    for case in original["cases"]
        raw=IOBuffer();state=T.TerminalPresentation(;width=24,height=4,attached=true)
        output=T.PresentationIO(raw,state)
        terminal=Tachikoma.Terminal(;io=output,size=(rows=4,cols=24),external_size=true)
        steps=Any[]
        for step in case["steps"]
            width=Int(step["width"]);height=Int(step["height"])
            state.width=width;state.height=height
            Tachikoma.set_size!(terminal,(cols=width,rows=height))
            rows=grapheme_fixture_rows(step)
            Tachikoma.draw!(terminal) do frame
                T.startup_document_draw!(frame.buffer,1,1,width,rows)
            end
            bytes=String(take!(raw))
            @test startswith(bytes,"\e[?2026h") && endswith(bytes,"\e[?2026l")
            push!(steps,Dict("name"=>step["name"],"width"=>width,"height"=>height,"writes"=>bytes))
        end
        push!(native,Dict("glyph"=>case["glyph"],"steps"=>steps))
    end
    GRAPHEME_TEST_CAPTURES["native"]=Dict("cases"=>native)
    path=get(ENV,"GRAPHEME_NATIVE_OUTPUT","")
    isempty(path)||write(path,JSON.json(Dict("cases"=>native)))
end

function grapheme_buffer_reference(buffer)
    sprint() do io
        print(io,"\e[?2026h\e[2J")
        for row in buffer.area.y:Tachikoma.bottom(buffer.area),column in buffer.area.x:Tachikoma.right(buffer.area)
            cell=buffer.content[Tachikoma.buf_index(buffer,column,row)]
            if cell.char!='\0'
                print(io,"\e[",row,";",column,"H")
                Tachikoma.write_style(io,cell.style)
                print(io,cell.char,cell.suffix)
            end
        end
        print(io,"\e[0m\e[?2026l")
    end
end

@testset "Real App editor frames preserve composed cells and terminal ownership" begin
    T=GraphemeOwner;steps=Any[];previous=T.ACTIVE_NATIVE_THEME[];previous_native=Tachikoma.theme()
    mktempdir() do directory
        write(joinpath(directory,"terminal-settings.json"),JSON.json(Dict("quiet-startup"=>true,"theme"=>"dark")))
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=directory);settings_dir=directory)
        raw=IOBuffer();terminal=Tachikoma.Terminal(;io=raw,size=(rows=12,cols=40),external_size=true)
        app.settings.terminal=terminal;T.initialize_terminal_presentation!(app,terminal)
        editor=T.chat_editor_state!(app)
        for (index,text) in enumerate(("","👩‍💻  X","👨‍👩‍👧‍👦      Y","é ✈️ 👍🏽  Z",""))
            T.chat_set_text!(editor,text)
            reference=Ref("")
            Tachikoma.draw!(terminal) do frame
                T.default_view!(app,frame)
                reference[]=grapheme_buffer_reference(frame.buffer)
            end
            actual=String(take!(raw))
            @test isempty(app.session.runtime.handles)
            @test startswith(actual,"\e[?2026h")
            @test !occursin("\e[999",actual)
            push!(steps,Dict("name"=>"editor-$index","width"=>40,"height"=>12,"writes"=>actual,"referenceWrites"=>reference[]))
        end
        @test T.terminal_presentation_pause!(app).ok
        frame="\e[?2026h\e[1;1H👩‍💻X\e[?2026l"
        write(terminal.io,frame);@test position(raw)==0
        @test !T.presentation_switch!(terminal.io,:regular).ok
        @test T.terminal_presentation_sink(app)===raw
        @test T.terminal_presentation_resume!(app).ok
        T.cleanup!(app);close(app.session)
    end
    T.ACTIVE_NATIVE_THEME[]=previous;Tachikoma.set_theme!(previous_native)
    GRAPHEME_TEST_CAPTURES["host"]=Dict("steps"=>steps)
    path=get(ENV,"GRAPHEME_HOST_OUTPUT","")
    isempty(path)||write(path,JSON.json(Dict("steps"=>steps)))
end

@testset "Original fullscreen transitions and actual App emitted cells" begin
    reference=get(ENV,"PI_SOURCE_ROOT",get(ENV,"PI_REFERENCE",""))
    if isdir(reference)
        mktempdir() do directory
            parity=joinpath(@__DIR__,"../parity")
            original=joinpath(directory,"original.json")
            native=joinpath(directory,"native.json");host=joinpath(directory,"host.json");report=joinpath(directory,"report.json")
            write(native,JSON.json(GRAPHEME_TEST_CAPTURES["native"]))
            write(host,JSON.json(GRAPHEME_TEST_CAPTURES["host"]))
            run(`node $(joinpath(parity,"pi_grapheme_frame_oracle.mjs")) $reference $original`)
            fresh=JSON.parsefile(original)
            saved=JSON.parsefile(joinpath(parity,"fixtures/pi_grapheme_frames.json"))
            @test fresh["hashes"]==saved["hashes"]
            @test fresh["wraps"]==saved["wraps"]
            @test fresh["cases"]==saved["cases"]
            run(`node $(joinpath(parity,"compare_grapheme_frames.mjs")) $original $native $host $report`)
            result=JSON.parsefile(report)
            @test result["checked"]==result["matching"]==85
            @test isempty(result["failures"])
        end
    end
end

@testset "Fragment fallback and alternate owners preserve bytes" begin
    T=GraphemeOwner;frame="\e[?2026h\e[1;1H👩‍💻X\e[?2026l"
    for cut in eachindex(frame)
        sink=IOBuffer();state=T.TerminalPresentation(;attached=true,width=24,height=4)
        output=T.PresentationIO(sink,state)
        write(output,frame[1:prevind(frame,cut)]);write(output,frame[cut:end])
        actual=String(take!(sink))
        @test cut==1 ? actual==T.fullscreen_grapheme_frame(frame;width=24,height=4).text : actual==frame
    end
    bytes=Vector{UInt8}(codeunits(frame))
    for cut in 1:length(bytes)-1
        sink=IOBuffer();state=T.TerminalPresentation(;attached=true,width=24,height=4)
        output=T.PresentationIO(sink,state)
        write(output,bytes[1:cut]);write(output,bytes[cut+1:end])
        @test take!(sink)==bytes
    end
    sink=IOBuffer();state=T.TerminalPresentation(;attached=true,width=24,height=4,leased=true)
    output=T.PresentationIO(sink,state);write(output,frame);@test position(sink)==0
    write(output,"external 👩‍💻X");@test String(take!(sink))=="external 👩‍💻X"
    @test T.fullscreen_grapheme_frame("\e[?2026h\e[1;1H👩‍💻X\e[١m\e[?2026l";width=24,height=4).status==:unsupported
    state=T.TerminalPresentation(;attached=true,mode=:regular,width=24,height=4,lines=[[Tachikoma.Span("actual 👩‍💻  X")]])
    output=T.PresentationIO(sink,state);write(output,frame)
    actual=String(take!(sink));@test occursin("actual 👩‍💻  X",actual) && !occursin("\e[1;5H",actual)
end

@testset "Real native image packets survive emission correction" begin
    T=GraphemeOwner
    previous=(protocol=Tachikoma.GRAPHICS_PROTOCOL[],cell=Tachikoma.CELL_PX[],shm=Tachikoma._KITTY_SHM_AVAILABLE[])
    Tachikoma.CELL_PX[]=(w=9,h=18);Tachikoma._KITTY_SHM_AVAILABLE[]=false
    image=first(JSON.parsefile(joinpath(@__DIR__,"fixtures/session_images/png-cases.json")))
    block=Dict("type"=>"image","mimeType"=>"image/png","data"=>image["data"])
    for protocol in (Tachikoma.gfx_kitty,Tachikoma.gfx_sixel)
        Tachikoma.GRAPHICS_PROTOCOL[]=protocol
        prepared=T.session_image_prepare(block,24;options=T.SessionImageOptions(;max_width_cells=12))
        io=IOBuffer();terminal=Tachikoma.Terminal(;io,size=(rows=20,cols=24),external_size=true);terminal.graphics_protocol=protocol
        packet=Ref("")
        Tachikoma.draw!(terminal) do f
            T.startup_document_draw!(f.buffer,1,1,24,[[Tachikoma.Span("👩‍💻  X")]])
            @test T.render_session_image!(prepared,Tachikoma.Rect(1,3,prepared.columns,prepared.rows),f)==:rendered
            packet[]=String(copy(only(f.gfx_regions).data))
        end
        raw=String(take!(io));result=T.fullscreen_grapheme_frame(raw;width=24,height=20)
        @test result.status== (occursin("👩‍💻X",raw) ? :corrected : :unchanged)
        @test result.corrections==Int(occursin("👩‍💻X",raw))
        @test occursin(packet[],result.text)
        @test result.text==replace(raw,"👩‍💻X"=>"👩‍💻\e[1;5HX")
        Tachikoma.draw!(terminal) do f
            T.startup_document_draw!(f.buffer,1,1,24,[[Tachikoma.Span("👩‍💻  X")]])
        end
        raw=String(take!(io));result=T.fullscreen_grapheme_frame(raw;width=24,height=20)
        @test result.status!=:unsupported
        @test protocol!=Tachikoma.gfx_kitty || occursin("\e_Ga=d,d=a,q=2\e\\",result.text)
    end
    Tachikoma.GRAPHICS_PROTOCOL[]=previous.protocol;Tachikoma.CELL_PX[]=previous.cell;Tachikoma._KITTY_SHM_AVAILABLE[]=previous.shm
end
