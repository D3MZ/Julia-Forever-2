using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module PromptHost
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function fixture(;blocked=false)
 directory=mktempdir();started=Channel{Nothing}(8);release=Channel{Nothing}(8);requests=Vector{String}[]
 provider=(messages,session)->begin
  push!(requests,[m.content for m in messages if m.role==:user]);put!(started,nothing)
  context=JF.current_execution_context()
  if blocked
   while !isready(release) && !JF.cancelled(context);sleep(0.001);end
   isready(release)&&take!(release)
  end
  JF.cancelled(context) ? Failure("cancelled fixture") : Answer("done")
 end
 app=T.App(Session(Kernel(provider);working_directory=directory);settings_dir=joinpath(directory,"settings"),registry=JF.ProviderRegistry(),theme_fallback="dark")
 (app,started,release,requests,directory)
end
function drain!(app)
 timedwait(8;pollint=0.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  !app.busy && all(istaskdone,app.operations.watchers)
 end
end
function finish!(app)
 kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
archive_users(app)=[entry["message"]["content"] for entry in JF.timeline_entries(app.archive.timeline) if get(entry,"type",nothing)=="message" && get(entry["message"],"role",nothing)=="user"]
@testset "Real prompt registration, invocation, provider and durable archive" begin
 app,started,release,requests,dir=fixture()
 prompts=joinpath(dir,".pi","prompts");mkpath(prompts)
 path=joinpath(prompts,"demo.md");write(path,"---\ndescription: actual description\nargument-hint: '[name]'\n---\nHello \$1 \${2:-default}")
 T.discover_disk_resources!(app;directory=dir,agent_dir=joinpath(dir,"agent"))
 loaded=only(filter(item->item.name=="demo",app.menus.prompts))
 @test loaded.content=="Hello \$1 \${2:-default}"
 @test loaded.path==path
 @test loaded.argument_hint=="[name]"
 @test only(filter(command->command.name=="demo",T.discover_commands(app))).description=="[name] — actual description"
 @test isempty(requests)
 @test isempty(app.session.messages)
 T.submit!(app,"/demo \"日本 語\" \"\"")
 @test drain!(app)==:ok
 @test requests==[["Hello 日本 語 default"]]
 @test first(app.session.messages).content=="Hello 日本 語 default"
 @test only(archive_users(app))=="Hello 日本 語 default"
 @test isfile(app.archive.timeline.path)
 @test Tachikoma.text(app.input)==""
 write(joinpath(prompts,"invalid.md"),"---\ndescription: [broken\n---\nbody")
 T.discover_disk_resources!(app;directory=dir,agent_dir=joinpath(dir,"agent"))
 @test !isempty(app.menus.resource_warnings)
 @test !any(item->item.name=="invalid",app.menus.prompts)
 T.register_prompt!(app,"literal","";content="/julia error(\"not code\")")
 T.submit!(app,"/literal")
 @test drain!(app)==:ok
 @test last(last(requests))=="/julia error(\"not code\")"
 @test last(archive_users(app))=="/julia error(\"not code\")"
 T.register_prompt!(app,"metadata","old constructor")
 Tachikoma.set_text!(app.input,"/metadata x");before=length(requests)
 T.submit!(app,"/metadata x")
 @test !app.busy
 @test length(requests)==before
 @test Tachikoma.text(app.input)=="/metadata x"
 @test occursin("content unavailable",app.status)
 T.register_prompt!(app,"empty","";content="")
 T.submit!(app,"/empty")
 @test Tachikoma.text(app.input)=="/empty"
 @test app.status=="Input is empty"
 @test T.RegisteredPrompt("old","compat").content===nothing
 finish!(app)
end
@testset "Actual skill file and missing-file rejection" begin
 app,started,release,requests,dir=fixture()
 path=joinpath(dir,"SKILL.md");write(path,"---\nname: fixture\ndescription: actual\n---\nUse relative references.")
 T.register_skill!(app,"fixture",path)
 T.submit!(app,"/skill:fixture exact \"raw arguments\"")
 @test drain!(app)==:ok
 expected="<skill name=\"fixture\" location=\"$path\">\nReferences are relative to $dir.\n\nUse relative references.\n</skill>\n\nexact \"raw arguments\""
 @test requests==[[expected]]
 @test archive_users(app)==[expected]
 rm(path)
 T.submit!(app,"/skill:fixture x")
 @test !app.busy
 @test length(requests)==1
 @test occursin("unavailable",app.status)
 @test Tachikoma.text(app.input)=="/skill:fixture x"
 finish!(app)
end
@testset "Actual streaming steering, follow-up, cancellation and closed-session rejection" begin
 app,started,release,requests,dir=fixture(;blocked=true)
 T.register_prompt!(app,"demo","";content="Expanded \$1")
 T.submit!(app,"initial");take!(started)
 T.submit!(app,"/demo steering")
 @test [v.message.content for v in JF.pending_input_snapshot(app.session).steering]==["Expanded steering"]
 @test archive_users(app)==["initial"]
 Tachikoma.set_text!(app.input,"/demo follow");T.follow_up_terminal_input!(app)
 @test [v.message.content for v in JF.pending_input_snapshot(app.session).follow_up]==["Expanded follow"]
 @test Tachikoma.text(app.input)==""
 T.register_prompt!(app,"missing","metadata only")
 Tachikoma.set_text!(app.input,"/missing x");T.follow_up_terminal_input!(app)
 @test Tachikoma.text(app.input)=="/missing x"
 @test occursin("content unavailable",app.status)
 @test length(JF.pending_input_snapshot(app.session).steering)+length(JF.pending_input_snapshot(app.session).follow_up)==2
 for _ in 1:3;put!(release,nothing);end
 @test drain!(app)==:ok
 @test last(requests)==["initial","Expanded steering","Expanded follow"]
 @test archive_users(app)==["initial","Expanded steering","Expanded follow"]
 while isready(started);take!(started);end
 T.submit!(app,"blocked");take!(started)
 JF.cancel!(app.operations.active);put!(release,nothing)
 @test drain!(app)==:ok
 @test occursin("cancel",app.status)
 before=length(requests);close(app.session)
 T.submit!(app,"/demo closed")
 @test !app.busy
 @test length(requests)==before
 @test Tachikoma.text(app.input)=="/demo closed"
 @test app.status=="Session is closed"
 finish!(app)
end
end
