# Test-only immutable source-derived fixtures; fresh source mode remains an independent oracle.
module AuthenticationFixture
using Test,JSON,SHA
const PIN="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
const HASHES=Dict(
    :selectors=>(original="252e02552078b7c45e2d51e6ff0a60b822a5d5d1a376df2c0d02f66c368ae8f4",cells="b7d94197d003f449ac91175ba14f71eff80ab1b528eba69bf399b39ca1fb451f"),
    :dialog=>(original="a5aa7f05c6a0288e48d57c68a89ebdf985448870ea1e152fded008db3db8d523",cells="03da704a1b8e37a90ef5819be27b499ca2997205f383730357a6d734f7a73c0e"),
)
function load(kind::Symbol,reference::AbstractString,output::AbstractString)
    name=kind==:selectors ? "selectors" : "dialog"
    root=joinpath(@__DIR__,"..")
    fixture=joinpath(root,"fixtures","pi-auth-"*name*"-original.json")
    cellfile=joinpath(root,"fixtures","pi-auth-"*name*"-cells.json")
    oracle=joinpath(@__DIR__,"pi_auth_"*name*"_oracle.mjs")
    provenance=joinpath(root,"fixtures","pi-menu-search-provenance.json")
    original=JSON.parsefile(fixture)
    cells=JSON.parsefile(cellfile)
    @test bytes2hex(sha256(read(fixture)))==HASHES[kind].original
    @test bytes2hex(sha256(read(cellfile)))==HASHES[kind].cells
    @test cells["sourceSha256"]==HASHES[kind].original
    @test original["reference"]["commit"]==PIN
    @test original["reference"]==JSON.parsefile(provenance)["reference"]
    @test length(original["reference"]["sourceHashes"])==513
    @test original["runnerSha256"]==bytes2hex(sha256(read(oracle)))
    @test cells["normalizerSha256"]==bytes2hex(sha256(read(joinpath(@__DIR__,"export_terminal_cell_fixture.mjs"))))
    @test cells["reference"]==original["reference"]
    @test isempty(reference) || isdir(reference)
    if isdir(reference)
        run(`node $oracle $reference $provenance $output`)
        fresh=JSON.parsefile(output)
        @test fresh==original
        exporter=joinpath(@__DIR__,"export_terminal_cell_fixture.mjs")
        celloutput=output*".cells.json"
        run(`node $exporter $reference $output $celloutput all pi-visible-width`)
        @test JSON.parsefile(celloutput)==cells
        original=fresh
    else
        cp(fixture,output;force=true)
    end
    (original,cells)
end
end
