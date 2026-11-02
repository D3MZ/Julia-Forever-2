module APIKeyFixture
using Test,JSON,SHA
const ORIGINAL_SHA="6cc8e26da6ad5caa80c7030bd4f634830ca9cc28d535aa53d2261a549ff5b67d"
const CELLS_SHA="e2bf536139425ded10753ed0697179cbb3ad95f38ce38e60ac0829ea3828d37f"
function load(reference::AbstractString,output::AbstractString)
    root=joinpath(@__DIR__,"..")
    fixture=joinpath(root,"fixtures","pi-api-key-original.json")
    cellfile=joinpath(root,"fixtures","pi-api-key-cells.json")
    oracle=joinpath(@__DIR__,"pi_api_key_oracle.mjs")
    provenance=joinpath(root,"fixtures","pi-menu-search-provenance.json")
    original=JSON.parsefile(fixture)
    cells=JSON.parsefile(cellfile)
    @test bytes2hex(sha256(read(fixture)))==ORIGINAL_SHA
    @test bytes2hex(sha256(read(cellfile)))==CELLS_SHA
    @test cells["sourceSha256"]==ORIGINAL_SHA
    @test original["reference"]==JSON.parsefile(provenance)["reference"]
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test original["runnerSha256"]==bytes2hex(sha256(read(oracle)))
    @test cells["normalizerSha256"]==bytes2hex(sha256(read(joinpath(@__DIR__,"export_terminal_cell_fixture.mjs"))))
    @test isempty(reference) || isdir(reference)
    if isdir(reference)
        run(`node $oracle $reference $provenance $output`)
        @test JSON.parsefile(output)==original
        exporter=joinpath(@__DIR__,"export_terminal_cell_fixture.mjs")
        target=output*".cells.json"
        run(`node $exporter $reference $output $target all pi-visible-width`)
        @test JSON.parsefile(target)==cells
    else
        cp(fixture,output;force=true)
    end
    (original,cells)
end
end
