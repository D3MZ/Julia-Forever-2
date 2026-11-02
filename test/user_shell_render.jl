using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
module UserShellRenderTests
using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
color(::Tachikoma.NoColor)=(0,-1)
color(c::Tachikoma.ColorRGB)=(50331648,Int(c.r)*65536+Int(c.g)*256+Int(c.b))
color(c::Tachikoma.Color256)=(16777216,Int(c.code))
function draw(rows,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(rows))))
    for (index,row) in enumerate(rows);T.draw_session_display_line!(buffer,1,index,width,row);end
    canonical=sprint() do io
        for y in eachindex(rows),x in 1:width
            cell=buffer.content[(y-1)*width+x];style=cell.style
            values=(string(cell.char,cell.suffix),color(style.fg)...,color(style.bg)...,Int(style.bold),Int(style.dim),Int(style.italic),Int(style.underline),Int(style.strikethrough))
            print(io,join(values,'\0'),'\n')
        end
    end
    ansi=[sprint() do io
        for x in 1:width
            cell=buffer.content[(y-1)*width+x]
            if cell.char!=Tachikoma.WIDE_CHAR_PAD
                print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for y in eachindex(rows)]
    (digest=bytes2hex(SHA.sha256(canonical)),ansi)
end
oracle=JSON.parsefile(get(ENV,"JF2_BASH_RENDER_ORACLE",joinpath(@__DIR__,"fixtures","pi-user-shell-render.json")))
baseline=get(ENV,"JF2_BASH_RENDER_BASELINE","")
isempty(baseline) || Base.include(T,baseline)
frames=Any[];matched=Ref(0)
output=get(ENV,"JF2_BASH_RENDER_CAPTURE","")
@testset "Original BashExecutionComponent transitions match native real rendering" begin
 for frame in oracle["snapshots"]
    source=frame["state"]
    message=Dict("command"=>source["command"],"output"=>source["output"],"excludeFromContext"=>source["excluded"],"exitCode"=>source["exitCode"],"cancelled"=>source["cancelled"],"fullOutputPath"=>source["path"])
    state=T.SessionDisplayState(;output_padding=source["pad"])
    source["expanded"] && T.session_display_transition!(state,:expand_all)
    rows=isempty(baseline) ? T.session_display_bash(message,frame["id"],frame["width"],state;running=source["running"],frame=source["frame"]) : T.session_display_bash(message,frame["id"],frame["width"],state)
    actual=draw(rows,frame["width"])
    identical=length(rows)==length(frame["terminalAnsiLines"]) && actual.digest==frame["cellsSha256"]
    matched[]+=identical
    push!(frames,Dict("id"=>frame["id"],"width"=>frame["width"],"terminalAnsiLines"=>actual.ansi,"identical"=>identical))
    @testset "$(frame["id"]) @ $(frame["width"])" begin
      @test length(rows)==length(frame["terminalAnsiLines"])
      @test actual.digest==frame["cellsSha256"]
    end
 end
 isempty(output) || write(output,JSON.json(Dict("snapshots"=>frames,"matched"=>matched[]))*"\n")
end
end
