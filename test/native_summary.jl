using Test,JuliaForever2
@testset "Real native summary lane accepts Answer/Reply and never executes action replies" begin
 replies=[Answer("native summary"),Reply(:answer,"wire summary"),Failure("denied"),Reply(:error,"provider rejected"),ActionDecision(RunJulia("error(\"must not execute\")")),Dict("unexpected"=>true)]
 expected=["native summary","wire summary","","","",""]
 for (reply,wanted) in zip(replies,expected)
  calls=Ref(0);provider=(messages,session)->begin calls[]+=1;reply end
  kernel=Kernel(provider);session=Session(kernel)
  output=JuliaForever2.model_summary!(session,nothing,[Message(:user,"actual transcript")],ExecutionContext(),"bug report")
  @test output==wanted
  @test calls[]==1
  @test isempty(session.messages)
  for message in (Message(:user,"earlier"),Message(:assistant,"reply"),Message(:user,"latest"))
   JuliaForever2.append_message!(session,message)
  end
  result=JuliaForever2.compact!(session)
  @test result.status==(isempty(wanted) ? :summary_failed : :compacted)
  @test isnothing(session.conversation.compaction)==isempty(wanted)
  @test calls[]==2
  close(session);close(kernel)
 end
end
