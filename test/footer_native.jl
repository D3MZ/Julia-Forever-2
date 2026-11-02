using Test,JSON,SHA,JuliaForever2,Tachikoma,CommonMark
module FooterNativeTests
using JSON,JuliaForever2,Tachikoma,CommonMark
include(joinpath(@__DIR__,"..","ext","terminal","menu_search_input.jl"))
const path=joinpath(@__DIR__,"..","ext","terminal","footer_native.jl")
if isfile(path)
    include(path)
end
end
include("differential/footer_replay.jl")
@testset "Footer original-source differential" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do dir
            oracle=joinpath(@__DIR__,"differential","footer_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output=joinpath(dir,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original=JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"]==513
            @test original["summary"]["frames"]==324
            @test original["tokenCases"][10]["text"]=="2.5k"
            evidence=get(ENV,"FOOTER_EVIDENCE_DIR",dir);mkpath(evidence)
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            @test isdefined(FooterNativeTests,:FooterSnapshot)
            @test isdefined(FooterNativeTests,:footer_native_lines)
            if isdefined(FooterNativeTests,:footer_native_lines)
                footer_test_replay(original,evidence)
            end
        end
    end
end

@testset "Footer factual states, formatting and actual buffer" begin
    model=FooterNative.FooterModel(;id="actual-configured",provider="demo",reasoning=false,context_window=100.0)
    absent=FooterNative.FooterSnapshot(;cwd="/home/user/work",home="/home/user",model)
    unknown=FooterNative.FooterSnapshot(;cwd="/home/user/work",home="/home/user",model,context=FooterNative.FooterContext(;percent=nothing))
    omitted=FooterNative.FooterSnapshot(;cwd="/home/user/work",home="/home/user",model,context=FooterNative.FooterContext())
    @test occursin("0.0%/100",join(FooterNative.footer_native_ansi(absent,100)))
    @test occursin("?/100",join(FooterNative.footer_native_ansi(unknown,100)))
    @test FooterNative.footer_native_ansi(absent,100)==FooterNative.footer_native_ansi(omitted,100)
    @test occursin("actual-configured",join(FooterNative.footer_native_ansi(absent,100)))
    @test !occursin("sub",join(FooterNative.footer_native_ansi(absent,100)))
    @test FooterNative.footer_native_cwd("/home/user-other/work","/home/user")=="/home/user-other/work"
    @test FooterNative.footer_native_cwd("/home/user/work",nothing)=="/home/user/work"
    @test FooterNative.footer_native_fixed(2.55,1)=="2.5"
    @test FooterNative.footer_native_fixed(6.25,1)=="6.3"
    @test FooterNative.footer_native_fixed(-6.25,1)=="-6.3"
    @test FooterNative.footer_native_fixed(0.15245,3)=="0.152"
    status="ok "*FooterNative.footer_native_fg(FooterNative.footer_native_style,:success,"界👩‍💻é")
    snapshot=FooterNative.FooterSnapshot(;cwd="/fixture",model,statuses=["b"=>"last","a"=>status])
    before=deepcopy(snapshot.statuses)
    lines=FooterNative.footer_native_lines(snapshot,60)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,60,length(lines)))
    FooterNative.footer_native_draw!(buffer,1,1,60,snapshot)
    @test snapshot.statuses==before
    glyphs=Tachikoma.cell_glyph.(buffer.content)
    wide=findfirst(==("界"),glyphs);joined=findfirst(==("👩‍💻"),glyphs)
    @test !isnothing(wide) && !isnothing(joined)
    @test buffer.content[wide+1].char=='\0' && buffer.content[joined+1].char=='\0'
    @test glyphs[joined+2]=="é"
    @test buffer.content[joined].style.fg==Tachikoma.ColorRGB(104,183,141)
    @test !occursin("fixture-provider",join(FooterNative.footer_native_ansi(absent,30)))
    @test occursin("\e[39m",FooterNative.footer_native_fg(Returns(Tachikoma.Style()),:warning,"plain"))
    entries=[FooterNative.FooterUsageEvent(;kind=:message,role=:assistant,usage=FooterNative.FooterUsage(;input=60,cache_read=40))]
    scanned=FooterNative.FooterSnapshot(;cwd="/fixture",events=entries)
    cached=FooterNative.FooterSnapshot(;cwd="/fixture",accounting=FooterNative.footer_native_totals(entries))
    @test FooterNative.footer_native_ansi(scanned,100)==FooterNative.footer_native_ansi(cached,100)
    @test cached.accounting.cache_rate==40.0
end
