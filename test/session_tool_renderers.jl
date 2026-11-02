using Test, JSON
isdefined(@__MODULE__,:session_render_digest)||include("session_display_render.jl")
isdefined(SRT,:SessionBuiltinToolRenderers)||Base.include(SRT,joinpath(@__DIR__,"../ext/terminal/session_tool_renderers.jl"))

function session_tool_fixture(capture,frame)
    fixture=only(filter(c->c["name"]==frame["fixture"],capture["cases"]))
    tool=SRJ.TimelineDisplayTool(source_entry_id="tool",call=Dict("id"=>"call","name"=>fixture["tool"],"arguments"=>fixture["args"]),result=frame["state"]["result"] ? Dict{String,Any}(fixture["result"]) : nothing)
    state=SRT.SessionDisplayState(expand_all=frame["state"]["expanded"],output_padding=frame["state"]["padding"])
    SRT.session_display_tool(tool,frame["width"],state,SRT.SessionBuiltinToolRenderers(cwd=capture["cwd"]))
end
function check_session_tool_capture(capture)
    @test capture["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test length(capture["snapshots"])==360
    for frame in capture["snapshots"]
        @testset "$(frame["id"]) @$(frame["width"])" begin
            rows=session_tool_fixture(capture,frame)
            @test length(rows)==frame["rowCount"]
            @test session_render_digest(rows,frame["width"])==frame["visualCellsSha256"]
        end
    end
end
@testset "Registered read/edit/shell actual original visual cells and transitions" begin
    capture=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi-session-tools.json"))
    check_session_tool_capture(capture)
end
@testset "Built-in display is read-only, sanitized and extensible" begin
    tool=SRJ.TimelineDisplayTool(source_entry_id="tool",call=Dict("name"=>"read","arguments"=>Dict("path"=>"/file/that/does/not/exist")),result=Dict("content"=>[Dict("type"=>"text","text"=>"saved output\e]52;c;aGk=\a")],"isError"=>false))
    before=deepcopy(tool.result)
    state=SRT.SessionDisplayState(expand_all=true)
    registry=SRT.SessionBuiltinToolRenderers(cwd="/nonexistent")
    rows=SRT.session_display_tool(tool,60,state,registry)
    text=join(span.content for row in rows for span in row)
    @test occursin("saved output",text)
    @test !occursin("52;",text)
    @test tool.result==before
    @test SRT.session_tool_range(Dict("offset"=>"12","limit"=>"8"))==":12-19"
    @test SRT.session_tool_range(Dict("limit"=>"invalid"))==""
    @test SRT.session_tool_range(Dict("offset"=>NaN))==""
    @test SRT.session_tool_duration(4_200)=="4.2s"
    @test SRT.session_tool_duration(90_000)=="1m 30s"
    @test SRT.session_tool_duration(7_384_000)=="2h 3m 4s"
    @test SRT.session_tool_size(51200)=="50.0KB"
    image=Dict("type"=>"image","mimeType"=>"image/png","data"=>"opaque")
    tool.result=Dict("content"=>[image],"isError"=>false)
    @test SRT.session_tool_output(tool,registry)=="[Image: [image/png]]"
    calls=Ref(0)
    callback=block->begin calls[]+=1;block["data"]="changed";"[decoded image]" end
    @test SRT.session_tool_output(tool,SRT.SessionBuiltinToolRenderers(image_fallback=callback))=="[decoded image]"
    @test calls[]==1
    @test tool.result["content"][1]==image
    tool.call["name"]="unknown"
    @test SRT.session_display_tool(tool,60,state,registry)==SRT.session_display_tool(tool,60,state)
end
