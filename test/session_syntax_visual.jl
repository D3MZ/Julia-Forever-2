using Test,JSON
isdefined(@__MODULE__,:check_session_syntax_capture)||include("session_syntax.jl")
@testset "Regenerated original full/eager source syntax differential" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            original=joinpath(directory,"original.json")
            oracle=joinpath(@__DIR__,"../parity/pi_session_syntax_oracle.mjs")
            resolver=joinpath(reference,"packages/coding-agent/src/experimental/source-resolver.ts")
            withenv("PI_SOURCE_ROOT"=>reference,"FORCE_COLOR"=>"3") do
                run(`node --import $resolver $oracle $original`)
            end
            check_session_syntax_capture(JSON.parsefile(original))
        end
    end
end
