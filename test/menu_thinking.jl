using Test, JSON, JuliaForever2, Tachikoma, CommonMark

module ThinkingNativeTests
using JuliaForever2, Tachikoma, CommonMark
const Owner = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
const FIXTURE_THEME = Owner.ThemeRuntime(Owner.theme_catalog("";preserve_extras=false);setting="dark")
pi_style(style::Symbol) = Owner.theme_style(FIXTURE_THEME,style)
const menu_token_score = Owner.menu_token_score
include(joinpath(@__DIR__, "..", "ext", "terminal", "menu_search_input.jl"))
include(joinpath(@__DIR__, "..", "ext", "terminal", "menu_thinking.jl"))
end
const ThinkingNative = ThinkingNativeTests

"""Serialize real native spans without interpreting or replacing their styles."""
function thinking_test_ansi(lines)
    [sprint() do io
        for span in line
            Tachikoma.write_style(io, span.style)
            print(io, span.content)
            print(io, "\e[0m")
        end
    end for line in lines]
end

"""Capture independently native state and native-rendered ANSI rows."""
function thinking_test_snapshot(menu, width, callbacks)
    lines = ThinkingNative.thinking_lines(menu, width)
    prefix = ThinkingNative.menu_search_prefix(menu.search)
    (query=menu.search.value,
        cursor=(utf16=length(transcode(UInt16, prefix)), graphemeBoundaryIndex=menu.search.cursor,
            displayColumn=ThinkingNative.menu_search_width(prefix)),
        queryDisplayWidth=ThinkingNative.menu_search_width(menu.search.value),
        renderedStartColumn=menu.search.rendered_start_column,
        selectedIndex=menu.cursor-1, selectedValue=ThinkingNative.thinking_selected(menu),
        selectedItem=isnothing(ThinkingNative.thinking_selected(menu)) ? nothing : ThinkingNative.thinking_item(menu, ThinkingNative.thinking_selected(menu)),
        visibleItems=ThinkingNative.thinking_items(menu),
        allItems=[ThinkingNative.thinking_item(menu, level) for level in menu.levels],
        maxVisible=max(1,length(menu.filtered)), mousePressedIndex=isnothing(menu.pressed) ? nothing : menu.pressed-1,
        callbackState=deepcopy(callbacks),
        layout=(search=(y=menu.search_row,height=1),list=(y=menu.list_row,height=menu.list_height)),
        hardwareCursor=ThinkingNative.thinking_hardware_cursor(menu), ansiLines=thinking_test_ansi(lines))
end

"""Compare all state dimensions before checking the ANSI in an independent terminal engine."""
function thinking_test_check(actual, expected, label, failures)
    encoded = JSON.parse(JSON.json(actual))
    for field in keys(encoded)
        if field != "ansiLines" && encoded[field] != expected[field]
            push!(failures,(case=label,field=field,actual=encoded[field],expected=expected[field]))
        end
    end
end

"""Replay only real public input entrypoints and return normalized mouse dispatch metadata."""
function thinking_test_event!(menu, event)
    result = nothing
    if event["type"] == "key"
        ThinkingNative.thinking_input!(menu, event["data"])
    elseif event["type"] == "listKey"
        ThinkingNative.thinking_list_input!(menu, event["data"])
    else
        mouse = event["resolved"]
        outcome = ThinkingNative.thinking_mouse!(menu, mouse["x"], mouse["y"];
            action=Symbol(mouse["type"]),button=Symbol(mouse["button"]),wheel_delta=get(mouse,"wheelDelta",0))
        if !isnothing(outcome)
            result = Dict(string(key)=>value for (key,value) in pairs(outcome) if key != :request)
        end
    end
    result
end

@testset "Thinking selector: hash-checked original state transitions" begin
    reference = get(ENV,"PI_REFERENCE", "")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle = joinpath(@__DIR__,"differential","pi_thinking_oracle.mjs")
            provenance = joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            output = joinpath(directory,"original.json")
            run(`node $oracle $reference $provenance $output`)
            original = JSON.parsefile(output)
            @test original["provenance"]["checkedSourceFiles"] == 513
            for case in original["supportCases"]
                model = case["model"]
                @test ThinkingNative.supported_thinking_levels(model["reasoning"],get(model,"thinkingLevelMap",Dict{String,Any}())) == case["availableLevels"]
            end
            failures, snapshots, expected_rows = [], [], []
            for case in original["cases"]
                spec, width, id = case["fixture"], case["width"], case["id"]
                callbacks = Dict{String,Any}("selectRequests"=>String[],"defaultRequests"=>String[],"cancelCount"=>0)
                events = []
                selected = level -> (push!(callbacks["selectRequests"],level); push!(events,(action="select",level=level)); :owner_selection_result)
                cancelled = () -> (callbacks["cancelCount"]+=1; push!(events,(action="cancel",)); :owner_cancel_result)
                saved = level -> (push!(callbacks["defaultRequests"],level); push!(events,(action="save-default",level=level)); :owner_default_result)
                menu = ThinkingNative.thinking_menu(spec["current"], spec["availableLevels"];
                    on_select=selected,on_cancel=cancelled,on_default=get(spec,"saveEnabled",true) ? saved : nothing,
                    default_level=get(spec,"defaultLevel",nothing),focused=get(spec,"focused",false))
                actual = thinking_test_snapshot(menu,width,callbacks)
                thinking_test_check(actual,case["initial"],"$id@$width initial",failures)
                push!(snapshots,(id="$id.initial",width=width,ansiLines=actual.ansiLines))
                push!(expected_rows,(id="$id.initial",width=width,terminalAnsiLines=case["initial"]["terminalAnsiLines"]))
                for transition in case["transitions"]
                    result = thinking_test_event!(menu,transition["event"])
                    actual = thinking_test_snapshot(menu,width,callbacks)
                    label = string(id,".step-",transition["index"])
                    thinking_test_check(actual,transition["after"],"$label@$width",failures)
                    if result != transition["result"]
                        push!(failures,(case="$label@$width",field="mouseResult",actual=result,expected=transition["result"]))
                    end
                    if JSON.parse(JSON.json(events)) != transition["callbackEvents"]
                        push!(failures,(case="$label@$width",field="callbackEvents",actual=copy(events),expected=transition["callbackEvents"]))
                    end
                    empty!(events)
                    push!(snapshots,(id=label,width=width,ansiLines=actual.ansiLines))
                    push!(expected_rows,(id=label,width=width,terminalAnsiLines=transition["after"]["terminalAnsiLines"]))
                end
            end
            evidence = get(ENV,"THINKING_EVIDENCE_DIR",directory)
            mkpath(evidence)
            write(joinpath(evidence,"native.json"),JSON.json((snapshots=snapshots,)))
            write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected_rows,)))
            write(joinpath(evidence,"state-differences.json"),JSON.json((cases=length(original["cases"]),frames=length(snapshots),failures=failures)))
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            for failure in first(failures,min(12,length(failures)))
                println(failure)
            end
            @test isempty(failures)
            @test length(snapshots) == 1705
            comparator = joinpath(dirname(dirname(pathof(JuliaForever2))), "parity", "compare_terminal_cells.mjs")
            @test isfile(comparator)
            if isfile(comparator)
                expected_path = joinpath(evidence, "reference.json")
                native_path = joinpath(evidence, "native.json")
                cells_path = joinpath(evidence, "cell-differences.json")
                run(`node $comparator $expected_path $native_path $cells_path`)
                cells = JSON.parsefile(cells_path)
                @test cells["checked"] == 1705 && cells["matching"] == 1705
                @test isempty(cells["missingFrames"]) && isempty(cells["failures"])
            end
        end
    end
end

@testset "Thinking selector callback outcomes and empty capabilities" begin
    menu = ThinkingNative.thinking_menu("medium",["off","medium","high"];
        on_select=level -> (accepted=false,reason="owner denied",level=level),on_cancel=()->:closed,
        on_default=level -> (persisted=false,error="read-only",level=level),default_level="high")
    selection = ThinkingNative.thinking_input!(menu,"\r")
    @test selection.invoked
    @test !selection.outcome.accepted
    @test selection.outcome.reason == "owner denied"
    saved = ThinkingNative.thinking_input!(menu,"\x13")
    @test saved.invoked
    @test !saved.outcome.persisted
    @test menu.current == "medium" && menu.default_level == "high"
    @test ThinkingNative.thinking_input!(menu,"\e").outcome == :closed
    @test ThinkingNative.supported_thinking_levels(false,Dict("off"=>nothing)) == ["off"]
    @test ThinkingNative.supported_thinking_levels(true,Dict(level=>nothing for level in ThinkingNative.THINKING_MENU_LEVELS)) == String[]
    @test ThinkingNative.supported_thinking_levels(true,Dict(:xhigh=>"high",:max=>"max",:low=>nothing)) == ["off","minimal","medium","high","xhigh","max"]
end
