const FooterNative=FooterNativeTests
function footer_test_model(value)
    isnothing(value) ? nothing : FooterNative.FooterModel(;id=value["id"],provider=value["provider"],reasoning=get(value,"reasoning",false),context_window=get(value,"contextWindow",nothing))
end
function footer_test_usage(value)
    FooterNative.FooterUsage(;input=value["input"],output=value["output"],cache_read=value["cacheRead"],cache_write=value["cacheWrite"],cost=value["cost"]["total"])
end
function footer_test_event(value)
    role=nothing
    usage=get(value,"usage",nothing)
    if value["type"]=="message"
        role=Symbol(value["message"]["role"])
        usage=get(value["message"],"usage",nothing)
    end
    FooterNative.FooterUsageEvent(;kind=Symbol(value["type"]),role,usage=isnothing(usage) ? nothing : footer_test_usage(usage))
end
function footer_test_snapshot(state,auto)
    context=get(state,"context",nothing)
    current=footer_test_model(get(state,"model",nothing))
    routed=get(state,"routed",nothing)
    statuses=Pair{String,String}[]
    for (key,value) in get(state,"statuses",[])
        text=haskey(value,"color") ? FooterNative.footer_native_fg(FooterNative.footer_native_style,Symbol(value["color"]),value["text"]) : value["text"]
        push!(statuses,key=>text)
    end
    FooterNative.FooterSnapshot(;cwd=get(state,"cwd","/fixture/home/work"),home=get(state,"home","/fixture/home"),
        branch=get(state,"branch",nothing),name=get(state,"name",nothing),model=current,thinking=get(state,"thinking","off"),
        routed=isnothing(routed) ? nothing : footer_test_model(routed["model"]),routed_thinking=isnothing(routed) ? nothing : get(routed,"thinkingLevel",nothing),
        context=isnothing(context) ? nothing : FooterNative.FooterContext(;percent=get(context,"percent",missing),window=get(context,"contextWindow",nothing)),
        events=FooterNative.FooterUsageEvent[footer_test_event(event) for event in get(state,"entries",[])],
        subscription=!isnothing(current) && current.provider in get(state,"subscriptions",[]),available_providers=get(state,"available",1),
        auto_compact=auto,experimental=get(state,"experimental",false),statuses)
end
function footer_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,span.content,"\e[0m")
        end
    end for line in lines]
end
function footer_test_buffer_ansi(snapshot,width,height)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,height))
    FooterNative.footer_native_draw!(buffer,1,1,width,snapshot;bold=get(ENV,"FORCE_COLOR","0")!="0")
    [sprint() do io
        for column in 1:width
            cell=buffer.content[Tachikoma.buf_index(buffer,column,row)]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style)
                print(io,Tachikoma.cell_glyph(cell),"\e[0m")
            end
        end
    end for row in 1:height]
end
function footer_test_capture!(state,auto,expected,id,width,snapshots,reference,failures)
    snapshot=footer_test_snapshot(state,auto)
    totals=FooterNative.footer_native_totals(snapshot.events)
    usage=totals.usage
    actual=Dict("input"=>usage.input,"output"=>usage.output,"cacheRead"=>usage.cache_read,"cacheWrite"=>usage.cache_write,"cost"=>usage.cost)
    if actual!=expected["usageTotals"] || totals.cache_rate!=expected["latestCacheHitRate"]
        push!(failures,(id=id,width=width,usage=actual,expected=expected["usageTotals"],cache_rate=totals.cache_rate,expected_cache=expected["latestCacheHitRate"]))
    end
    lines=FooterNative.footer_native_lines(snapshot,width;bold=get(ENV,"FORCE_COLOR","0")!="0")
    push!(snapshots,(id=id,width=width,ansiLines=footer_test_ansi(lines),bufferAnsiLines=footer_test_buffer_ansi(snapshot,width,length(lines))))
    push!(reference,(id=id,width=width,terminalAnsiLines=expected["terminalAnsiLines"]))
end
function footer_test_replay(original,evidence)
    snapshots,reference,failures=[],[],[]
    for case in original["cases"]
        state=Dict{String,Any}(deepcopy(case["fixture"]))
        auto=get(state,"auto",true)
        id,width=case["id"],case["width"]
        footer_test_capture!(state,auto,case["initial"],"$id.initial",width,snapshots,reference,failures)
        for transition in case["transitions"]
            event=transition["event"]
            if event["type"]=="append"
                push!(get!(state,"entries",[]),event["entry"])
            elseif event["type"]=="auto"
                auto=event["value"]
            elseif event["type"]=="replace"
                state=Dict{String,Any}(deepcopy(event["value"]))
            else
                key=event["type"]=="providers" ? "available" : event["type"]
                state[key]=event["value"]
            end
            if haskey(event,"context")
                state["context"]=event["context"]
            end
            footer_test_capture!(state,auto,transition["after"],string(id,".step-",transition["index"]),width,snapshots,reference,failures)
        end
    end
    for case in original["tokenCases"]
        @test FooterNative.footer_native_tokens(case["count"])==case["text"]
    end
    for case in original["cwdCases"]
        @test FooterNative.footer_native_cwd(case["cwd"],case["home"])==case["text"]
    end
    write(joinpath(evidence,"native.json"),JSON.json((snapshots=[(id=frame.id,width=frame.width,ansiLines=frame.ansiLines) for frame in snapshots],)))
    write(joinpath(evidence,"native-buffer.json"),JSON.json((snapshots=[(id=frame.id,width=frame.width,ansiLines=frame.bufferAnsiLines) for frame in snapshots],)))
    write(joinpath(evidence,"reference.json"),JSON.json((snapshots=reference,)))
    write(joinpath(evidence,"state-differences.json"),JSON.json((failures=failures,frames=length(snapshots))))
    for failure in first(failures,min(5,length(failures)))
        println(failure)
    end
    @test isempty(failures)
    comparator=joinpath(@__DIR__,"..","..","parity","compare_terminal_cells.mjs")
    expected,actual,comparison=joinpath.(evidence,("reference.json","native.json","cell-differences.json"))
    run(`node $comparator $expected $actual $comparison`)
    cells=JSON.parsefile(comparison)
    @test cells["checked"]==324 && cells["matching"]==324
    @test isempty(cells["missingFrames"]) && isempty(cells["failures"])
    actual,comparison=joinpath.(evidence,("native-buffer.json","buffer-cell-differences.json"))
    run(`node $comparator $expected $actual $comparison`)
    cells=JSON.parsefile(comparison)
    @test cells["checked"]==324 && cells["matching"]==324
    @test isempty(cells["missingFrames"]) && isempty(cells["failures"])
end
