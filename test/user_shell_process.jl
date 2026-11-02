using Test,JuliaForever2,JSON
module UserShellProcessTests
using Test,JuliaForever2,JSON
const P=JuliaForever2.UserShellProcess
@testset "Actual native isolated user shell process" begin
 if Sys.islinux()
 folder=mktempdir()
 run(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__,"..","scripts","build_terminal_jobs.jl")) $folder`)
 adapter=JuliaForever2.TerminalJobs.TerminalJobAdapter(;library=joinpath(folder,"libjf2_terminal_jobs."*JuliaForever2.TerminalJobs.Libdl.dlext))
 execute(args...;kwargs...)=P.execute(args...;adapter,kwargs...)
 fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-user-shell-oracle.json"))
 directory=mktempdir()
 for case in fixture["real"]
  chunks=String[];owner=P.Operation()
  result=execute(case["command"];directory,operation=owner,on_chunk=x->push!(chunks,x))
  @test result.ok
  @test (case["id"]=="cwd" ? "<fixture-directory>" : result.output)==case["output"]
  @test result.exit_code==case["exitCode"]
  @test result.cancelled==case["cancelled"] && result.truncated==case["truncated"]
  @test join(chunks)==result.output
  @test owner.completed && owner.job.closed
 end
 started=Channel{Nothing}(1);stop=Threads.Atomic{Bool}(false);owner=P.Operation()
 task=@async execute("printf 'ready\\n'; sleep 30";directory,operation=owner,cancelled=()->stop[],on_chunk=x->put!(started,nothing))
 @test timedwait(10;pollint=0.002) do
  isready(started)
 end==:ok
 take!(started);stop[]=true;result=fetch(task)
 @test result.ok && result.cancelled && isnothing(result.exit_code)
 @test result.output=="ready\n" && owner.completed && owner.job.closed
 @test !execute("printf x";directory,operation=owner).ok
 @test !execute("printf x";directory="/missing-jf2-directory").ok
 @test !execute("printf x";directory,shell="/missing-jf2-shell").ok
 @test execute("printf x";directory,cancelled=Returns(true)).cancelled
 result=execute("(sleep 0.06; printf first; sleep 0.06; printf second; sleep 0.06; printf third) & exit 0";directory)
 @test result.ok && result.output=="firstsecondthird"
 owner=P.Operation();stop=Threads.Atomic{Bool}(false)
 task=@async execute("(while true; do printf tick; sleep 0.02; done) & exit 0";directory,operation=owner,cancelled=()->stop[])
 @test timedwait(10;pollint=0.002) do
  !isnothing(owner.job) && owner.job.finished
 end==:ok
 rejected=execute("printf must_not_run";directory,operation=owner)
 @test !rejected.ok && !istaskdone(task)
 stop[]=true;result=fetch(task)
 @test result.ok && result.cancelled && owner.completed && owner.job.closed
 @test startswith(result.output,"tick")
 owner=P.Operation();result=execute("printf 'stream data'";directory,operation=owner,on_chunk=x->error("Rejected stream fixture"))
 @test !result.ok && occursin("Rejected stream fixture",result.reason) && owner.completed
 else
  @test !P.execute("printf unsupported";directory=mktempdir()).ok
 end
end
end
