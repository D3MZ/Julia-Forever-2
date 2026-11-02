using Test,JSON,Tachikoma
module ThemeEdgeTests
using JSON,Tachikoma
include(joinpath(@__DIR__,"..","ext","terminal","theme_colors.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_system.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","theme_runtime.jl"))
end

"""Read the actual native token escape, normalizing only the equivalent empty/default reset."""
function theme_edge_ansi(theme,token)
    style=ThemeEdgeTests.theme_token_style(theme,token)
    background=ThemeEdgeTests.THEME_TOKEN_METADATA[token]["slot"]=="background"
    color=background ? style.bg : style.fg
    ansi=color isa Tachikoma.NoColor ? (background ? "\e[49m" : "\e[39m") : sprint(io -> background ? Tachikoma.write_bg(io,color) : Tachikoma.write_fg(io,color))
    ansi*(style.dim ? "\e[2m" : "")
end

@testset "Theme runtime source-checked validation, huge hues and partial reports" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle=joinpath(@__DIR__,"differential","pi_theme_edge_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output=joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original=JSON.parsefile(output)
            for case in original["validationCases"]
                actual=ThemeEdgeTests.theme_read_document(JSON.parse(case["rawJson"]))
                @test actual.ok==case["load"]["accepted"]
                if actual.ok
                    @test theme_edge_ansi(actual.theme,"accent")==case["load"]["accentAnsi"]
                end
            end
            for case in original["colorCases"]
                actual=ThemeEdgeTests.theme_color(case["value"])
                @test sprint(io -> Tachikoma.write_fg(io,actual))==case["truecolorAnsi"]
                @test sprint(io -> Tachikoma.write_fg(io,ThemeEdgeTests.theme_indexed(actual)))==case["indexedAnsi"]
            end
            catalog=ThemeEdgeTests.theme_catalog("";preserve_extras=false)
            catalog.pending=true
            runtime=ThemeEdgeTests.ThemeRuntime(catalog)
            for transition in original["controller"]["transitions"]
                event=transition["event"]
                colors=get(event,"colors",Dict{String,Any}())
                rgb(value)=(Int(value["r"]),Int(value["g"]),Int(value["b"]))
                arguments=Dict{Symbol,Any}()
                for key in ("background","foreground")
                    if haskey(colors,key)
                        arguments[Symbol(key)]=rgb(colors[key])
                    end
                end
                if haskey(colors,"palette")
                    arguments[:palette]=rgb.(colors["palette"])
                end
                if !isempty(arguments)
                    ThemeEdgeTests.theme_terminal!(runtime;arguments...)
                end
                expected=transition["after"]
                @test String(catalog.appearance)==expected["terminalAppearance"]
                @test runtime.active.name==expected["activeThemeName"]
                for (token,value) in expected["tokens"]
                    @test theme_edge_ansi(runtime.active,token)==value["ansi"]
                end
            end
            evidence=get(ENV,"THEME_EDGE_EVIDENCE_DIR",directory)
            mkpath(evidence)
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
        end
    end
end
