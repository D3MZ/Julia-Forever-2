using Test,JSON,JuliaForever2
const LogoutCredentials = JuliaForever2.CredentialStorage
@testset "Original Pi stored-credential removal projection" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            output=joinpath(directory,"original.json")
            run(`node $(joinpath(@__DIR__,"differential","credential_logout_oracle.mjs")) $reference $output`)
            original=JSON.parsefile(output)
            @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
            @test length(original["cases"])==6
            C=LogoutCredentials
            for name in (:alpha,:beta)
                C.save_credentials!(directory,name,Dict("api_key"=>"fake-"*String(name)))
            end
            ids()=sort!([String(id) for id in (:alpha,:beta) if !isnothing(C.load_credentials(directory,id))])
            @test ids()==original["cases"][1]["ids"]
            @test C.delete_credentials!(directory,:alpha).removed
            @test ids()==original["cases"][2]["ids"]
            @test !C.delete_credentials!(directory,:alpha).removed
            @test ids()==original["cases"][3]["ids"]
            @test !C.delete_credentials!(directory,:beta;active=Returns(false)).ok
            @test ids()==original["cases"][4]["ids"]
            held=Channel{Nothing}(1);release=Channel{Nothing}(1)
            writer=@async lock(C.auth_lock(directory,:beta)) do
                put!(held,nothing);take!(release)
                C.save_credentials!(directory,:beta,Dict("api_key"=>"fake-replaced"))
            end
            take!(held)
            deleting=@async C.delete_credentials!(directory,:beta)
            yield()
            @test !istaskdone(deleting)
            @test ids()==original["cases"][5]["ids"]
            put!(release,nothing);wait(writer)
            @test fetch(deleting).removed
            @test ids()==original["cases"][6]["ids"]
        end
    end
end
@testset "Local removal preserves refreshed credentials and rejects redirected paths" begin
    C=LogoutCredentials
    mktempdir() do directory
        C.save_credentials!(directory,:alpha,Dict("access_token"=>"fixture-old"))
        old=C.credential_revision(directory,:alpha)
        C.save_credentials!(directory,:alpha,Dict("access_token"=>"fixture-new"))
        @test !C.delete_credentials!(directory,:alpha;expected=old).ok
        @test C.load_credentials(directory,:alpha)["access_token"]=="fixture-new"
        @test C.delete_credentials!(directory,:alpha;expected=C.credential_revision(directory,:alpha)).removed
        @test isnothing(C.load_credentials(directory,:alpha))
        @test !ispath(joinpath(directory,"alpha.json.lock"))
        @test_throws ErrorException C.delete_credentials!(directory,Symbol("../outside"))
        outside=joinpath(directory,"outside.json");write(outside,"untouched")
        symlink(outside,joinpath(directory,"alpha.json"))
        @test_throws ErrorException C.delete_credentials!(directory,:alpha)
        @test read(outside,String)=="untouched"
        C.save_credentials!(directory,:alpha,Dict("api_key"=>"replacement"))
        @test !islink(joinpath(directory,"alpha.json"))
        @test read(outside,String)=="untouched"
        rm(joinpath(directory,"alpha.json"))
        mkdir(joinpath(directory,"alpha.json.lock"))
        @test_throws Base.IOError C.delete_credentials!(directory,:alpha)
        @test isdir(joinpath(directory,"alpha.json.lock"))
        rm(joinpath(directory,"alpha.json.lock"))
        mkdir(joinpath(directory,"alpha.json"))
        @test_throws ErrorException C.delete_credentials!(directory,:alpha)
    end
end
