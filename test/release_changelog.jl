using Test,JSON,JuliaForever2
const RCF=JuliaForever2
@testset "Credential-free explicit release policy, schema, pagination and actual cache" begin
 calls=String[]
 note=Dict("tag_name"=>"v0.3.0","name"=>"Actual test release","published_at"=>"2026-11-01T00:00:00Z","body"=>"Real fixture notes","html_url"=>RCF.JF2_RELEASES_PAGE*"/tag/v0.3.0")
 transport=(url,context,policy)->begin push!(calls,url);(status=200,body=JSON.json([note]),reason="") end
 @test_throws ErrorException RCF.fetch_release_changelog(ExecutionContext();transport)
 @test isempty(calls)
 snapshot=RCF.fetch_release_changelog(ExecutionContext();transport,policy=RCF.ReleaseFetchPolicy(;allow_network=true))
 @test only(calls)==RCF.JF2_RELEASES_API*"?per_page=100&page=1"
 @test only(snapshot.entries).body=="Real fixture notes"
 dir=mktempdir();path=joinpath(dir,"releases.json")
 @test RCF.read_release_changelog(path)===nothing
 @test RCF.read_release_changelog_state(path).digest===nothing
 digest=RCF.save_release_changelog!(path,snapshot)
 @test RCF.read_release_changelog(path).entries==snapshot.entries
 state=RCF.read_release_changelog_state(path)
 @test state.digest==digest
 @test state.snapshot.entries==snapshot.entries
 @test filemode(path)&0o777==0o600
 @test_throws TaskFailedException RCF.save_release_changelog!(path,snapshot)
 @test RCF.save_release_changelog!(path,snapshot;expected=digest)==digest
 link=joinpath(dir,"link");symlink(path,link)
 @test_throws ErrorException RCF.read_release_changelog(link)
 denied=(url,context,policy)->(status=403,body="{}",reason="")
 @test_throws ErrorException RCF.fetch_release_changelog(ExecutionContext();transport=denied,policy=RCF.ReleaseFetchPolicy(;allow_network=true))
 empty_source=(url,context,policy)->(status=200,body="[]",reason="")
 empty_snapshot=RCF.fetch_release_changelog(ExecutionContext();transport=empty_source,policy=RCF.ReleaseFetchPolicy(;allow_network=true))
 @test isempty(empty_snapshot.entries)
 malformed=(url,context,policy)->(status=200,body="{}",reason="")
 @test_throws ErrorException RCF.fetch_release_changelog(ExecutionContext();transport=malformed,policy=RCF.ReleaseFetchPolicy(;allow_network=true))
 invalid=copy(note);invalid["html_url"]="https://evil.example/"
 @test_throws ErrorException RCF.release_note(invalid)
 sink=RCF.ReleaseResponseBuffer(IOBuffer(),3)
 @test write(sink,"abc")==3
 @test_throws ErrorException write(sink,"d")
 @test String(take!(sink.buffer))=="abc"
 @test_throws ErrorException RCF.public_release_transport("http://localhost/",ExecutionContext(),RCF.ReleaseFetchPolicy(;allow_network=true))
 context=ExecutionContext();JuliaForever2.cancel!(context)
 @test_throws ErrorException RCF.fetch_release_changelog(context;transport,policy=RCF.ReleaseFetchPolicy(;allow_network=true))
 @test length(calls)==1
 pages=(url,context,policy)->(status=200,body=JSON.json([merge(note,Dict("tag_name"=>"v$i","html_url"=>RCF.JF2_RELEASES_PAGE*"/tag/v$i")) for i in 1:100]),reason="")
 @test_throws ErrorException RCF.fetch_release_changelog(ExecutionContext();transport=pages,policy=RCF.ReleaseFetchPolicy(;allow_network=true,maximum_pages=1))
end
