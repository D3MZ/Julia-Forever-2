using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module SessionPreferenceLifecycleTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
function drain!(app)
    timedwait(20;pollint=0.002) do
        while isready(app.queue.channel)
            Tachikoma.update!(app,take!(app.queue.channel))
        end
        !app.busy && all(istaskdone,app.operations.watchers)
    end
end
function capture(app,id)
    width=60;height=24;area=Tachikoma.Rect(1,1,width,height);buffer=Tachikoma.Buffer(area)
    app.area=area;frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
    Tachikoma.view(app,frame)
    lines=[sprint(io->(foreach(span->(Tachikoma.write_style(io,span.style);print(io,span.content)),line);print(io,"\e[0m"))) for line in T.startup_buffer_rows(buffer,width,height)]
    (;id,width,terminalAnsiLines=lines)
end
@testset "Persisted settings remain real after every session replacement" begin
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-session-preferences.json"))
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    if isdir(reference)
        mktempdir() do dir
            path=joinpath(dir,"original.json")
            run(`node $(joinpath(@__DIR__,"differential","pi_session_preferences_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $path`)
            @test JSON.parsefile(path)==original
        end
    end
    frames=[];observations=[]
    for (case_index,case) in enumerate(original["cases"]), operation in (:new,:clone,:fork,:resume,:import)
        mktempdir() do directory
            settings=joinpath(directory,"config");mkpath(settings)
            preferences=Dict("steering-mode"=>case["steering"],"follow-up-mode"=>case["followUp"],"hide-thinking"=>string(case["hideThinking"]),"quiet-startup"=>"true")
            settings_file=joinpath(settings,"terminal-settings.json");write(settings_file,JSON.json(preferences));saved=read(settings_file)
            kernel=JF.Kernel();app=T.App(JF.Session(kernel;working_directory=directory);settings_dir=settings,theme_fallback="dark")
            JF.append_message!(app.session,JF.Message(:user,"fixture initial user"))
            JF.append_message!(app.session,JF.Message(:assistant,"fixture initial answer",:answer))
            source=app.archive.timeline;source_entries=JF.timeline_entries(source)
            foreign=JF.SessionTimeline(directory)
            JF.timeline_append_message!(foreign,Dict("role"=>"user","content"=>"foreign user"))
            JF.timeline_append_message!(foreign,Dict("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>"foreign answer")]))
            path=joinpath(directory,"import.jsonl");write(path,JF.timeline_export_jsonl(foreign))
            argument=operation==:fork ? first(app.archive.entry_ids) : operation==:resume ? source.identity.id : operation==:import ? path : ""
            old=app.session
            push!(frames,capture(app,"$(operation).$(case_index).before"))
            T.session_action!(app,operation,argument)
            @test drain!(app)==:ok
            @test app.session!==old && !isopen(old) && isopen(app.session)
            actual=JF.pending_input_snapshot(app.session)
            @test actual.steering_mode==case["steering"]
            @test actual.follow_up_mode==case["followUp"]
            @test app.transcript.display.hide_thinking==case["hideThinking"]
            @test isempty(actual.steering) && isempty(actual.follow_up)
            @test read(settings_file)==saved
            # Verify actual delivery cardinality, journal mutation and rendered thinking visibility.
            for (kind,expected_mode) in ((:steering,case["steering"]),(:follow_up,case["followUp"]))
                for n in 1:2
                    @test JF.queue_input!(app.session,"new $kind $n";kind).ok
                end
                delivered=JF.deliver_pending_inputs!(app.session,kind,JF.ExecutionContext())
                @test length(delivered)==(expected_mode=="all" ? 2 : 1)
                persisted=JF.load_timeline(app.archive.store,app.archive.timeline.identity.id)
                records=JF.timeline_messages(persisted)
                @test all(item->any(message->get(message,"content",nothing)==item.message.content,records),delivered)
                JF.clear_pending_inputs!(app.session;kind)
            end
            JF.timeline_append_message!(app.archive.timeline,Dict("role"=>"assistant","content"=>[Dict("type"=>"thinking","thinking"=>"VISIBLE_THOUGHT_SENTINEL")]))
            rows=T.archive_transcript_lines!(app,60);text=join(join(span.content for span in row) for row in rows)
            @test occursin("VISIBLE_THOUGHT_SENTINEL",text)==!case["hideThinking"]
            @test occursin("Thinking...",text)==case["hideThinking"]
            @test app.session.runtime.pending_inputs !== old.runtime.pending_inputs
            push!(frames,capture(app,"$(operation).$(case_index).after"))
            push!(observations,(;operation,case_index,steering=actual.steering_mode,followUp=actual.follow_up_mode,hideThinking=app.transcript.display.hide_thinking,status=app.status))
            T.finish_shutdown!(app);close(kernel)
        end
    end
    output=get(ENV,"SESSION_PREFERENCE_EVIDENCE","")
    isempty(output)||write(output,JSON.json((;snapshots=frames,observations)))
end
end
module SessionPreferenceFailureTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const JF=JuliaForever2
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
using ..SessionPreferenceLifecycleTests: drain!
function publish_candidate!(app,transition)
    handle=JF.submit_managed!(app.session,app.session,T.ui_context(app)) do context
        JF.ExecutionResult(true,transition.status,transition)
    end
    T.track_operation!(app,handle,:session_action_done,"Publishing fixture candidate")
    drain!(app)
end
@testset "Session preference rejection retains current runtime and private state" begin
    mktempdir() do directory
        kernel=JF.Kernel();app=T.App(JF.Session(kernel;working_directory=directory);settings_dir=joinpath(directory,"config"),theme_fallback="dark")
        for (name,value) in (("steering-mode","all"),("follow-up-mode","all"),("hide-thinking","true"))
            T.set_setting_value!(app,name,value)
        end
        path=joinpath(app.settings.directory,"terminal-settings.json");saved=read(path)
        old=app.session;archive=app.archive;transcript=app.transcript
        T.session_action!(app,:resume,"missing-session")
        @test drain!(app)==:ok
        @test app.session===old && app.archive===archive && app.transcript===transcript
        @test isopen(old) && read(path)==saved
        @test app.transcript.display.hide_thinking && JF.pending_input_snapshot(old).steering_mode=="all"
        closed=T.prepare_session_transition(app,Val(:new),"");close(closed.session)
        @test publish_candidate!(app,closed)==:ok
        @test app.session===old && isopen(old) && app.archive===archive
        @test occursin("closed",app.status) && !isopen(closed.session)
        @test read(path)==saved
        invalid=T.prepare_session_transition(app,Val(:new),"")
        app.menus.preferences["steering-mode"]="invalid"
        @test publish_candidate!(app,invalid)==:ok
        @test app.session===old && isopen(old) && !isopen(invalid.session)
        @test occursin("invalid",app.status)
        app.menus.preferences["steering-mode"]="all"
        # Rebind from the most recent accepted settings, not values captured by preparation.
        latest=T.prepare_session_transition(app,Val(:new),"")
        T.set_setting_value!(app,"steering-mode","one-at-a-time")
        app.transcript.display.expand_all=true;app.transcript.display.show_usage=true
        push!(app.transcript.display.expanded,"old-entry-only")
        @test publish_candidate!(app,latest)==:ok
        @test JF.pending_input_snapshot(app.session).steering_mode=="one-at-a-time"
        @test JF.pending_input_snapshot(app.session).follow_up_mode=="all"
        @test app.transcript.display.hide_thinking
        @test app.transcript.display.expand_all && app.transcript.display.show_usage
        @test isempty(app.transcript.display.expanded)
        # Denied persistence never becomes a new-session effective value.
        original=read(path);rm(path);symlink("unowned-settings",path)
        T.set_setting_value!(app,"steering-mode","all")
        @test T.menu_preference(app,"steering-mode","")=="one-at-a-time"
        T.session_action!(app,:new)
        @test drain!(app)==:ok
        @test JF.pending_input_snapshot(app.session).steering_mode=="one-at-a-time"
        @test islink(path) && !isfile(joinpath(app.settings.directory,"unowned-settings"))
        T.finish_shutdown!(app);close(kernel)
    end
end
end
