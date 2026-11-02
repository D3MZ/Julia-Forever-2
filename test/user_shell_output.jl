using Test,JuliaForever2,JSON
module UserShellOutputTests
using Test,JuliaForever2,JSON
isdefined(JuliaForever2,:UserShellOutput) || Base.include(JuliaForever2,joinpath(@__DIR__,"..","src","infrastructure","user_shell_output.jl"))
const O=JuliaForever2.UserShellOutput
@testset "Exact original streamed shell sanitation and bounded output" begin
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-user-shell-oracle.json"))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        path=joinpath(mktempdir(),"original.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_user_shell_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
        @test JSON.parsefile(path)==fixture
    end
    for case in fixture["cases"]
        state=O.Accumulator(;directory=mktempdir());streamed=""
        for bytes in case["chunks"]
            streamed*=O.feed!(state,UInt8.(bytes))
        end
        if case["error"]===nothing || case["cancelled"]
            actual=O.finish!(state);streamed*=actual.final_chunk;expected=case["value"]
            @test actual.output==expected["output"]
            @test actual.truncated==expected["truncated"]
            @test streamed==expected["streamed"]
            @test (isnothing(actual.full_output_path) ? nothing : read(actual.full_output_path,String))==expected["fullOutput"]
        else
            @test streamed==case["value"]["streamed"]
            O.close!(state)
        end
        @test state.closed
    end
    for case in fixture["tail"]
        actual=O.truncate_tail(case["text"];max_lines=case["maxLines"],max_bytes=case["maxBytes"])
        @test Dict(string(k)=>v for(k,v)in pairs(actual))==case["result"]
    end
end
end
