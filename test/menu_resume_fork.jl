using Test, JSON, SHA, JuliaForever2, Tachikoma, CommonMark
module ResumeNativeTests
using JSON, JuliaForever2, Tachikoma, CommonMark
const Owner = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const pi_style = Owner.pi_style
const menu_token_score = Owner.menu_token_score
include(joinpath(@__DIR__,"..","ext","terminal","menu_search_input.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_thinking.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","menu_tree.jl"))
for name in ("menu_resume.jl","menu_fork.jl")
    path = joinpath(@__DIR__,"..","ext","terminal",name)
    if isfile(path)
        include(path)
    end
end
end
include("differential/resume_fork_replay.jl")
@testset "Resume/fork original-source-checked differential" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do dir
            oracle=joinpath(@__DIR__,"differential","pi_resume_fork_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output=joinpath(dir,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original=JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"]==513
            @test original["summary"]["frames"]==753
            @test first(original["cases"])["initial"]["currentLoading"]
            evidence=get(ENV,"RESUME_EVIDENCE_DIR",dir)
            mkpath(evidence)
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            @test isdefined(ResumeNativeTests,:resume_menu)
            @test isdefined(ResumeNativeTests,:fork_menu)
            if isdefined(ResumeNativeTests,:resume_menu) && isdefined(ResumeNativeTests,:fork_menu)
                resume_test_replay(original,evidence)
            end
        end
    end
end

@testset "Resume/fork native effect boundaries and real cells" begin
    loads,mutations,events=[],[],[]
    menu=ResumeNative.resume_menu(;on_load=(menu,request)->push!(loads,request),on_select=path->(accepted=false,path=path),
        on_cancel=()->push!(events,:cancel),on_rename=(menu,request)->push!(mutations,request),
        on_delete=(menu,request)->push!(mutations,request),current_path="/fixture/a",path_key=identity,
        schedule=(callback,delay)->nothing,unschedule=Returns(nothing),now=Returns(1000.0))
    a=ResumeNative.ResumeEntry(;id="a",path="/fixture/a",name="Active",modified=999.0)
    b=ResumeNative.ResumeEntry(;id="b",path="/fixture/b",first_message="A界👩‍💻éZ",modified=998.0)
    request=only(loads)
    ResumeNative.resume_loaded!(menu,request,[a,b])
    @test ResumeNative.resume_selected(menu)==a.path
    selected=ResumeNative.resume_input!(menu,"\r")
    @test selected.invoked && !selected.outcome.accepted
    ResumeNative.resume_input!(menu,"\x04")
    @test isempty(mutations) && isnothing(menu.confirming_delete)
    @test last(menu.status)=="Cannot delete the currently active session"
    ResumeNative.resume_input!(menu,"\e[B")
    ResumeNative.resume_input!(menu,"\x12")
    ResumeNative.resume_input!(menu,"renamed")
    ResumeNative.resume_input!(menu,"\r")
    @test only(mutations).value=="renamed"
    @test menu.records[2].name===nothing
    ResumeNative.resume_mutation_complete!(menu,only(mutations);ok=false,error="permission denied")
    @test menu.mode==:list && menu.records[2].name===nothing
    ResumeNative.resume_input!(menu,"\x04")
    ResumeNative.resume_input!(menu,"\r")
    deletion=last(mutations)
    @test deletion.kind==:delete && deletion.path==b.path && length(menu.records)==2
    ResumeNative.resume_mutation_complete!(menu,deletion;ok=false,error="locked by owner")
    @test length(menu.records)==2 && last(menu.status)=="Failed to delete: locked by owner"
    ResumeNative.resume_mutation_complete!(menu,deletion;ok=true)
    @test length(menu.records)==2
    ResumeNative.resume_input!(menu,"\t")
    pending=last(loads)
    ResumeNative.resume_progress!(menu,pending,1,2;entries=[b])
    @test ResumeNative.resume_selected(menu)==b.path
    ResumeNative.resume_input!(menu,"\e")
    @test pending.cancelled && events==[:cancel]
    ResumeNative.resume_loaded!(menu,pending,[a])
    @test menu.caches[:all]===nothing && ResumeNative.resume_selected(menu)==b.path
    lines=ResumeNative.resume_lines(menu,60)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,60,length(lines)))
    ResumeNative.resume_draw!(buffer,1,1,60,menu)
    glyphs=Tachikoma.cell_glyph.(buffer.content)
    joined=findfirst(==("👩‍💻"),glyphs)
    @test !isnothing(joined) && buffer.content[joined+1].char=='\0'
    @test glyphs[joined+2]=="é" && glyphs[joined+3]=="Z"
    tab_buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,30,1))
    ResumeNative.session_draw_lines!(tab_buffer,1,1,30,[[Tachikoma.Span("A\tB")]])
    @test Tachikoma.cell_glyph(tab_buffer.content[9])=="B"
    ResumeNative.resume_dispose!(menu)
    @test !ResumeNative.resume_input!(menu,"\r").invoked
    @test !isnothing(ResumeNative.resume_pattern("[").error)
    @test !isnothing(ResumeNative.resume_pattern(repeat("a",8193)).error)
    regex=ResumeNative.resume_pattern(raw"(a+)+$")
    @test !ResumeNative.resume_pattern_match(regex,repeat("a",1000)*"!")
    ResumeNative.resume_pattern_close!(regex)
    @test regex.code==C_NULL
    fork=ResumeNative.fork_menu([ResumeNative.ForkMessage(;id="original-user-id",text="complete message")];
        on_select=id->(created=false,id=id),on_cancel=Returns(nothing))
    result=ResumeNative.fork_input!(fork,"\r")
    @test result.entry_id=="original-user-id" && !result.outcome.created
    @test fork.messages[1].text=="complete message"
    ResumeNative.fork_dispose!(fork)
    @test !ResumeNative.fork_input!(fork,"\r").invoked
end
