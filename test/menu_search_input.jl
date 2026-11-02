using Test, JSON, Tachikoma

module MenuSearchNativeTests
using Tachikoma
include(joinpath(@__DIR__, "..", "ext", "terminal", "menu_search_input.jl"))
end
const SearchNative = MenuSearchNativeTests

"""Capture public native state plus its real ANSI search row for the differential."""
function search_native_snapshot(input, width)
    runs = SearchNative.menu_search_render!(input, width)
    prefix = SearchNative.menu_search_prefix(input)
    (value=input.value, cursor=input.cursor, utf16=length(transcode(UInt16, prefix)),
        displayColumn=SearchNative.menu_search_width(prefix), displayWidth=SearchNative.menu_search_width(input.value),
        renderedStartColumn=input.rendered_start_column, pasting=input.pasting, pasteBuffer=input.paste_buffer,
        ansi=SearchNative.menu_search_ansi(runs))
end

"""Replay one source fixture event using only public native input APIs."""
function search_native_event!(input, event)
    if event["type"] == "key"
        SearchNative.menu_search_input!(input, event["data"])
    elseif event["type"] == "setValue"
        SearchNative.menu_search_set!(input, event["value"])
        :handled
    else
        mouse = event["mouse"]
        SearchNative.menu_search_click!(input, mouse["x"], mouse["y"]; button=Symbol(mouse["button"]), action=Symbol(mouse["type"]))
    end
end

"""Check grapheme state and ANSI independently of the terminal-cell normalization."""
function check_search_snapshot(actual, expected, label, failures)
    pairs = (("value", actual.value, expected["value"]),
        ("cursor", actual.cursor, expected["cursor"]["graphemeBoundaryIndex"]),
        ("utf16", actual.utf16, expected["cursor"]["utf16"]),
        ("displayColumn", actual.displayColumn, expected["cursor"]["displayColumn"]),
        ("displayWidth", actual.displayWidth, expected["displayWidth"]),
        ("renderedStartColumn", actual.renderedStartColumn, expected["renderedStartColumn"]),
        ("pasting", actual.pasting, expected["paste"]["active"]),
        ("pasteBuffer", actual.pasteBuffer, expected["paste"]["buffer"]),
        ("ansi", replace(actual.ansi, "\e[0m" => ""), replace(expected["terminalAnsiLines"][1], "\e[0m" => "")))
    for (field, value, original) in pairs
        if value != original
            push!(failures, (case=label, field=field, actual=value, expected=original))
        end
    end
end

@testset "Native search: original-source transitions and rendered rows" begin
    reference = get(ENV, "PI_REFERENCE", "")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle = joinpath(@__DIR__, "differential", "pi_menu_search_oracle.mjs")
            provenance = joinpath(@__DIR__, "fixtures", "pi-menu-search-provenance.json")
            prior = joinpath(@__DIR__, "fixtures", "pi-menu-search-settings.json")
            output = joinpath(directory, "original.json")
            run(`node $oracle $reference $provenance $output $prior`)
            original = JSON.parsefile(output)
            @test original["validation"]["sourceHashAssertions"] == 513
            @test original["validation"]["freshlyReproducedSettingsFrames"] == 50
            for fixture in original["widthCases"]
                @test SearchNative.menu_search_width(fixture["value"]) == fixture["width"]
            end
            failures = []
            snapshots = []
            expected_rows = []
            for case in original["standaloneCases"]
                input = SearchNative.MenuSearchInput()
                width, id = case["width"], case["id"]
                initial = search_native_snapshot(input, width)
                check_search_snapshot(initial, case["initial"], "$id@$width initial", failures)
                for transition in case["transitions"]
                    action = search_native_event!(input, transition["event"])
                    actual = search_native_snapshot(input, width)
                    label = string(id, ".step-", transition["index"])
                    check_search_snapshot(actual, transition["after"], "$label@$width", failures)
                    callbacks = transition["callbackEvents"]
                    expected_action = isempty(callbacks) ? nothing : Symbol(last(callbacks)["action"])
                    if !isnothing(expected_action) && action != expected_action
                        push!(failures, (case="$label@$width", field="callback", actual=action, expected=expected_action))
                    end
                    if transition["event"]["type"] == "mouse"
                        expected_handled = !isnothing(transition["result"]) && get(transition["result"], "handled", false)
                        if action != expected_handled
                            push!(failures, (case="$label@$width", field="mouseHandled", actual=action, expected=expected_handled))
                        end
                    end
                    if width > 0
                        push!(snapshots, (id=label, width=width, ansiLines=[actual.ansi]))
                        push!(expected_rows, (id=label, width=width, terminalAnsiLines=transition["after"]["terminalAnsiLines"]))
                    end
                end
            end
            evidence = get(ENV, "MENU_SEARCH_EVIDENCE_DIR", directory)
            mkpath(evidence)
            write(joinpath(evidence, "native.json"), JSON.json((snapshots=snapshots,)))
            write(joinpath(evidence, "reference.json"), JSON.json((snapshots=expected_rows,)))
            write(joinpath(evidence, "state-differences.json"), JSON.json((cases=length(original["standaloneCases"]), transitions=original["summary"]["transitions"], failures=failures)))
            cp(output, joinpath(evidence, "original-fresh.json"); force=true)
            for failure in first(failures, min(12, length(failures)))
                println(failure)
            end
            @test isempty(failures)
            @test length(original["standaloneCases"]) == 230
            @test original["summary"]["transitions"] == 1245
        end
    end
end

@testset "Native search buffer and decoded-key adapters" begin
    input = SearchNative.MenuSearchInput()
    for character in "A界👩‍💻éZ"
        SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(character))
    end
    @test input.value == "A界👩‍💻éZ"
    @test input.cursor == 5
    @test SearchNative.menu_search_input!(input, Tachikoma.KeyEvent('x', Tachikoma.key_release)) == :ignored
    @test input.value == "A界👩‍💻éZ"
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:left))
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:backspace))
    @test input.value == "A界👩‍💻Z"
    @test input.cursor == 3
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:home))
    @test input.cursor == 0
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:end_key))
    @test input.cursor == 4
    buffer = Tachikoma.Buffer(Tachikoma.Rect(1, 1, 20, 1))
    SearchNative.menu_search_draw!(buffer, 1, 1, 20, input)
    @test Tachikoma.cell_glyph(buffer.content[4]) == "界"
    @test buffer.content[5].char == '\0'
    @test Tachikoma.cell_glyph(buffer.content[6]) == "👩‍💻"
    @test buffer.content[7].char == '\0'
    @test buffer.content[8].char == 'Z'
    @test buffer.content[9].style.fg isa SearchNative.MenuSearchInverseColor
    @test SearchNative.menu_search_width("界👩‍💻é🇺🇸1️⃣☀️") == 11
    @test length(SearchNative.menu_search_spans(input, 20)) == 3
    @test SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:unknown), collect(codeunits("\e[200~x\n"))) == :handled
    @test input.pasting
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:enter), UInt8[0x0d])
    @test input.pasting
    SearchNative.menu_search_input!(input, Tachikoma.KeyEvent(:unknown), collect(codeunits("\e[201~")))
    @test input.value == "A界👩‍💻Zx"
    Tachikoma.clear!(input)
    @test Tachikoma.text(input) == ""
    @test !input.pasting
end
