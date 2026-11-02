using Test, JSON, JuliaForever2
module PendingInputTests
using Test, JSON, JuliaForever2
const JF=JuliaForever2
texts(items)=[item.message.content for item in items]
queues(session)=(steering=texts(JF.pending_input_snapshot(session).steering),follow_up=texts(JF.pending_input_snapshot(session).follow_up))
function enqueue!(session,list)
    for item in list
        result=JF.queue_input!(session,item[2];kind=item[1]=="steer" ? :steering : :follow_up)
        @test result.ok
    end
end
struct FixtureExecutor
    on_work::Any
end
JF.execute!(executor::FixtureExecutor,session,action,context::ExecutionContext)=(executor.on_work(session);ExecutionResult(true,"done"))
struct PreparedFixtureProvider{F,P}
    respond::F
    prepare::P
end
(provider::PreparedFixtureProvider)(messages,session)=provider.respond(messages,session)
JF.maybe_compact!(session::Session,provider::PreparedFixtureProvider,context::ExecutionContext)=provider.prepare(session)
function run_case(config)
    requests=Vector{String}[];delivered=String[];actions=String[];calls=Ref(0)
    provider=(messages,session)->begin
        index=calls[];calls[]+=1
        push!(requests,[m.content for m in messages if m.role==:user])
        enqueue!(session,get(get(config,"atRequest",Dict()),string(index),Any[]))
        responses=get(config,"responses",Any[])
        kind=index<length(responses) ? responses[index+1] : "answer"
        kind=="tool" ? ActionDecision(RunJulia("inert fixture")) : kind in ("error","abort") ? Failure(kind) : Answer("answer-$index")
    end
    executor=FixtureExecutor(session->begin push!(actions,"work");enqueue!(session,get(config,"atTool",Any[]));end)
    prepared=PreparedFixtureProvider(provider,session->enqueue!(session,get(get(config,"atPrepare",Dict()),string(calls[]),Any[])))
    session=Session(Kernel(prepared);executor)
    @test JF.set_input_queue_mode!(session,:steering,get(config,"steeringMode","one-at-a-time")).ok
    @test JF.set_input_queue_mode!(session,:follow_up,get(config,"followUpMode","one-at-a-time")).ok
    enqueue!(session,get(config,"before",Any[]))
    sink=event->event.kind==:queued_input_delivered ? push!(delivered,event.data.message.content) : nothing
    result=run_turn!(session,"initial";context=ExecutionContext(;event_sink=sink))
    after=queues(session)
    if get(config,"continue",false)
        result=fetch(JF.submit_queued_turn!(session;context=ExecutionContext(;event_sink=sink)))
    end
    remaining=queues(session)
    close(session)
    (requests,delivered=vcat(["initial"],delivered),actions,after,remaining)
end
@testset "Exact original Agent queue ordering and real native loop checkpoints" begin
    reference=get(ENV,"PI_REFERENCE","");@test isdir(reference)
    evidence=get(ENV,"PENDING_INPUT_EVIDENCE",mktempdir());mkpath(evidence)
    output=joinpath(evidence,"original-fresh.json")
    run(`node $(joinpath(@__DIR__,"differential","pi_pending_inputs_oracle.mjs")) $reference $output`)
    original=JSON.parsefile(output)
    for case in original["cases"]
        got=run_case(case["config"])
        @test got.requests==case["requests"]
        @test got.delivered==case["delivered"]
        @test got.actions==case["actions"]
        @test got.after.steering==case["after"]["steering"]
        @test got.after.follow_up==case["after"]["follow_up"]
        @test got.remaining.steering==case["remaining"]["steering"]
        @test got.remaining.follow_up==case["remaining"]["follow_up"]
    end
    state=JF.PendingInputs()
    for expected in original["transitions"]
        step=expected["step"];op=step["op"]
        if op in ("steer","followUp")
            @test JF.queue_input!(state,step["text"];kind=op=="steer" ? :steering : :follow_up).ok
        elseif op in ("steeringMode","followUpMode")
            @test JF.set_input_queue_mode!(state,op=="steeringMode" ? :steering : :follow_up,step["value"]).ok
        elseif op=="clearSteering"
            @test JF.clear_pending_inputs!(state;kind=:steering).ok
        elseif op in ("clearAll","reset")
            @test JF.clear_pending_inputs!(state).ok
        end
        got=JF.pending_input_snapshot(state)
        @test texts(got.steering)==expected["steering"]
        @test texts(got.follow_up)==expected["follow_up"]
        @test texts(JF.peek_pending_inputs(state))==expected["peek"]
        @test (!isempty(got.steering)||!isempty(got.follow_up))==expected["has"]
        @test got.steering_mode==expected["steeringMode"] && got.follow_up_mode==expected["followUpMode"]
    end
end
@testset "Cancellation, denied inputs, bounded loops and isolated session ownership" begin
    session=Session(Kernel((messages,session)->Answer("done")))
    @test !JF.queue_input!(session,"").ok
    @test !JF.queue_input!(session,"a";kind=:other).ok
    @test !JF.queue_input!(session,Message(:assistant,"bad")).ok
    @test !JF.set_input_queue_mode!(session,:steering,"bogus").ok
    @test !JF.clear_pending_inputs!(session;kind=:other).ok
    first=JF.queue_input!(session,"first");second=JF.queue_input!(session,"second")
    @test first.id != second.id
    context=ExecutionContext();cancel!(context)
    @test !run_turn!(session,"cancelled";context).ok
    @test queues(session).steering==["first","second"]
    @test !fetch(JF.submit_queued_turn!(session;max_steps=0)).ok
    @test queues(session).steering==["first","second"]
    child=JF.child_session(session,nothing,false)
    @test isempty(JF.peek_pending_inputs(child))
    @test JF.queue_input!(child,"child").ok
    @test queues(session).steering==["first","second"]
    @test queues(child).steering==["child"]
    @test JF.clear_pending_inputs!(session).removed |> length == 2
    @test isempty(JF.peek_pending_inputs(session))
    @test !fetch(JF.submit_queued_turn!(session)).ok
    close(child);close(session)
    @test !JF.queue_input!(session,"closed").ok
    @test !JF.set_input_queue_mode!(session,:steering,"all").ok
end
@testset "Input arriving during action is deferred until action completion, preserving executor" begin
    started=Channel{Nothing}(1);release=Channel{Nothing}(1);requests=Vector{String}[];count=Ref(0)
    executor=FixtureExecutor(_->begin put!(started,nothing);take!(release);end)
    provider=(messages,session)->begin push!(requests,[m.content for m in messages if m.role==:user]);count[]+=1;count[]==1 ? ActionDecision(RunJulia("fixture")) : Answer("done");end
    session=Session(Kernel(provider);executor)
    handle=submit_turn!(session,"initial")
    take!(started)
    @test JF.queue_input!(session,"steer while working").ok
    @test JF.queue_input!(session,"follow later";kind=:follow_up).ok
    @test length(requests)==1
    put!(release,nothing)
    @test fetch(handle).ok
    @test requests==[["initial"],["initial","steer while working"],["initial","steer while working","follow later"]]
    @test session.runtime.executor===executor
    @test isempty(JF.peek_pending_inputs(session))
    close(session)
end
@testset "Queue continuation retains the installed loop wrappers and denies no work silently" begin
    seen=Any[]
    session=Session(Kernel((messages,session)->Answer("done")))
    wrap_component!(session.kernel, :loop) do inner
        (owner,prompt,limit)->begin push!(seen,prompt);Base.invokelatest(inner,owner,prompt,limit);end
    end
    @test JF.queue_input!(session,"retained").ok
    @test fetch(JF.submit_queued_turn!(session)).ok
    @test seen==[nothing]
    @test [m.content for m in session.messages if m.role==:user]==["retained"]
    @test !JF.set_input_queue_mode!(session,:steering,12).ok
    close(session)
end

end
