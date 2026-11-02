using Test, JSON, JuliaForever2
module PreferenceTransactionTests
using Test, JSON, JuliaForever2
include(joinpath(@__DIR__, "..", "ext", "terminal", "preference_transaction.jl"))
@testset "Private preference transactions preserve other owners and reject stale snapshots" begin
    dir=mktempdir();path=joinpath(dir,"terminal-settings.json")
    write(path,JSON.json(Dict("theme"=>"light/dark","extras"=>Dict("one"=>1))))
    prepared=prepare_terminal_preference(path,"steering-mode","all")
    @test prepared.ok
    runtime=Ref("one-at-a-time")
    result=commit_terminal_preference!(prepared.plan;apply=()->(runtime[]="all"))
    @test result.ok && result.state==:verified && runtime[]=="all"
    @test JSON.parsefile(path)==Dict("theme"=>"light/dark","extras"=>Dict("one"=>1),"steering-mode"=>"all")
    @test stat(path).mode & 0o777 == 0o600
    stale=prepare_terminal_preference(path,"steering-mode","one-at-a-time").plan
    data=JSON.parsefile(path);data["theme"]="dark";write(path,JSON.json(data))
    @test commit_terminal_preference!(stale).state==:conflict
    @test JSON.parsefile(path)["theme"]=="dark"
    staged=prepare_terminal_preference(path,"steering-mode","one-at-a-time").plan
    @test commit_terminal_preference!(staged;before_replace=()->write(path,"{}" )).state==:conflict
    @test read(path,String)=="{}"
    @test length(readdir(dir))==1
end
@testset "Denied, invalid, cancelled and failed effects cannot report fake success" begin
    dir=mktempdir();path=joinpath(dir,"terminal-settings.json")
    @test !prepare_terminal_preference(path,"invalid","yes";validate=(k,v)->false).ok
    @test !ispath(path)
    write(path,"{")
    @test !prepare_terminal_preference(path,"a","b").ok
    @test read(path,String)=="{"
    rm(path);symlink("missing",path)
    @test !prepare_terminal_preference(path,"a","b").ok
    @test islink(path)
    rm(path);mkdir(path)
    @test !prepare_terminal_preference(path,"a","b").ok
    rm(path);@test !prepare_terminal_preference(joinpath(dir,"credentials.json"),"a","b").ok
    plan=prepare_terminal_preference(path,"a","b").plan
    @test commit_terminal_preference!(plan;active=Returns(false)).state==:cancelled
    @test !ispath(path)
    runtime=Ref("before")
    rejected=commit_terminal_preference!(plan;apply=()->(runtime[]="bad";(ok=false,reason="Effect rejected")),restore=()->(runtime[]="before"))
    @test rejected.state==:rolled_back && !rejected.ok
    @test !ispath(path) && runtime[]=="before"
    failed=commit_terminal_preference!(plan;apply=()->error("effect fault"),restore=()->(runtime[]="before"))
    @test failed.state==:rolled_back && occursin("effect fault",failed.reason)
    @test !ispath(path)
    uncertain=commit_terminal_preference!(plan;apply=()->(write(path,"{}");false))
    @test uncertain.state==:uncertain && !uncertain.ok
    @test read(path,String)=="{}"
    rm(path);badparent=joinpath(dir,"parent");write(badparent,"x")
    badplan=prepare_terminal_preference(joinpath(badparent,"terminal-settings.json"),"a","b")
    @test badplan.ok
    @test !commit_terminal_preference!(badplan.plan).ok
    @test read(badparent,String)=="x"
    @test length(readdir(dir))==1
end
@testset "Two native writers share ownership and stale update cannot erase unrelated theme" begin
    dir=mktempdir();path=joinpath(dir,"terminal-settings.json")
    one=prepare_terminal_preference(path,"steering-mode","all").plan
    two=prepare_terminal_preference(path,"theme","light").plan
    @test terminal_preference_lock(path)===terminal_preference_lock(joinpath(dir,".","terminal-settings.json"))
    @test commit_terminal_preference!(one).ok
    @test commit_terminal_preference!(two).state==:conflict
    fresh=prepare_terminal_preference(path,"theme","light").plan
    @test commit_terminal_preference!(fresh).ok
    @test JSON.parsefile(path)==Dict("theme"=>"light","steering-mode"=>"all")
end
end
