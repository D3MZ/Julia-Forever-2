using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module CommandDocumentsTest
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const J=JuliaForever2
const T=Base.get_extension(J,:JuliaForever2TerminalExt)
function fixture()
 dir=mktempdir();requests=String[]
 provider=(messages,session)->begin push!(requests,last(messages).content);Answer("done") end
 app=T.App(Session(Kernel(provider);working_directory=dir);settings_dir=joinpath(dir,"settings"),registry=J.ProviderRegistry(),theme_fallback="dark")
 app,requests,dir
end
function drain!(app)
 timedwait(10;pollint=0.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  !app.busy && all(istaskdone,app.operations.watchers)
 end
end
function finish!(app)
 kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
function ansi(row)
 sprint() do io
  for span in row
   print(io,"\e[0m");Tachikoma.write_style(io,span.style);print(io,span.content)
  end
  print(io,"\e[0m")
 end
end
const snapshots=Dict{String,Any}[]
function record!(app,id)
 area=Tachikoma.Rect(1,1,100,30);buffer=Tachikoma.Buffer(area);frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tuple{Int,Int,Matrix{Tachikoma.ColorRGBA}}[])
 T.default_view!(app,frame)
 lines=String[]
 for y in 1:30
  row=Tachikoma.Span[]
  for x in 1:100
   cell=buffer.content[(y-1)*100+x]
   cell.char!='\0' && push!(row,Tachikoma.Span(string(cell.char,cell.suffix),cell.style))
  end
  push!(lines,ansi(row))
 end
 push!(snapshots,Dict("id"=>id,"width"=>100,"ansiLines"=>lines))
end
@testset "Original shortcut table and factual installed bindings" begin
 original=JSON.parsefile(joinpath(@__DIR__,"..","parity","fixtures","pi_command_workflows.json"))
 bindings=Dict{String,String}(String(k)=>(v isa AbstractVector ? join(v,"/") : v) for(k,v)in original["hotkeys"]["bindings"])
 merge!(bindings,Dict("command.slash"=>"/","command.bash"=>"!","command.bashExcluded"=>"!!"))
 @test T.command_hotkeys_markdown(bindings;macos=false,windows=false)==original["hotkeys"]["markdown"]
 @test occursin("Unavailable",T.command_hotkeys_markdown(Dict{String,String}()))
 live=T.command_editor_bindings()
 @test live["tui.editor.cursorLeft"]=="left/ctrl+b"
 @test !haskey(live,"tui.input.tab")
 @test !haskey(live,"app.editor.external")
 @test T.command_key_label("ctrl+alt+]";macos=true)=="Ctrl+Option+]"
 @test !occursin('\e',T.command_hotkeys_markdown(bindings;extensions=["x"=>"unsafe\e[31m | text"]))
 app,requests,dir=fixture();before=J.timeline_export_jsonl(app.archive.timeline);record!(app,"hotkeys/before")
 T.hotkeys_command!(app;bindings)
 rows=T.archive_transcript_lines!(app,100)
 @test occursin("Keyboard Shortcuts",join(span.content for row in rows for span in row))
 @test isempty(requests) && isempty(app.session.messages)
 @test J.timeline_export_jsonl(app.archive.timeline)==before
 @test app.page==:chat
 record!(app,"hotkeys/after")
 for width in (100,60,30)
  doc=last(app.transcript.documents.documents)
  push!(snapshots,Dict("id"=>"hotkeys/default","width"=>width,"ansiLines"=>ansi.(T.command_document_rows(doc,width))))
 end
 T.append_command_document!(app,"More","Actual extra")
 @test length(app.transcript.documents.documents)==2
 J.append_message!(app.session,Message(:user,"later"))
 rows=T.archive_transcript_lines!(app,100)
 @test count(row->occursin("Keyboard Shortcuts",join(span.content for span in row)),rows)==1
 @test findfirst(row->occursin("Actual extra",join(span.content for span in row)),rows)<findfirst(row->occursin("later",join(span.content for span in row)),rows)
 T.submit!(app,"/new");@test drain!(app)==:ok
 @test isempty(app.transcript.documents.documents)
 finish!(app)
end
@testset "Session documents snapshot archive without model calls or mutation" begin
 app,requests,dir=fixture();before=J.timeline_export_jsonl(app.archive.timeline)
 record!(app,"session/before");T.submit!(app,"/session");record!(app,"session/after")
 @test isempty(requests) && isempty(app.session.messages)
 @test J.timeline_export_jsonl(app.archive.timeline)==before
 @test only(app.transcript.documents.documents).content.statistics.messages.total==0
 J.append_message!(app.session,Message(:user,"after snapshot"))
 @test only(app.transcript.documents.documents).content.statistics.messages.total==0
 original=JSON.parsefile(joinpath(@__DIR__,"..","parity","fixtures","pi_command_workflows.json"))
 for case in original["cases"],width in (100,60,30)
  stats=J.session_statistics(case["entries"];id=case["id"],name=case["id"])
  rows=T.command_stats_rows(stats,width;selected_model="openai/fixture")
  push!(snapshots,Dict("id"=>"session/"*case["id"],"width"=>width,"ansiLines"=>ansi.(rows)))
 end
 finish!(app)
end
@testset "Actual cached/refresh/error/cancel release transitions" begin
 app,requests,dir=fixture();calls=Ref(0)
 transport=(url,ctx,policy)->begin calls[]+=1;(status=200,body="[]",reason="") end
 record!(app,"changelog/before")
 T.changelog_command!(app,"";transport);@test drain!(app)==:ok
 @test calls[]==0
 @test occursin("explicitly",T.release_changelog_markdown(J.ReleaseChangelog(J.JF2_RELEASES_PAGE,"now",J.ReleaseNote[])))
 @test occursin("No bundled",last(app.transcript.documents.documents).content)
 record!(app,"changelog/unfetched")
 T.changelog_command!(app,"refresh";transport);@test drain!(app)==:ok
 @test calls[]==1
 @test isfile(joinpath(app.settings.directory,"release-changelog.json"))
 @test occursin("No changelog entries found",last(app.transcript.documents.documents).content)
 record!(app,"changelog/verified-empty")
 T.changelog_command!(app,"";transport);@test drain!(app)==:ok
 @test calls[]==1
 error_transport=(url,ctx,policy)->(status=403,body="{}",reason="denied fixture")
 count=length(app.transcript.documents.documents)
 T.changelog_command!(app,"refresh";transport=error_transport);@test drain!(app)==:ok
 @test occursin("denied fixture",app.status)
 @test length(app.transcript.documents.documents)==count
 record!(app,"changelog/error")
 entered=Channel{Nothing}(1)
 blocked=(url,ctx,policy)->begin put!(entered,nothing);while !J.cancelled(ctx);sleep(.001);end;(status=0,body="",reason="Cancelled fixture") end
 T.changelog_command!(app,"refresh";transport=blocked);take!(entered)
 J.cancel!(app.operations.active);@test drain!(app)==:ok
 @test occursin("Cancelled fixture",app.status)
 @test length(app.transcript.documents.documents)==count
 @test isempty(requests) && isempty(app.session.messages)
 record!(app,"changelog/cancelled")
 finish!(app)
end
@testset "Accepted messages queued during actual release retrieval are delivered only after success" begin
 for success in (true,false)
  app,requests,dir=fixture();entered=Channel{Nothing}(1);release=Channel{Nothing}(1)
  transport=(url,context,policy)->begin put!(entered,nothing);take!(release);(status=success ? 200 : 403,body="[]",reason=success ? "" : "denied fixture") end
  T.changelog_command!(app,"refresh";transport);take!(entered)
  accepted=T.submit_literal_input!(app,"queued after notes";kind=:follow_up)
  @test accepted.ok
  @test isempty(requests)
  put!(release,nothing);@test drain!(app)==:ok
  @test isempty(T.pending_input_ids(app))==success
  @test requests==(success ? ["queued after notes"] : String[])
  @test any(message->message.content=="queued after notes",app.session.messages)==success
  @test isempty(app.transcript.documents.documents)==!success
  finish!(app)
 end
end
@testset "Actual clear and compaction discard transient output, failed compaction retains it" begin
 app,requests,dir=fixture()
 T.submit!(app,"/session")
 before=app.transcript.documents.revision
 T.submit!(app,"/clear")
 @test isempty(app.transcript.documents.documents)
 @test app.transcript.documents.revision>before
 T.submit!(app,"/session")
 T.submit!(app,"/compact")
 @test drain!(app)==:ok
 @test length(app.transcript.documents.documents)==1
 @test occursin("nothing_to_compact",app.status)
 J.append_message!(app.session,Message(:user,"earlier"))
 J.append_message!(app.session,Message(:assistant,"earlier response"))
 J.append_message!(app.session,Message(:user,"latest"))
 T.submit!(app,"/compact")
 @test drain!(app)==:ok
 @test isempty(app.transcript.documents.documents)
 @test any(entry->get(entry,"type",nothing)=="compaction",J.timeline_entries(app.archive.timeline))
 @test length(requests)==1
 finish!(app)
end
path=get(ENV,"COMMAND_DOCUMENT_EVIDENCE","")
!isempty(path) && write(path,JSON.json(Dict("snapshots"=>snapshots)))
end
