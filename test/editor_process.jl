using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module ExternalEditorProcessTests
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
isdefined(T,:edit_external_text) || Base.include(T,joinpath(@__DIR__,"..","ext","terminal","editor_process.jl"))
const HELPER=abspath(joinpath(@__DIR__,"fixtures","external-editor-helper.py"))
@testset "Pinned original external editor real child outcomes" begin
    fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-external-editor-oracle.json"))
    reference=get(ENV,"PI_REFERENCE","")
    if !isempty(reference)
        output=joinpath(mktempdir(),"original.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_external_editor_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $output $HELPER`)
        @test JSON.parsefile(output)==fixture
    end
    for record in fixture["cases"]
        directory=mktempdir();temporary=mktempdir();owner=T.ExternalEditorProcess()
        command=get(record,"command","python3 "*HELPER*" "*get(record,"tail",""))
        actual=T.edit_external_text(command,record["content"];directory,temporary_root=temporary,owner)
        expected=record["result"]
        @test actual.ok==(expected["status"]=="complete")
        @test expected["status"]=="complete" ? actual.content==expected["content"] : actual.reason==expected["message"]
        @test readdir(temporary)==record["remainingTemporary"]
        @test owner.completed
        @test !isnothing(owner.process) ? !process_running(owner.process) : true
    end
end
@testset "Editor configuration, directory, boundaries and cancellation" begin
    @test T.external_editor_command(" custom  editor ";environment=Dict("VISUAL"=>"ignored"))==" custom  editor "
    @test T.external_editor_command("  ";environment=Dict("VISUAL"=>"visual","EDITOR"=>"editor"))=="visual"
    @test T.external_editor_command(nothing;environment=Dict("EDITOR"=>"editor"))=="editor"
    @test T.external_editor_command(nothing;environment=Dict{String,String}(),windows=false)=="nano"
    @test T.external_editor_command(nothing;environment=Dict{String,String}(),windows=true)=="notepad"
    directory=mktempdir();temporary=mktempdir()
    @test_throws ErrorException T.external_editor_exit(T.ExternalEditorProcess(),"unopened",1024)
    command="python3 "*HELPER*" unchanged"
    result=T.edit_external_text(SubString(command),SubString("unchanged"))
    @test result.ok && result.content=="unchanged"
    result=T.edit_external_text("python3 "*HELPER*" cwd","original";directory,temporary_root=temporary)
    @test result.ok && result.content==basename(directory)
    for (mode,reason,maximum) in (("invalid","not valid UTF-8",1024),("oversized","size limit",1024),("removed","removed",1024))
        result=T.edit_external_text("python3 "*HELPER*" "*mode,"original";directory,temporary_root=temporary,max_bytes=maximum)
        @test !result.ok && occursin(reason,result.reason)
        @test isnothing(result.content)
        @test isempty(readdir(temporary))
    end
    result=T.edit_external_text("python3 "*HELPER*" unchanged","original";directory,temporary_root=temporary,max_bytes=2)
    @test !result.ok && occursin("input exceeds",result.reason)
    @test isempty(readdir(temporary))
    owner=T.ExternalEditorProcess();started=Channel{Nothing}(1)
    task=@async T.edit_external_text("python3 "*HELPER*" hang","original";directory,temporary_root=temporary,owner,on_started=owner->put!(started,nothing))
    take!(started);T.cancel_external_editor!(owner);result=fetch(task)
    @test !result.ok && result.cancelled && isnothing(result.content)
    @test owner.completed && !process_running(owner.process)
    @test isempty(readdir(temporary))
    @test !T.edit_external_text("ignored","draft";owner).ok
    owner=T.ExternalEditorProcess();T.cancel_external_editor!(owner)
    @test T.edit_external_text("ignored","draft";owner).cancelled
    @test isnothing(owner.process)
    result=T.edit_external_text("python3 "*HELPER*" hang","draft";directory,temporary_root=temporary,on_started=owner->error("Fixture start callback failed"))
    @test !result.ok && occursin("Fixture start callback failed",result.reason)
    @test isempty(readdir(temporary))
end
end
