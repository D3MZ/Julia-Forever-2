using Test,JSON
isdefined(@__MODULE__,:check_session_tool_capture)||include("session_tool_renderers.jl")
@testset "Regenerated exact-revision original built-in tool components" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            original=joinpath(directory,"original.json")
            oracle=joinpath(@__DIR__,"../parity/pi_session_tools_oracle.mjs")
            resolver=joinpath(reference,"packages/coding-agent/src/experimental/source-resolver.ts")
            withenv("PI_SOURCE_ROOT"=>reference,"FORCE_COLOR"=>"3") do
                run(`node --import $resolver $oracle $original`)
            end
            capture=JSON.parsefile(original)
            check_session_tool_capture(capture)
            evidence=get(ENV,"PI_TOOL_RENDER_EVIDENCE","")
            if !isempty(evidence)
                mkpath(evidence)
                cp(original,joinpath(evidence,"original-live.json");force=true)
            end
        end
    end
end
