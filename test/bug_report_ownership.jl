module BugReportOwnershipTests
using Test,JuliaForever2,Tachikoma,CommonMark
const J=JuliaForever2
const T=Base.get_extension(J,:JuliaForever2TerminalExt)
function fixture()
 dir=mktempdir();calls=Ref(0)
 kernel=Kernel((messages,session)->begin calls[]+=1;Answer("unused") end)
 app=T.App(Session(kernel;working_directory=dir);settings_dir=joinpath(dir,"settings"),registry=J.ProviderRegistry(),theme_fallback="dark")
 app,kernel,calls,dir
end
function drain!(app)
 timedwait(10;pollint=.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  !app.busy && all(istaskdone,app.operations.watchers)
 end
end
@testset "Absent and replaced archive ownership never starts an export" begin
 app,kernel,calls,dir=fixture();timeline=app.archive.timeline
 app.archive.timeline=nothing
 @test isnothing(T.bug_report_command!(app,"unavailable"))
 @test app.page==:chat && isnothing(app.menus.bug_report)
 @test occursin("No active session archive",app.status)
 app.archive.timeline=timeline
 T.bug_report_command!(app,"gone before export");control=app.menus.bug_report;control.transcript=true
 app.archive.timeline=nothing
 @test isnothing(T.bug_report_export!(app,control))
 @test app.page==:chat && !app.busy
 @test occursin("No active session archive",app.status)
 app.archive.timeline=timeline
 T.bug_report_command!(app,"different owner");control=app.menus.bug_report;control.owner="not-this-session"
 @test isnothing(T.bug_report_export!(app,control))
 @test occursin("different session",app.status)
 @test !app.busy && isempty(filter(path->endswith(path,".zip"),readdir(dir))) && calls[]==0
 T.finish_shutdown!(app);close(kernel)
end
@testset "Cancellation uses the captured handle and tolerates completion before a late key" begin
 app,kernel,calls,dir=fixture();T.bug_report_command!(app,"cancelled")
 control=app.menus.bug_report;control.stage=:working
 @test isnothing(T.bug_report_input!(app,"\e"))
 entered=Channel{Nothing}(1)
 handle=J.submit_managed!(app.session,app.session,T.ui_context(app)) do context
  put!(entered,nothing)
  while !J.cancelled(context);sleep(.001);end
  J.ExecutionResult(false,"cancelled fixture")
 end
 T.track_operation!(app,handle,:bug_report_done,"fixture working");take!(entered)
 @test isnothing(T.bug_report_input!(app,"\e"))
 @test drain!(app)==:ok
 @test J.cancelled(handle.context)
 @test app.operations.active===nothing && !app.busy && app.page==:chat
 @test isnothing(T.bug_report_input!(app,"\e"))
 @test calls[]==0 && isempty(filter(path->endswith(path,".zip"),readdir(dir)))
 T.finish_shutdown!(app);close(kernel)
end
@testset "Report text remains plain validated UTF-8 for styled input" begin
 text=Base.AnnotatedString("actual 🙂",[(1:6,:fixture,true)])
 @test J.bug_report_bytes(text)==collect(codeunits("actual 🙂"))
 @test J.bug_report_text(text,"description",100) isa String
 report=J.local_bug_report(text;id="string-boundary",created_at="2026-11-02T00:00:00Z")
 @test occursin("actual 🙂",String(copy(Dict(report.files)["report.md"])))
 @test J.bug_report_zip(report) isa Vector{UInt8}
end

end
