using Test,JSON,SHA,JuliaForever2,Tachikoma,CommonMark
const RegularOwner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Original main-screen stream, scrollback and shrink semantics" begin
    path=joinpath(@__DIR__,"fixtures","pi-regular-terminal.json")
    @test bytes2hex(sha256(read(path)))=="c8363cd1bf2f497194a960c4b9d32827ee7fca523aa7c8ba70ad199f4a232775"
    original=JSON.parsefile(path)
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    mktempdir() do directory
        reference=get(ENV,"PI_REFERENCE","")
        @test isempty(reference) || isdir(reference)
        if isdir(reference)
            oracle=joinpath(@__DIR__,"differential","pi_regular_terminal_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            fresh=joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $fresh`)
            @test JSON.parsefile(fresh)==original
        end
        cases=Any[]
        for case in original["cases"]
            state=RegularOwner.RegularTerminalState();steps=Any[]
            for step in case["steps"]
                writes=sprint() do io
                    if step["name"]=="stop"
                        RegularOwner.regular_finish!(state,io)
                    else
                        cursor=isnothing(step["cursor"]) ? nothing : (step["cursor"][1]+1,step["cursor"][2]+1)
                        rows=String[line*"\e[0m\e]8;;\a" for line in step["lines"]]
                        RegularOwner.regular_rendered!(state,io,rows,step["width"],step["height"];cursor,clear_on_shrink=step["clear"])
                    end
                end
                @test writes==step["writes"]
                push!(steps,(name=step["name"],width=step["width"],height=step["height"],writes))
            end
            push!(cases,(id=case["id"],width=case["width"],height=case["height"],steps))
        end
        if isdir(reference)
            native=joinpath(directory,"native.json");report=joinpath(directory,"cells.json")
            write(native,JSON.json((;cases)))
            comparator=joinpath(@__DIR__,"differential","compare_regular_terminal.mjs")
            run(`node $comparator $reference $path $native $report`)
            @test JSON.parsefile(report)["matching"]==270
        end
    end
end

@testset "Native regular rows cannot execute untrusted terminal controls" begin
    rows=[[Tachikoma.Span("safe\e]52;c;secret\a\e[2J\e_pi:c\a\ttext",Tachikoma.Style(;bold=true))]]
    rendered=RegularOwner.regular_row(only(rows))
    @test !occursin("52;",rendered)
    @test !occursin("\e[2J",rendered)
    @test !occursin("pi:c",rendered)
    @test occursin("safe   text",rendered)
    @test occursin("\e[1m",rendered)
end
