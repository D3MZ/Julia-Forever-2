using Test,JuliaForever2,JSON,SHA
module TerminalJobTests
using Test,JuliaForever2,JSON,SHA
const J=JuliaForever2.TerminalJobs
@testset "Native job-control installation, admission and verification" begin
    if Sys.islinux()
    folder=mktempdir()
    run(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__,"..","scripts","build_terminal_jobs.jl")) $folder`)
    adapter=J.TerminalJobAdapter(;library=joinpath(folder,"libjf2_terminal_jobs."*J.Libdl.dlext))
    @test isfile(adapter.library)
    @test J.terminal_library(adapter)!=C_NULL
    result=J.spawn_terminal_job(adapter,["/bin/true"];directory=pwd(),input_fd=-1,output_fd=1,error_fd=2)
    @test !result.ok && isnothing(result.job)
    @test occursin("Bad file descriptor",result.reason)
    @test_throws ErrorException J.spawn_terminal_job(adapter,String[];directory=pwd(),input_fd=0,output_fd=1,error_fd=2)
    @test_throws ErrorException J.spawn_terminal_job(adapter,["bad\0argument"];directory=pwd(),input_fd=0,output_fd=1,error_fd=2)
    missing=J.TerminalJobAdapter(;library=joinpath(mktempdir(),"missing.so"))
    @test_throws ErrorException J.terminal_library(missing)
    folder=mktempdir();copy_path=joinpath(folder,basename(adapter.library));cp(adapter.library,copy_path)
    @test_throws ErrorException J.terminal_library(J.TerminalJobAdapter(;library=copy_path))
    metadata=JSON.parsefile(adapter.library*".json")
    metadata["source_sha256"]="changed";write(copy_path*".json",JSON.json(metadata))
    @test_throws ErrorException J.terminal_library(J.TerminalJobAdapter(;library=copy_path))
    metadata=JSON.parsefile(adapter.library*".json");metadata["library_sha256"]="changed";write(copy_path*".json",JSON.json(metadata))
    @test_throws ErrorException J.terminal_library(J.TerminalJobAdapter(;library=copy_path))
    metadata=JSON.parsefile(adapter.library*".json");write(copy_path*".json",JSON.json(metadata))
    @test J.terminal_library(J.TerminalJobAdapter(;library=copy_path))!=C_NULL
    else
        @test_throws ErrorException J.terminal_library(J.TerminalJobAdapter())
    end
end
end
