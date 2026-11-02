using Test, JSON, SHA, JuliaForever2, Tachikoma, CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
const FooterHost=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const footer_host_file=joinpath(@__DIR__,"..","ext","terminal","footer_controls.jl")
if isfile(footer_host_file) && !isdefined(FooterHost,:FooterHostState)
    Base.include(FooterHost,footer_host_file)
end
@testset "Actual App footer host source differential" begin
    reference=get(ENV,"PI_REFERENCE","")
    evidence=get(ENV,"FOOTER_HOST_EVIDENCE",mktempdir())
    mkpath(evidence)
    oracle=joinpath(@__DIR__,"differential","footer_host_oracle.mjs")
    provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
    fixtures=joinpath(@__DIR__,"fixtures","footer-host.json")
    output=joinpath(evidence,"original.json")
    pinned=joinpath(@__DIR__,"fixtures","pi-footer-host-original.json")
    cells_path=joinpath(@__DIR__,"fixtures","pi-footer-host-cells.json")
    cell_fixture=JSON.parsefile(cells_path)
    @test bytes2hex(sha256(read(pinned)))=="a988c0607422e51d88dc526f3c944e3be9a80620036447dcf4364ddfd0a88e2d"
    @test bytes2hex(sha256(read(cells_path)))=="c397dec535a3beb41e4a1be12d9ea38efe51a1f2e301e7a9993c3abb9b84cd76"
    @test isempty(reference) || isdir(reference)
    @test cell_fixture["sourceSha256"]==bytes2hex(sha256(read(pinned)))
    data=JSON.parsefile(pinned)
    @test data["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test bytes2hex(sha256(read(fixtures)))==data["provenance"]["fixtureSha256"]
    if isdir(reference)
        run(`node $oracle $reference $provenance $output $fixtures`)
        fresh=JSON.parsefile(output)
        @test fresh==data
    end
    @test data["provenance"]["checkedSourceFiles"]==513
    @test length(data["snapshots"])==130
    @test isdefined(FooterHost,:FooterHostState)
    @test isdefined(FooterHost,:footer_control_lines)
    replay=joinpath(@__DIR__,"differential","footer_host_replay.jl")
    if isdefined(FooterHost,:FooterHostState) && isfile(replay)
        include(replay)
        footer_host_replay(data,JSON.parsefile(fixtures),evidence;cell_fixture,fresh_reference=isdir(reference))
        include("footer_controls_facts.jl")
    end
end
