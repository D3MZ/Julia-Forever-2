module BuiltinKeyUIFixture
using Test,JSON,SHA
const ORIGINAL_SHA="e5f3fb717776c54f2ae880a676457913965ab5fb26270ff95fdbb03a959ee033"
const CELLS_SHA="a305a765c56a1bccae5c37a0b187fc9ba9c3a9cc28a29adb994cf75f3688f827"
function load(reference::AbstractString,output::AbstractString)
    root=joinpath(@__DIR__,"..")
    fixture=joinpath(root,"fixtures","pi-builtin-key-ui-original.json")
    cellfile=joinpath(root,"fixtures","pi-builtin-key-ui-cells.json")
    oracle=joinpath(@__DIR__,"pi_builtin_key_ui_oracle.mjs")
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
