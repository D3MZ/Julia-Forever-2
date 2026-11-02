using Test, JSON, SHA, JuliaForever2, Tachikoma, CommonMark
ENV["TZ"] = "UTC"

module TreeNativeTests
using JSON, JuliaForever2, Tachikoma, CommonMark
const Owner = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const pi_style = Owner.pi_style
const menu_token_score = Owner.menu_token_score
include(joinpath(@__DIR__, "..", "ext", "terminal", "menu_search_input.jl"))
include(joinpath(@__DIR__, "..", "ext", "terminal", "menu_thinking.jl"))
const source = joinpath(@__DIR__, "..", "ext", "terminal", "menu_tree.jl")
if isfile(source)
    include(source)
end
end

@testset "Tree selector ownership and lifecycle" begin
    node = Dict{String,Any}("entry"=>Dict{String,Any}("id"=>"root","parentId"=>nothing,"type"=>"message",
        "message"=>Dict("role"=>"user","content"=>"original full text")),"children"=>Any[],"label"=>"before")
    untouched = deepcopy(node)
    callbacks = []
    menu = TreeNativeTests.tree_menu([node],"root";
        on_select=id->(accepted=false,id=id),on_cancel=()->:closed,
        on_label=(id,value)->(persisted=false,id=id,value=value),on_copy=text->(copied=false,text=text),
        now=()->"2026-11-01T12:34:56.000Z",schedule=(callback,delay)->push!(callbacks,callback))
    request = TreeNativeTests.tree_input!(menu,"\r")
    @test request.invoked && !request.outcome.accepted && request.entry_id=="root"
    @test TreeNativeTests.tree_selected(menu)=="root"
    @test !TreeNativeTests.tree_input!(menu,"\x18").outcome.copied
    TreeNativeTests.tree_input!(menu,"L")
    @test !TreeNativeTests.tree_captures_viewport(menu)
    TreeNativeTests.tree_input!(menu,"\x05")
    TreeNativeTests.tree_input!(menu,"\x15")
    TreeNativeTests.tree_input!(menu," new ")
    label = TreeNativeTests.tree_input!(menu,"\r")
    @test label.invoked && !label.outcome.persisted && label.value=="new"
    @test menu.entries[1].label=="new"
    @test node==untouched
    @test TreeNativeTests.tree_captures_viewport(menu)
    @test TreeNativeTests.tree_mouse!(menu,2,3;action=:click)===nothing
    @test TreeNativeTests.tree_input!(menu,"\e").outcome==:closed
    @test isempty(callbacks)
    empty_menu = TreeNativeTests.tree_menu(Any[],nothing;on_select=identity,on_cancel=()->push!(callbacks,:cancelled),
        schedule=(callback,delay)->push!(callbacks,(callback,delay)))
    scheduled = only(callbacks)
    @test last(scheduled)==0.1
    TreeNativeTests.tree_dispose!(empty_menu)
    first(scheduled)()
    @test length(callbacks)==1
    @test TreeNativeTests.tree_timestamp(0)=="1970-01-01T00:00:00.000Z"
    @test TreeNativeTests.tree_timestamp(-0.001)=="1969-12-31T23:59:59.999Z"
    @test occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$",TreeNativeTests.tree_timestamp())
    menu.entries[1].record["message"] = Dict("role"=>"user","content"=>"A界👩‍💻éZ")
    menu.entries[1].label = nothing
    lines = TreeNativeTests.tree_lines(menu,60)
    buffer = Tachikoma.Buffer(Tachikoma.Rect(1,1,60,length(lines)))
    TreeNativeTests.tree_draw!(buffer,1,1,60,menu)
    glyphs = Tachikoma.cell_glyph.(buffer.content)
    wide = findfirst(==("界"),glyphs)
    joined = findfirst(==("👩‍💻"),glyphs)
    @test !isnothing(wide) && !isnothing(joined)
    @test buffer.content[wide+1].char=='\0'
    @test buffer.content[joined+1].char=='\0'
    @test glyphs[joined+2]=="é" && glyphs[joined+3]=="Z"
end

const TreeNative = TreeNativeTests

"""Serialize real native styles, retaining inverse-video search cursors."""
function tree_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io,span.style)
            print(io,span.content,"\e[0m")
        end
    end for line in lines]
end

"""Project actual native state, never oracle after-values or rendered text."""
function tree_test_snapshot(menu,width,callbacks)
    lines = TreeNative.tree_lines(menu,width)
    input = menu.editing == 0 ? nothing : (entryId=menu.entries[menu.editing].id,value=menu.input.value,
        cursorUtf16=length(transcode(UInt16,TreeNative.menu_search_prefix(menu.input))),renderedStartColumn=menu.input.rendered_start_column)
    filtered = map(menu.visible) do index
        geometry = menu.geometry[index]
        (id=menu.entries[index].id,indent=geometry.depth,showConnector=geometry.connector,isLast=geometry.last,
            gutters=[(position=first(pair),show=last(pair)) for pair in geometry.gutters],isVirtualRootChild=geometry.virtual_root)
    end
    (selectedIndex=menu.cursor-1,selectedId=TreeNative.tree_selected(menu),query=menu.query,filter=menu.filter,
        lastSelectedId=menu.remembered,foldedIds=[menu.entries[index].id for index in menu.folded],
        activePathIds=[menu.entries[index].id for index in menu.active],maxVisibleLines=menu.maximum_rows,
        showLabelTimestamps=menu.label_times,multipleRoots=menu.multiple_roots,capturesViewportInput=TreeNative.tree_captures_viewport(menu),
        filtered=filtered,labels=[(id=menu.entries[index].id,label=menu.entries[index].label,timestamp=menu.entries[index].label_time) for index in menu.order],
        labelInput=input,callbackState=deepcopy(callbacks),hardwareCursor=TreeNative.tree_hardware_cursor(menu),ansiLines=tree_test_ansi(lines))
end

function tree_test_compare(actual,expected,label,failures)
    encoded = JSON.parse(JSON.json(actual))
    for field in keys(encoded)
        if field != "ansiLines" && encoded[field] != expected[field]
            push!(failures,(case=label,field=field,actual=encoded[field],expected=expected[field]))
        end
    end
end

function tree_test_replay(original,evidence)
    failures,snapshots,expected_rows = [],[],[]
    environment = original["environment"]
    for case in original["cases"]
        fixture,width,id = case["fixture"],case["width"],case["id"]
        callbacks = Dict{String,Any}("selectRequests"=>String[],"labelRequests"=>[],"copyRequests"=>[],"cancelCount"=>0)
        events,timers = [],[]
        select = entryId -> (push!(callbacks["selectRequests"],entryId);push!(events,(action="select",entryId=entryId));:selected_by_owner)
        cancel = () -> (callbacks["cancelCount"]+=1;push!(events,(action="cancel",));:cancelled_by_owner)
        label = (entryId,value) -> (push!(callbacks["labelRequests"],(entryId=entryId,label=value));push!(events,(action="label",entryId=entryId,label=value));:label_owner_result)
        copy_text = value -> (push!(callbacks["copyRequests"],value);push!(events,(action="copy",text=value));:clipboard_owner_result)
        schedule = (callback,delay) -> (push!(timers,(callback,delay));nothing)
        menu = TreeNative.tree_menu(original["fixtures"][fixture["tree"]],get(fixture,"currentLeaf",nothing);
            on_select=select,on_cancel=cancel,on_label=get(fixture,"labelCallback",true) ? label : nothing,on_copy=copy_text,
            height=fixture["height"],initial_selected=get(fixture,"initialSelected",nothing),filter=get(fixture,"filter","default"),
            focused=get(fixture,"focused",false),now=()->environment["fixedTime"],schedule,home=environment["home"],
            bold=get(ENV,"FORCE_COLOR","0")!="0")
        actual = tree_test_snapshot(menu,width,callbacks)
        tree_test_compare(actual,case["initial"],"$id@$width initial",failures)
        push!(snapshots,(id="$id.initial",width=width,ansiLines=actual.ansiLines))
        push!(expected_rows,(id="$id.initial",width=width,terminalAnsiLines=case["initial"]["terminalAnsiLines"]))
        for transition in case["transitions"]
            event = transition["event"]
            result = nothing
            if event["type"]=="key"
                TreeNative.tree_input!(menu,event["data"])
            elseif event["type"]=="updateLabel"
                TreeNative.tree_update_label!(menu,event["entryId"],get(event,"label",nothing);timestamp=get(event,"timestamp",nothing))
            elseif event["type"]=="fireTimers"
                for (callback,_) in timers
                    callback()
                end
                empty!(timers)
            elseif event["type"]=="mouse"
                result = TreeNative.tree_mouse!(menu,3,8;action=Symbol(event["action"]))
            end
            actual = tree_test_snapshot(menu,width,callbacks)
            name = string(id,".step-",transition["index"])
            tree_test_compare(actual,transition["after"],"$name@$width",failures)
            if JSON.parse(JSON.json(events)) != transition["callbackEvents"]
                push!(failures,(case="$name@$width",field="callbackEvents",actual=copy(events),expected=transition["callbackEvents"]))
            end
            if result != transition["result"]
                push!(failures,(case="$name@$width",field="mouseResult",actual=result,expected=transition["result"]))
            end
            empty!(events)
            push!(snapshots,(id=name,width=width,ansiLines=actual.ansiLines))
            push!(expected_rows,(id=name,width=width,terminalAnsiLines=transition["after"]["terminalAnsiLines"]))
        end
        if [round(Int,delay*1000) for (_,delay) in timers] != case["pendingTimerDelays"]
            push!(failures,(case="$id@$width",field="pendingTimerDelays"))
        end
        TreeNative.tree_dispose!(menu)
    end
    write(joinpath(evidence,"native.json"),JSON.json((snapshots=snapshots,)))
    write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected_rows,)))
    write(joinpath(evidence,"state-differences.json"),JSON.json((frames=length(snapshots),failures=failures)))
    for failure in first(failures,min(10,length(failures)))
        println(failure)
    end
    @test isempty(failures)
    comparator = joinpath(@__DIR__,"..","parity","compare_terminal_cells.mjs")
    reference,native,comparison = joinpath.(evidence,("reference.json","native.json","cell-differences.json"))
    run(`node $comparator $reference $native $comparison`)
    cells = JSON.parsefile(comparison)
    @test cells["checked"] == 825 && cells["matching"] == 825
    @test isempty(cells["missingFrames"]) && isempty(cells["failures"])
end

@testset "Tree selector: original-source-checked differential contract" begin
    reference = get(ENV, "PI_REFERENCE", "")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle = joinpath(@__DIR__, "differential", "pi_tree_oracle.mjs")
            provenance = joinpath(@__DIR__, "fixtures", "pi-menu-search-provenance.json")
            output = joinpath(directory, "original.json")
            run(`node $oracle $reference $provenance $output`)
            original = JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"] == 513
            @test original["counts"]["frames"] == 825
            @test first(original["cases"])["initial"]["selectedId"] == "leaf"
            @test !isempty(first(original["cases"])["initial"]["filtered"])
            evidence = get(ENV, "TREE_EVIDENCE_DIR", directory)
            mkpath(evidence)
            cp(output, joinpath(evidence, "original-fresh.json"); force=true)
            implemented = isdefined(TreeNativeTests, :tree_menu)
            write(joinpath(evidence, "baseline.json"), JSON.json((nativeTreeSelector=implemented,
                originalFrames=original["counts"]["frames"], originalInitialSelected="leaf",
                missing=implemented ? String[] : ["tree_menu", "tree_lines", "tree_input!", "tree_selected"])))
            @test implemented
            if implemented
                tree_test_replay(original,evidence)
            end
        end
    end
end
