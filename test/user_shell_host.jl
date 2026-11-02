using Test,JuliaForever2,Tachikoma,CommonMark,JSON
module UserShellHostTests
using Test,JuliaForever2,Tachikoma,CommonMark,JSON
const J=JuliaForever2
const T=Base.get_extension(J,:JuliaForever2TerminalExt)
function settle(app;timeout=10)
    timedwait(timeout;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && isnothing(app.operations.shell.active)
    end==:ok
end
function fixture(;provider=(messages,session)->Answer("fixture reply"))
    session=Session(Kernel(provider);working_directory=mktempdir())
    T.App(session;settings_dir=mktempdir(),registry=J.ProviderRegistry(),theme_fallback="dark")
end
function finish(app)
    T.finish_shutdown!(app);close(app.session.kernel)
end
function install_adapter(app)
    directory=mktempdir()
    process=run(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__,"..","scripts","build_terminal_jobs.jl")) $directory`)
    app.operations.shell.adapter=J.TerminalJobs.TerminalJobAdapter(;library=joinpath(directory,"libjf2_terminal_jobs.so"))
end
@testset "Actual raw user shell host executes, archives and excludes without model dispatch" begin
 calls=String[];app=fixture(;provider=(messages,session)->(push!(calls,last(messages).content);Answer("fixture reply")))
 install_adapter(app)
 @test isnothing(T.raw_user_shell("!")) && isnothing(T.raw_user_shell("!!  "))
 @test T.raw_user_shell(" !! printf fixture ")==(command="printf fixture",exclude_from_context=true)
 editor=T.chat_editor_state!(app);T.chat_write!(editor,"! printf 'fixture output\\n'",27)
 @test T.chat_host_submit!(app,editor,T.chat_text(editor)).ok
 @test isempty(Tachikoma.text(app.input))
 @test settle(app)
 @test isempty(calls)
 records=J.timeline_messages(app.archive.timeline)
 @test length(records)==1 && only(records)["role"]=="bashExecution"
 @test only(records)["output"]=="fixture output\n"
 @test isempty(app.operations.shell.pending)
 @test T.submit!(app,"!! printf 'excluded fixture\\n'").ok
 @test settle(app)
 @test length(J.timeline_messages(app.archive.timeline))==2
 @test length(J.context_messages(app.session))==1
 @test !occursin("excluded fixture",only(J.context_messages(app.session)).content)
 @test T.submit_literal_input!(app,"! literal not shell").ok
 @test settle(app)
 @test calls==["! literal not shell"]
 @test length(J.timeline_messages(app.archive.timeline))==4
 finish(app)
end
@testset "One shell owner, cancellation, failure and literal resource isolation" begin
 calls=String[];app=fixture(;provider=(messages,session)->(push!(calls,last(messages).content);Answer("fixture reply")));install_adapter(app)
 @test T.submit!(app,"! printf start; sleep 5").ok
 T.chat_write!(T.chat_editor_state!(app),"! printf forbidden_second",25)
 @test !T.chat_host_submit!(app,T.chat_editor_state!(app),Tachikoma.text(app.input)).ok
 @test Tachikoma.text(app.input)=="! printf forbidden_second"
 original=app.session
 T.session_action!(app,:new);@test app.session===original && !app.busy
 T.clear_command!(app,"");@test app.session===original
 @test T.chat_editor_escape!(app,T.chat_editor_state!(app)).action==:cancel_shell
 @test settle(app)
 @test only(J.timeline_messages(app.archive.timeline))["cancelled"]
 app.operations.shell.interceptor=event->error("fixture interceptor denied")
 @test T.submit!(app,"! touch never_created").ok
 @test settle(app)
 @test !isfile(joinpath(app.settings.workspace,"never_created"))
 @test occursin("fixture interceptor denied",app.status)
 @test length(J.timeline_messages(app.archive.timeline))==1
 app.operations.shell.interceptor=event->J.UserShellProcess.Result(;ok=true,output="actual extension fixture",exit_code=9)
 @test T.submit!(app,"! extension fixture").ok
 @test settle(app)
 @test last(J.timeline_messages(app.archive.timeline))["exitCode"]==9
 @test isempty(calls)
 finish(app)
end
@testset "Agent turn defers shell record until tool ordering is complete" begin
 started=Channel{Bool}(1);release=Channel{Bool}(1)
 app=fixture(;provider=(messages,session)->begin put!(started,true);take!(release);Answer("completed agent fixture") end);install_adapter(app)
 @test T.submit_literal_input!(app,"agent fixture").ok
 take!(started)
 @test T.submit!(app,"! printf concurrent_fixture").ok
 @test timedwait(10;pollint=0.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  isnothing(app.operations.shell.active)
 end==:ok
 @test length(app.operations.shell.pending)==1
 @test all(record->get(record,"role","")!="bashExecution",J.timeline_messages(app.archive.timeline))
 put!(release,true);@test settle(app)
 @test [record["role"] for record in J.timeline_messages(app.archive.timeline)]==["user","assistant","bashExecution"]
 @test isempty(app.operations.shell.pending)
 finish(app)
end
@testset "Journal failure retains real executed receipt without retry or result loss" begin
 app=fixture();install_adapter(app)
 timeline=T.ensure_archive!(app.archive,app.session)
 write(timeline.path,"external conflicting writer fixture")
 @test T.submit!(app,"! printf x >> invocation-count; printf retained_fixture").ok
 @test settle(app)
 run=only(app.operations.shell.pending)
 @test run.uncertain && occursin("archival outcome",app.status)
 @test isempty(J.history_snapshot(app.session).messages)
 @test isfile(run.checkpoint)
 @test JSON.parsefile(run.checkpoint)["message"]["output"]=="retained_fixture"
 countpath=joinpath(app.settings.workspace,"invocation-count")
 @test read(countpath,String)=="x"
 T.flush_user_shell!(app);@test read(countpath,String)=="x"
 @test !T.submit!(app,"! printf must_not_run").ok
 @test !T.require_user_shell_idle!(app)
 finish(app)
 @test isfile(run.checkpoint)
end

@testset "Literal registered prompts, shell draft and real recovery boundaries" begin
 calls=String[];app=fixture(;provider=(messages,session)->(push!(calls,last(messages).content);Answer("literal fixture")));install_adapter(app)
 T.register_prompt!(app,"literal-bang","Literal source fixture";content="! touch resource_must_not_execute")
 T.chat_write!(T.chat_editor_state!(app),"/literal-bang",13)
 @test T.chat_host_submit!(app,T.chat_editor_state!(app),"/literal-bang").ok
 @test settle(app)
 @test calls==["! touch resource_must_not_execute"]
 @test !isfile(joinpath(app.settings.workspace,"resource_must_not_execute"))
 T.chat_write!(T.chat_editor_state!(app)," !! draft",9)
 @test T.chat_editor_escape!(app,T.chat_editor_state!(app)).action==:clear_shell_draft
 @test isempty(Tachikoma.text(app.input))
 app.operations.shell.interceptor=event->T.UserShellExecution(;execute=(event;on_chunk,cancelled)->begin
    on_chunk("real fixture callback")
    J.UserShellProcess.Result(;ok=true,output="real fixture callback",exit_code=0)
 end)
 @test T.submit!(app,"! extension_operation").ok
 @test settle(app)
 @test last(J.timeline_messages(app.archive.timeline))["output"]=="real fixture callback"
 app.operations.shell.interceptor=nothing
 @test T.submit!(app,"! printf ready; sleep 5").ok
 run=app.operations.shell.active
 @test !run.expanded
 T.user_shell_expand!(app,true);@test run.expanded
 run.deferred=true;T.user_shell_expand!(app,false);@test run.expanded
 finish(app)
 @test istaskdone(run.task) && run.result.cancelled
 @test isfile(run.checkpoint)
 @test JSON.parsefile(run.checkpoint)["message"]["cancelled"]
end
@testset "Missing recovery directory authority cannot start a process" begin
 app=fixture();write(joinpath(app.settings.directory,"shell-results"),"fixture blocking file")
 T.chat_write!(T.chat_editor_state!(app),"! touch denied_fixture",22)
 @test !T.chat_host_submit!(app,T.chat_editor_state!(app),"! touch denied_fixture").ok
 @test Tachikoma.text(app.input)=="! touch denied_fixture"
 @test isnothing(app.operations.shell.active)
 @test !isfile(joinpath(app.settings.workspace,"denied_fixture"))
 finish(app)
end

@testset "Busy Alt+Enter preserves a leading bang as follow-up text, never shell" begin
 started=Channel{Bool}(1);release=Channel{Bool}(1);calls=Ref(0)
 app=fixture(;provider=(messages,session)->begin
  calls[]+=1
  if calls[]==1;put!(started,true);take!(release);end
  Answer("follow-up fixture")
 end)
 @test T.submit_literal_input!(app,"agent fixture").ok
 take!(started)
 text="! touch followup_must_not_execute"
 T.chat_write!(T.chat_editor_state!(app),text,length(text))
 @test T.chat_host_submit!(app,T.chat_editor_state!(app),text;kind=:follow_up).ok
 @test isnothing(app.operations.shell.active)
 @test only(J.pending_input_snapshot(app.session).follow_up).message.content==text
 put!(release,true);@test settle(app)
 @test !isfile(joinpath(app.settings.workspace,"followup_must_not_execute"))
 @test calls[]==2
 finish(app)
end

end
