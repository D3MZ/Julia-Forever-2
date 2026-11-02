using Dates
const ResumeNative=ResumeNativeTests
resume_test_seconds(value)=datetime2unix(DateTime(chop(value;tail=1)))
resume_test_date(value)=Dates.format(unix2datetime(value),dateformat"yyyy-mm-ddTHH:MM:SS.sss")*"Z"
function resume_test_entry(row)
    ResumeNative.ResumeEntry(;id=row["id"],path=row["path"],cwd=row["cwd"],created=resume_test_seconds(row["created"]),
        modified=resume_test_seconds(row["modified"]),messages=row["messageCount"],first_message=row["firstMessage"],
        text=row["allMessagesText"],name=get(row,"name",nothing),parent=get(row,"parentSessionPath",nothing))
end
function resume_test_record(entry)
    row=Dict{String,Any}("id"=>entry.id,"path"=>entry.path,"cwd"=>entry.cwd,"created"=>resume_test_date(entry.created),
        "modified"=>resume_test_date(entry.modified),"messageCount"=>entry.messages,"firstMessage"=>entry.first_message,"allMessagesText"=>entry.text)
    isnothing(entry.name) || (row["name"]=entry.name)
    isnothing(entry.parent) || (row["parentSessionPath"]=entry.parent)
    row
end
resume_test_cache(::Nothing)=nothing
resume_test_cache(rows::AbstractVector)=resume_test_record.(rows)
"""Serialize through the production final-output text normalization, matching original TUI row normalization."""
function resume_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,ResumeNative.Owner.startup_safe_text(span.content),"\e[0m")
        end
    end for line in lines]
end
function resume_test_input(input)
    (value=input.value,cursorUtf16=length(transcode(UInt16,ResumeNative.menu_search_prefix(input))),
        cursorGrapheme=input.cursor,renderedStartColumn=input.rendered_start_column,pasting=input.pasting,pasteBuffer=input.paste_buffer)
end
function resume_test_snapshot(menu,width,callbacks,loads,timers)
    lines=ResumeNative.resume_lines(menu,width)
    status=isnothing(menu.status) ? nothing : (type=String(first(menu.status)),message=last(menu.status))
    progress=isnothing(menu.progress) ? nothing : (loaded=first(menu.progress),total=last(menu.progress))
    (mode=String(menu.mode),scope=String(menu.scope),sortMode=String(menu.sort),nameFilter=String(menu.names),
        capturesViewportInput=ResumeNative.resume_captures_viewport(menu),selectedIndex=menu.cursor-1,
        selectedPath=ResumeNative.resume_selected(menu),selectionTouched=menu.selection_touched,
        search=resume_test_input(menu.search),renameInput=resume_test_input(menu.rename_input),renameTargetPath=menu.rename_target,
        showCwd=menu.show_cwd,showPath=menu.show_path,confirmingDeletePath=menu.confirming_delete,maxVisible=menu.maximum_rows,
        rows=[(path=row.entry.path,depth=row.depth,isLast=row.last,ancestorContinues=row.ancestors) for row in menu.rows],
        currentSessions=resume_test_cache(menu.caches[:current]),allSessions=resume_test_cache(menu.caches[:all]),
        currentLoading=haskey(menu.loads,:current),allLoading=haskey(menu.loads,:all),
        header=(scope=String(menu.header_scope),sortMode=String(menu.sort),nameFilter=String(menu.names),loading=menu.loading,
            progress=progress,showPath=menu.show_path,showRenameHint=menu.show_rename,confirmingDeletePath=menu.confirming_delete,status=status),
        loads=[(id=load.id,scope=String(load.scope),settled=load.completed,aborted=load.cancelled) for load in loads],
        timerDelays=[round(Int,last(timers[id])*1000) for id in sort!(collect(keys(timers)))],
        callbackState=deepcopy(callbacks),hardwareCursor=ResumeNative.resume_hardware_cursor(menu),ansiLines=resume_test_ansi(lines))
end
function resume_test_compare(actual,expected,label,failures)
    encoded=JSON.parse(JSON.json(actual))
    for (key,value) in encoded
        if key!="ansiLines" && value!=expected[key]
            push!(failures,(case=label,field=key,actual=value,expected=expected[key]))
        end
    end
end
function resume_test_frame!(actual,expected,name,width,snapshots,expected_rows,failures)
    resume_test_compare(actual,expected,"$name@$width",failures)
    push!(snapshots,(id=name,width=width,ansiLines=actual.ansiLines))
    push!(expected_rows,(id=name,width=width,terminalAnsiLines=expected["terminalAnsiLines"]))
end
function resume_test_resume(case,environment,snapshots,expected_rows,failures)
    fixture,width,id=case["fixture"],case["width"],case["id"]
    callbacks=Dict{String,Any}("selectRequests"=>String[],"renameRequests"=>[],"cancelCount"=>0,"exitCount"=>0,"renderCount"=>0,"operationErrors"=>String[])
    events,loads,renames,deletes=[],ResumeNative.ResumeLoadRequest[],ResumeNative.ResumeMutationRequest[],ResumeNative.ResumeMutationRequest[]
    timers=Dict{Int,Any}()
    serial=Ref(0)
    schedule=(callback,delay)->(serial[]+=1;timers[serial[]]=(callback,delay);serial[])
    unschedule=timer->(isnothing(timer) || delete!(timers,timer);nothing)
    onload=(menu,request)->(push!(loads,request);push!(events,(action="load",scope=String(request.scope),id=request.id));nothing)
    select=path->(push!(callbacks["selectRequests"],path);push!(events,(action="select",path=path));:owner_result)
    cancel=()->(callbacks["cancelCount"]+=1;push!(events,(action="cancel",));:cancel_result)
    rename=(menu,request)->(push!(renames,request);push!(callbacks["renameRequests"],(path=request.path,value=request.value));push!(events,(action="rename",path=request.path,value=request.value));:pending)
    remove=(menu,request)->(push!(deletes,request);:pending)
    rows=Dict(:current=>deepcopy(fixture["currentRows"]),:all=>deepcopy(fixture["allRows"]))
    menu=ResumeNative.resume_menu(;on_load=onload,on_select=select,on_cancel=cancel,on_rename=get(fixture,"rename",true) ? rename : nothing,
        on_delete=remove,request_render=()->(callbacks["renderCount"]+=1),schedule,unschedule,
        focused=get(fixture,"focused",true),current_path=fixture["currentPath"],home=environment["home"],
        show_rename=get(fixture,"showRenameHint",get(fixture,"rename",true)),now=()->resume_test_seconds(environment["fixedTime"]),bold=get(ENV,"FORCE_COLOR","0")!="0")
    actual=resume_test_snapshot(menu,width,callbacks,loads,timers)
    resume_test_frame!(actual,case["initial"],"$id.initial",width,snapshots,expected_rows,failures)
    if JSON.parse(JSON.json(events))!=case["initialEvents"]
        push!(failures,(case="$id initial",field="initialEvents",actual=copy(events),expected=case["initialEvents"]))
    end
    empty!(events)
    for transition in case["transitions"]
        event=transition["event"]
        result=nothing
        if event["type"]=="key"
            ResumeNative.resume_input!(menu,event["data"])
        elseif event["type"]=="load"
            index=findfirst(load->!load.completed && (haskey(event,"id") ? load.id==event["id"] : load.scope==Symbol(event["scope"])),loads)
            request=loads[index]
            source=rows[request.scope]
            if event["action"]=="progress"
                entries=get(event,"partial",true) ? resume_test_entry.(source[1:min(event["loaded"],length(source))]) : nothing
                ResumeNative.resume_progress!(menu,request,event["loaded"],event["total"];entries)
            elseif event["action"]=="reject"
                ResumeNative.resume_failed!(menu,request,get(event,"error","fixture load denied"))
            else
                ResumeNative.resume_loaded!(menu,request,resume_test_entry.(source))
            end
        elseif event["type"]=="rename"
            request=first(filter(request->!request.completed,renames))
            accepted=event["action"]!="reject"
            if accepted
                for row in [rows[:current];rows[:all]]
                    row["path"]==request.path && (row["name"]=request.value)
                end
            else
                push!(callbacks["operationErrors"],"fixture rename denied")
            end
            ResumeNative.resume_mutation_complete!(menu,request;ok=accepted)
        elseif event["type"]=="settle"
            pending=filter(request->!request.completed,deletes)
            for request in pending
                blocked=endswith(request.path,"blocked-dir")
                if !blocked
                    for scope in (:current,:all)
                        filter!(row->row["path"]!=request.path,rows[scope])
                    end
                end
                error="EISDIR: illegal operation on a directory, unlink '$(request.path)' (trash: spawnSync trash ENOENT)"
                ResumeNative.resume_mutation_complete!(menu,request;ok=!blocked,error)
            end
        elseif event["type"]=="timers"
            queued=[timers[key] for key in sort!(collect(keys(timers)))]
            empty!(timers)
            for (callback,_) in queued
                callback()
            end
        elseif event["type"]=="mouse"
            result=ResumeNative.resume_mouse!(menu,get(event,"x",3),menu.input_row+get(event,"y",0);action=Symbol(event["action"]))
        end
        actual=resume_test_snapshot(menu,width,callbacks,loads,timers)
        name=string(id,".step-",transition["index"])
        resume_test_frame!(actual,transition["after"],name,width,snapshots,expected_rows,failures)
        if JSON.parse(JSON.json(events))!=transition["callbackEvents"]
            push!(failures,(case="$name@$width",field="callbackEvents",actual=copy(events),expected=transition["callbackEvents"]))
        end
        if JSON.parse(JSON.json(result))!=transition["result"]
            push!(failures,(case="$name@$width",field="mouseResult",actual=result,expected=transition["result"]))
        end
        empty!(events)
    end
    ResumeNative.resume_dispose!(menu)
end
function resume_test_fork(case,environment,snapshots,expected_rows,failures)
    fixture,width,id=case["fixture"],case["width"],case["id"]
    state=Dict{String,Any}("selectRequests"=>String[],"cancelCount"=>0)
    events,timers=[],[]
    select=id->(push!(state["selectRequests"],id);push!(events,(action="select",entryId=id));:owner_result)
    cancel=()->(state["cancelCount"]+=1;push!(events,(action="cancel",));:owner_result)
    schedule=(callback,delay)->(push!(timers,(callback,delay));nothing)
    messages=[ResumeNative.ForkMessage(;id=row["id"],text=row["text"]) for row in fixture["messages"]]
    menu=ResumeNative.fork_menu(messages;on_select=select,on_cancel=cancel,initial_selected=fixture["initialSelected"],schedule,bold=get(ENV,"FORCE_COLOR","0")!="0")
    snapshot()=(selectedIndex=menu.cursor-1,selectedId=ResumeNative.fork_selected(menu),maxVisible=menu.maximum_rows,
        callbackState=deepcopy(state),timerDelays=[round(Int,delay*1000) for (_,delay) in timers],ansiLines=resume_test_ansi(ResumeNative.fork_lines(menu,width)))
    resume_test_frame!(snapshot(),case["initial"],"$id.initial",width,snapshots,expected_rows,failures)
    for transition in case["transitions"]
        event=transition["event"]
        result=nothing
        if event["type"]=="key"
            ResumeNative.fork_input!(menu,event["data"])
        elseif event["type"]=="timers"
            queued=copy(timers)
            empty!(timers)
            for (callback,_) in queued
                callback()
            end
        else
            result=ResumeNative.fork_mouse!(menu,3,8;action=:press)
        end
        name=string(id,".step-",transition["index"])
        resume_test_frame!(snapshot(),transition["after"],name,width,snapshots,expected_rows,failures)
        if JSON.parse(JSON.json(events))!=transition["callbackEvents"]
            push!(failures,(case="$name@$width",field="callbackEvents",actual=copy(events),expected=transition["callbackEvents"]))
        end
        if result!=transition["result"]
            push!(failures,(case="$name@$width",field="mouseResult",actual=result,expected=transition["result"]))
        end
        empty!(events)
    end
    ResumeNative.fork_dispose!(menu)
end
function resume_test_replay(original,evidence)
    failures,snapshots,expected_rows=[],[],[]
    for case in original["cases"]
        runner=case["kind"]=="resume" ? resume_test_resume : resume_test_fork
        runner(case,original["environment"],snapshots,expected_rows,failures)
    end
    entries=resume_test_entry.(original["catalog"])
    for case in original["searchCases"]
        parsed=ResumeNative.resume_query(case["query"])
        matches=[(id=entry.id,ResumeNative.resume_match(entry,parsed)...) for entry in entries]
        @test JSON.parse(JSON.json(matches))==case["matches"]
        for (key,expected) in case["orders"]
            sort,names=Symbol.(split(key,'/'))
            @test [entry.id for entry in ResumeNative.resume_search(entries,case["query"],sort,names)]==expected
        end
        isnothing(parsed.pattern) || ResumeNative.resume_pattern_close!(parsed.pattern)
    end
    write(joinpath(evidence,"native.json"),JSON.json((snapshots=snapshots,)))
    write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected_rows,)))
    write(joinpath(evidence,"state-differences.json"),JSON.json((frames=length(snapshots),failures=failures)))
    for failure in first(failures,min(5,length(failures)))
        println(failure)
    end
    @test isempty(failures)
    comparator=joinpath(@__DIR__,"..","..","parity","compare_terminal_cells.mjs")
    reference,native,comparison=joinpath.(evidence,("reference.json","native.json","cell-differences.json"))
    run(`node $comparator $reference $native $comparison`)
    cells=JSON.parsefile(comparison)
    @test cells["checked"]==753 && cells["matching"]==753
    @test isempty(cells["missingFrames"]) && isempty(cells["failures"])
end
