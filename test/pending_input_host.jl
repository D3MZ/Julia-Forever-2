using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module PendingHostTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function app_fixture(;blocked=false,reply=Answer("done"),preferences=Dict{String,String}())
    directory=mktempdir();write(joinpath(directory,"terminal-settings.json"),JSON.json(preferences))
    started=Channel{Nothing}(8);release=Channel{Nothing}(8);requests=Vector{String}[]
    provider=(messages,session)->begin
        push!(requests,[m.content for m in messages if m.role==:user]);put!(started,nothing)
        context=JF.current_execution_context()
        if blocked
            while !isready(release) && !JF.cancelled(context)
                sleep(0.001)
            end
            isready(release) && take!(release)
        end
        JF.cancelled(context) ? Failure("cancelled fixture") : reply
    end
    app=T.App(Session(Kernel(provider));settings_dir=directory,registry=JF.ProviderRegistry(),theme_fallback="dark")
    app.directory="fixture (main)"
    (app,started,release,requests,directory)
end
function finish!(app)
    kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
function drain!(app)
    timedwait(5;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
function packet!(app,raw;key=:enter)
    T.page_input!(app,Val(:chat),KeyEvent(key),collect(codeunits(raw)))
end
function ansi(row)
    sprint() do io
        for span in row
            print(io,"\e[0m");Tachikoma.write_style(io,span.style);print(io,span.content)
        end
        print(io,"\e[0m")
    end
end
function backend_lines(backend,width,height)
    [sprint() do io
        for x in 1:width
            cell=backend.buf.content[(y-1)*width+x]
            if cell.char != Tachikoma.WIDE_CHAR_PAD
                print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for y in 1:height]
end
function dock_frame(app,width)
    rows=T.pending_input_lines(app,width)
    backend=TestBackend(width,max(1,length(rows)))
    T.session_draw_lines!(backend.buf,1,1,width,rows)
    backend_lines(backend,width,length(rows))
end
function full_frame(app,width,height)
    backend=TestBackend(width,height)
    frame=Tachikoma.Frame(backend.buf,backend.buf.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
    Tachikoma.view(app,frame)
    backend_lines(backend,width,height)
end
function queue_text(app)
    snapshot=JF.pending_input_snapshot(app.session)
    Dict("steering"=>[v.message.content for v in snapshot.steering],"followUp"=>[v.message.content for v in snapshot.follow_up])
end
@testset "Actual pinned interactive handlers and native App pending dock transitions" begin
    reference=get(ENV,"PI_REFERENCE","")
    evidence=get(ENV,"PENDING_HOST_EVIDENCE",mktempdir());mkpath(evidence)
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-pending-host-oracle.json"))
    if !isempty(reference)
        @test isdir(reference)
        output=joinpath(evidence,"original-fresh.json")
        run(`node $(joinpath(@__DIR__,"differential","pi_pending_host_oracle.mjs")) $reference $output`)
        fresh=JSON.parsefile(output)
        @test fresh==original
        original=fresh
    end
    frames=Any[];screens=Any[];native=Any[]
    for packet in original["packets"]
        @test T.pending_follow_up_key(packet["input"])==packet["follow"]
        @test T.pending_dequeue_key(packet["input"])==packet["dequeue"]
    end
    for config in original["cases"]
        streaming=get(config,"streaming",true)
        app,started,release,requests,directory=app_fixture(;blocked=streaming)
        if streaming
            T.submit!(app,"initial");take!(started)
            get(config,"compacting",false) && (app.operations.active_kind=:compaction_done)
        end
        expected=filter(state->state["id"]==config["id"],original["states"])
        for state in expected
            step=state["step"];action=step["action"]
            haskey(step,"text") && Tachikoma.set_text!(app.input,step["text"])
            if action=="enter"
                packet!(app,"\r")
            elseif action=="follow"
                packet!(app,"\e\r")
            elseif action=="dequeue"
                packet!(app,"\e[1;3A";key=:up)
            elseif action=="escape"
                packet!(app,"\e";key=:escape)
            end
            !streaming && app.busy && (@test drain!(app)==:ok)
            @test queue_text(app)==state["queues"]
            @test Tachikoma.text(app.input)==state["editor"]
            action=="dequeue" && (@test app.status==state["status"])
            if action=="escape"
                @test JF.cancelled(app.operations.active.context)
            end
            id=string(config["id"],"/",state["index"])
            push!(native,Dict("id"=>id,"queues"=>queue_text(app),"editor"=>Tachikoma.text(app.input),"status"=>app.status,"page"=>String(app.page)))
            for width in (100,60,30,10)
                rows=T.pending_input_lines(app,width)
                push!(frames,Dict("id"=>id,"width"=>width,"ansiLines"=>dock_frame(app,width)))
            end
            push!(screens,Dict("id"=>id,"width"=>100,"ansiLines"=>full_frame(app,100,24)))
        end
        if streaming
            handle=app.operations.active
            isnothing(handle) || JF.cancel!(handle)
            put!(release,nothing)
            @test drain!(app)==:ok
        end
        finish!(app)
    end
    write(joinpath(evidence,"candidate.json"),JSON.json(Dict("snapshots"=>frames,"states"=>native)))
    write(joinpath(evidence,"native-full-app.json"),JSON.json(Dict("snapshots"=>screens)))
end
@testset "Real persisted queue modes, literal submissions and denied updates" begin
    app,started,release,requests,directory=app_fixture(;preferences=Dict("steering-mode"=>"all","follow-up-mode"=>"all"))
    @test JF.pending_input_snapshot(app.session).steering_mode=="all"
    @test JF.pending_input_snapshot(app.session).follow_up_mode=="all"
    T.set_setting_value!(app,"steering-mode","one-at-a-time")
    @test JF.pending_input_snapshot(app.session).steering_mode=="one-at-a-time"
    @test JSON.parsefile(joinpath(directory,"terminal-settings.json"))["steering-mode"]=="one-at-a-time"
    T.set_setting_value!(app,"steering-mode","bad")
    @test JF.pending_input_snapshot(app.session).steering_mode=="one-at-a-time"
    badpath=joinpath(directory,"not-directory");write(badpath,"x");app.settings.directory=badpath
    T.set_setting_value!(app,"steering-mode","all")
    @test JF.pending_input_snapshot(app.session).steering_mode=="one-at-a-time"
    app.settings.directory=directory
    @test T.submit_literal_input!(app,"/julia error(\"must be literal\")").ok
    @test drain!(app)==:ok
    @test requests==[["/julia error(\"must be literal\")"]]
    @test app.session.messages[1].content=="/julia error(\"must be literal\")"
    Tachikoma.set_text!(app.input,"retained after denial");close(app.session)
    @test !T.submit_literal_input!(app,Tachikoma.text(app.input)).ok
    @test Tachikoma.text(app.input)=="retained after denial"
    finish!(app)
end
@testset "Completed-turn race resumes once; errors and no-progress loops preserve pending work" begin
    for kind in (:success,:failure,:custom)
        app,started,release,requests,directory=app_fixture(;reply=kind==:failure ? Failure("fixture denied") : Answer("done"))
        if kind==:custom
            install!(app.session.kernel,ComponentSpec(:loop,(session,prompt,limit)->ExecutionResult(true,"custom loop")))
        end
        T.submit!(app,"initial");handle=app.operations.active;wait(handle;throw=false)
        Tachikoma.set_text!(app.input,"late incoming")
        packet!(app,"\r")
        @test Tachikoma.text(app.input)==""
        @test queue_text(app)["steering"]==["late incoming"]
        @test drain!(app)==:ok
        if kind==:success
            @test requests==[["initial"],["initial","late incoming"]]
            @test isempty(T.pending_input_ids(app))
        else
            @test queue_text(app)["steering"]==["late incoming"]
            @test kind==:failure ? app.status=="fixture denied" : occursin("did not consume",app.status)
            @test length(app.operations.watchers)<=2
        end
        finish!(app)
    end
end
end
