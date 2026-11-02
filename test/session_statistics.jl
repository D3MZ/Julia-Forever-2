using Test,JSON,JuliaForever2
const SSF=JuliaForever2
@testset "Source-pinned all-branch accounting, not current context" begin
 data=JSON.parsefile(joinpath(@__DIR__,"..","parity","fixtures","pi_command_workflows.json");dicttype=Dict{String,Any})
 @test data["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
 for case in data["cases"]
  stats=SSF.session_statistics(case["entries"];id=case["id"]);expected=case["stats"]
  @test stats.messages==(total=expected["totalMessages"],user=expected["userMessages"],assistant=expected["assistantMessages"],tool_calls=expected["toolCalls"],tool_results=expected["toolResults"])
  for (native,original) in ((:input,"input"),(:output,"output"),(:cache_read,"cacheRead"),(:cache_write,"cacheWrite"))
   actual=getproperty(stats.tokens,native)
   @test SSF.session_total_complete(actual)
   @test actual.value==expected["tokens"][original]
  end
  @test stats.cost.value≈expected["cost"]
  @test SSF.session_total_complete(stats.cost)
  @test SSF.session_combined_total(values(stats.tokens)...).value==expected["tokens"]["total"]
  @test [b.key for b in stats.breakdown]==[b["key"] for b in case["breakdown"]]
  @test Float64[b.cost.value for b in stats.breakdown]≈Float64[b["cost"] for b in case["breakdown"]]
  @test [SSF.session_combined_total(values(b.tokens)...).value for b in stats.breakdown]==[b["tokens"] for b in case["breakdown"]]
 end
end
@testset "Unknown, actual zero, native estimates and unsafe values" begin
 entries=[Dict("type"=>"message","message"=>Dict("role"=>"assistant","content"=>Any[]))]
 unknown=SSF.session_statistics(entries;id="unknown")
 @test !SSF.session_total_complete(unknown.tokens.input)
 @test unknown.tokens.input.reported==0
 @test !SSF.session_total_complete(unknown.cost)
 @test only(unknown.breakdown).key=="Unattributed"
 marker=Dict("format"=>"JuliaForever2.usage-provenance.v1","observedFields"=>["input","output"],"usage"=>Dict{String,Any}("input"=>0,"output"=>2),"costSource"=>"unknown")
 payload=Dict("role"=>"assistant","usage"=>Dict("input"=>999,"output"=>999,"cacheRead"=>999,"cacheWrite"=>999),"jf2"=>Dict("usageProvenance"=>marker))
 original=deepcopy(payload)
 native=SSF.session_statistics([Dict("type"=>"message","message"=>payload)];id="native")
 @test native.tokens.input.value==0 && SSF.session_total_complete(native.tokens.input)
 @test native.tokens.output.value==2
 @test !SSF.session_total_complete(native.tokens.cache_read)
 @test !SSF.session_total_complete(native.cost)
 @test payload==original
 partial=SSF.session_statistics([entries;[Dict("type"=>"message","message"=>payload)]];id="partial")
 @test partial.tokens.input.reported==1 && partial.tokens.input.expected==2
 @test !SSF.session_total_complete(partial.tokens.input)
 marker["costSource"]="catalog-estimate";marker["usage"]["cost"]=0.05
 append!(marker["observedFields"],["cacheRead","cacheWrite"]);marker["usage"]["cacheRead"]=0;marker["usage"]["cacheWrite"]=0
 cost=SSF.session_statistics([Dict("type"=>"message","message"=>payload)];id="cost")
 @test cost.cost.value==0.05
 @test cost.cost_sources==Set([:catalog_estimate])
 @test_throws ErrorException SSF.session_statistics(["bad"];id="bad")
 @test_throws ErrorException SSF.session_statistics([Dict("type"=>"message")];id="bad")
 @test_throws OverflowError SSF.session_combined_total(SSF.ReportedSessionTotal(typemax(Int),1,1),SSF.ReportedSessionTotal(1,1,1))
end
