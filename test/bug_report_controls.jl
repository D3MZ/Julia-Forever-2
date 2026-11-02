using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module BugControlsTest
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const J=JuliaForever2
const T=Base.get_extension(J,:JuliaForever2TerminalExt)
function fixture(;reply=Answer("Actual fixture bug summary"))
 dir=mktempdir();requests=String[]
 provider=(messages,session)->begin push!(requests,last(messages).content);reply end
 app=T.App(Session(Kernel(provider);working_directory=dir);settings_dir=joinpath(dir,"settings"),registry=J.ProviderRegistry(),theme_fallback="dark")
 app,requests,dir
end
function drain!(app)
 timedwait(10;pollint=.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  !app.busy && all(istaskdone,app.operations.watchers)
 end
end
function finish!(app)
 kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
@testset "Original cancellation paths restore the actual editor without provider/file work" begin
 original=JSON.parsefile(joinpath(@__DIR__,"..","parity","fixtures","pi_bug_workflow.json"))
 @test original["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
 for case in original["fixtures"]
  app,requests,dir=fixture();Tachikoma.set_text!(app.input,"preserved unsent draft")
  before=J.timeline_export_jsonl(app.archive.timeline)
  T.bug_report_command!(app,"Actual reproduction")
  @test app.page==:bug_report
  for packet in case["inputs"];T.bug_report_input!(app,packet);end
  @test app.page==:chat
  @test app.menus.bug_report===nothing
  @test app.status==case["trace"][1][2]
  @test Tachikoma.text(app.input)=="preserved unsent draft"
  @test isempty(requests)
  @test J.timeline_export_jsonl(app.archive.timeline)==before
  @test isempty(filter(path->endswith(path,".zip"),readdir(dir)))
  finish!(app)
 end
end
@testset "Real transcript ZIP and reviewable issue draft, no publication" begin
 app,requests,dir=fixture();J.append_message!(app.session,Message(:user,"SENSITIVE TRANSCRIPT DATA"))
 T.submit!(app,"/bug reproducible")
 @test app.page==:bug_report
 for packet in ("\r","\r","\r");T.bug_report_input!(app,packet);end
 @test app.busy
 @test drain!(app)==:ok
 @test occursin("exported",app.status)
 files=filter(path->endswith(path,".zip"),readdir(dir;join=true));@test length(files)==1
 contents=read(`python3 -c 'import zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);print(z.read("session.jsonl").decode())' $(only(files))`,String)
 @test occursin("SENSITIVE TRANSCRIPT DATA",contents)
 @test isempty(requests)
 receipts=[entry for entry in J.timeline_entries(app.archive.timeline) if get(entry,"customType",nothing)=="JuliaForever2.bug-report"]
 @test length(receipts)==1
 @test receipts[1]["data"]["published"]===false
 @test receipts[1]["data"]["transcriptIncluded"]===true
 T.submit!(app,"/bug reviewable")
 for packet in ("\r","\r","\e[B","\r");T.bug_report_input!(app,packet);end
 @test drain!(app)==:ok
 issue=only(filter(path->endswith(path,"-issue.zip"),readdir(dir;join=true)))
 data=JSON.parse(read(`python3 -c 'import zipfile,json,sys;z=zipfile.ZipFile(sys.argv[1]);print(json.dumps({"names":z.namelist(),"draft":z.read("issue.md").decode(),"transcript":z.read("session.jsonl").decode()}))' $issue`,String))
 @test occursin("issues/new",data["draft"])
 @test !occursin("SENSITIVE TRANSCRIPT DATA",data["draft"])
 @test occursin("SENSITIVE TRANSCRIPT DATA",data["transcript"])
 @test isempty(requests)
 finish!(app)
end
@testset "Summary requires explicit yes and uses the real configured provider lane" begin
 app,requests,dir=fixture();J.append_message!(app.session,Message(:user,"Describe a real reproduction"))
 T.submit!(app,"/bug summary")
 for packet in ("\r","\e[B","\r","\r","\r");T.bug_report_input!(app,packet);end
 @test drain!(app)==:ok
 @test length(requests)==1
 path=only(filter(path->endswith(path,".zip"),readdir(dir;join=true)))
 data=JSON.parse(read(`python3 -c 'import zipfile,json,sys;z=zipfile.ZipFile(sys.argv[1]);print(json.dumps({"names":z.namelist(),"summary":z.read("summary.md").decode()}))' $path`,String))
 @test data["summary"]=="Actual fixture bug summary"
 @test !("session.jsonl" in data["names"])
 finish!(app)
end
@testset "Denied summary does not export or claim success" begin
 app,requests,dir=fixture(;reply=Failure("denied provider"))
 T.submit!(app,"/bug denied")
 for packet in ("\r","\e[B","\r","\r","\r");T.bug_report_input!(app,packet);end
 @test drain!(app)==:ok
 @test length(requests)==1
 @test occursin("no bug summary",app.status)
 @test isempty(filter(path->endswith(path,".zip"),readdir(dir)))
 @test app.page==:chat
 finish!(app)
end
@testset "Ctrl+C cancels overlay without discarding chat or quitting" begin
 app,requests,dir=fixture();Tachikoma.set_text!(app.input,"unsent")
 T.bug_report_command!(app,"before cancel")
 T.default_input!(app,Tachikoma.KeyEvent(:ctrl_c))
 @test app.page==:chat && !app.quit
 @test Tachikoma.text(app.input)=="unsent"
 @test isempty(requests)
 finish!(app)
end

end
