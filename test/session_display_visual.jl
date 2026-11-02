using Test, JSON
isdefined(@__MODULE__,:session_render_fixture) || include("session_display_render.jl")

function session_render_ansi(row)
    sprint() do io
        for span in row
            print(io,"\e[0m")
            Tachikoma.write_style(io,span.style)
            print(io,span.content)
        end
        print(io,"\e[0m")
    end
end

@testset "Live exact-revision original transcript renderer differential" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            root=dirname(@__DIR__)
            input=joinpath(directory,"contexts.json")
            original=joinpath(directory,"original.json")
            write(input,JSON.json(Dict("cases"=>session_render_oracle()["cases"])))
            oracle=joinpath(root,"parity/pi_session_render_oracle.mjs")
            resolver=joinpath(reference,"packages/coding-agent/src/experimental/source-resolver.ts")
            withenv("PI_SOURCE_ROOT"=>reference,"FORCE_COLOR"=>"3") do
                run(`node --import $resolver $oracle $input $original`)
            end
            capture=JSON.parsefile(original)
            matching=filter(frame->!(frame["fixture"] in UNSUPPORTED_IMAGE_CASES),capture["snapshots"])
            @test length(matching)==180
            for frame in matching
                rows=session_render_fixture(capture,frame)
                @test length(rows)==frame["rowCount"]
                @test session_render_digest(rows,frame["width"])==frame["cellsSha256"]
            end
            evidence=get(ENV,"PI_SESSION_RENDER_EVIDENCE","")
            if !isempty(evidence)
                mkpath(evidence)
                cp(original,joinpath(evidence,"original-live.json");force=true)
                frames=[Dict("id"=>frame["id"],"width"=>frame["width"],"ansiLines"=>session_render_ansi.(session_render_fixture(capture,frame))) for frame in capture["snapshots"]]
                write(joinpath(evidence,"candidate-live.json"),JSON.json(Dict("snapshots"=>frames)))
            end
        end
    end
end
