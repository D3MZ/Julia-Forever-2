using Test,JuliaForever2,JSON
module UserShellRecordTests
using Test,JuliaForever2,JSON
const J=JuliaForever2
@testset "Pinned original shell-to-model context projection" begin
 fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-user-shell-oracle.json"))
 for case in fixture["messageCases"]
  record=case["record"]
  result=J.UserShellProcess.Result(;ok=true,output=record["output"],exit_code=get(record,"exitCode",nothing),cancelled=record["cancelled"],truncated=record["truncated"],full_output_path=get(record,"fullOutputPath",nothing))
  message=J.user_shell_message(record["command"],result;exclude_from_context=record["excludeFromContext"],timestamp=123)
  @test message.content==case["text"]
  projected=J.model_context_message(message)
  @test isnothing(projected)==isempty(case["messages"])
  if !isnothing(projected)
   @test projected.content==only(only(case["messages"])["content"])["text"]
  end
 end
end
@testset "Real shell records retain context exclusion through every supported store" begin
 result=J.UserShellProcess.Result(;ok=true,output="harmless fixture\n",exit_code=0)
 included=J.user_shell_message("printf fixture",result)
 excluded=J.user_shell_message("printf private_fixture",result;exclude_from_context=true)
 session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=mktempdir())
 J.append_message!(session,included);J.append_message!(session,excluded)
 @test length(J.history_snapshot(session).messages)==2
 @test length(J.context_messages(session))==1
 @test only(J.context_messages(session)).content==included.content
 @test isnothing(J.wire_metadata(included.metadata))
 timeline=J.SessionTimeline(pwd())
 J.timeline_append_message!(timeline,J.timeline_archive_message(included))
 J.timeline_append_message!(timeline,J.timeline_archive_message(excluded))
 @test length(J.timeline_messages(timeline))==2
 @test length(J.timeline_runtime_messages(timeline))==1
 store=J.SessionStore(mktempdir());@test J.save_session!(store,"shell",session).ok
 saved=JSON.parsefile(J.session_file(store,"shell"));@test saved["version"]==3
 restored=J.saved_session_record(store,"shell")
 copy=Session(Kernel((messages,session)->error("No model call permitted"));messages=restored.messages)
 @test length(J.history_snapshot(copy).messages)==2 && length(J.context_messages(copy))==1
 @test J.timeline_archive_message(last(J.history_snapshot(copy).messages))["excludeFromContext"]===true
 bad=deepcopy(saved);bad["version"]=2
 @test_throws ErrorException J.session_record(J.SessionRecord(bad,store,"shell"))
 damaged=J.Message(:user,"changed";metadata=included.metadata)
 @test_throws ErrorException J.timeline_archive_message(damaged)
 J.clear_history!(session);J.append_message!(session,Message(:user,"ordinary"));@test J.save_session!(store,"ordinary",session).ok
 @test JSON.parsefile(J.session_file(store,"ordinary"))["version"]==2
 close(copy);close(copy.kernel);close(session);close(session.kernel)
end
@testset "Durable append failure does not claim an installed shell record" begin
 result=J.UserShellProcess.Result(;ok=true,output="fixture",exit_code=7)
 session=Session(Kernel((messages,session)->error("No model call permitted"));working_directory=mktempdir())
 J.bind_history_journal!(session,(session,operation,args...)->error("fixture journal denied"))
 @test_throws ErrorException J.append_message!(session,J.user_shell_message("false",result))
 @test isempty(J.history_snapshot(session).messages)
 @test_throws ErrorException J.user_shell_message("missing",J.UserShellProcess.Result(;ok=false,reason="spawn denied"))
 close(session);close(session.kernel)
end
@testset "Excluded shell output never enters compaction summaries" begin
 result=J.UserShellProcess.Result(;ok=true,output="private fixture excluded",exit_code=0)
 hidden=J.user_shell_message("printf secret_fixture",result;exclude_from_context=true)
 visible=J.user_shell_message("printf public_fixture",J.UserShellProcess.Result(;ok=true,output="public fixture",exit_code=0))
 session=Session(Kernel((messages,session)->error("No model call permitted"));compaction=J.CompactionSettings(;keep_recent_tokens=0),messages=[Message(:user,"old"),hidden,visible,Message(:user,"now")])
 plan=J.compaction_plan(session.conversation,0)
 @test plan.first_kept==4
 @test !any(message->occursin("private fixture",message.content),plan.summarized)
 @test length(plan.summarized)==2
 @test isnothing(last(plan.summarized).metadata)
 seen=Ref(J.Message[])
 @test J.compact!(session;summarize=messages->(seen[]=messages;"summary")).status==:compacted
 @test !any(message->occursin("private fixture",message.content),seen[])
 @test length(J.history_snapshot(session).messages)==4
 close(session);close(session.kernel)
end

end
