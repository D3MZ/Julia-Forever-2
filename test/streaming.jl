using JuliaForever2: CodeModePolicy, ResponseProgress, protocol_progress, emit_protocol_progress!, operation_id
using JSON

@testset "Code-mode streaming decodes only response content" begin
    policy = CodeModePolicy()
    @test isnothing(protocol_progress(policy, ""))
    @test isnothing(protocol_progress(policy, raw"""{"""))
    @test isnothing(protocol_progress(policy, raw"""{"kind":"ans"""))
    @test isnothing(protocol_progress(policy, raw"""{"content":"ready","kind":"ans"""))

    preview = protocol_progress(policy, raw"""{"kind":"answer","content":"hello""")
    @test preview.kind == :answer
    @test preview.text == "hello"
    preview = protocol_progress(policy, raw"""{"content":"ready","kind":"answer"}""")
    @test preview.kind == :answer
    @test preview.text == "ready"

    expected = "println(\"hello\")\npath = \"a\\b\"\nλ = \"你好 🚀\""
    wire = JSON.json((kind="code", content=expected))
    for count in 1:ncodeunits(wire)
        partial = String(collect(codeunits(wire)[1:count]))
        preview = protocol_progress(policy, partial)
        if !isnothing(preview)
            @test preview.kind == :code
            @test isvalid(preview.text)
            @test startswith(expected, preview.text)
        end
    end
    @test protocol_progress(policy, wire).text == expected

    expected = "quote: \"; slash: \\; line: \n; tab: \t; rocket: 🚀; lambda: λ"
    escaped = replace(JSON.json((kind="answer", content=expected)), "🚀" => raw"\uD83D\uDE80", "λ" => raw"\u03bb")
    for count in 1:ncodeunits(escaped)
        preview = protocol_progress(policy, first(escaped, count))
        if !isnothing(preview)
            @test isvalid(preview.text)
            @test startswith(expected, preview.text)
        end
    end
    @test protocol_progress(policy, escaped).text == expected
    @test protocol_progress(policy, raw"""{"kind":"answer","content":"safe\uD83D\uDE""").text == "safe"
    @test protocol_progress(policy, raw"""{"kind":"answer","content":"safe""" * "\\").text == "safe"
end

@testset "Incomplete or invalid protocol never leaks JSON" begin
    policy = CodeModePolicy()
    invalid = [
        raw"""{"kind":"tool","content":"hidden"}""",
        raw"""{"content":"hidden"}""",
        raw"""{"kind":"answer","content":42}""",
        raw"""{"kind":"answer","content":"bad\q"}""",
        raw"""{"kind":"answer","content":"bad\uD800x"}""",
        raw"""{"kind":"answer","content":"bad\uDC00"}""",
        raw"""{"kind":"answer","content":"bad\uD800\u0041"}""",
        raw"""{"kind":"answer","content":"bad\uZZZZ"}""",
        raw"""{"kind":"answer","content":"valid","content":"duplicate"}""",
        raw"""{"kind":"answer","content":"valid",}""",
        raw"""{"kind":"answer","content":"valid"} trailing""",
        "{\"kind\":\"answer\",\"content\":\"illegal\nnewline\"}",
    ]
    @test all(isnothing(protocol_progress(policy, wire)) for wire in invalid)
    @test isnothing(protocol_progress(policy, String(UInt8[0x7b, 0x22, 0xff])))
    @test isnothing(protocol_progress(:custom_protocol, "anything"))
end

@testset "Semantic progress identifies the operation and honors cancellation" begin
    events = HarnessEvent[]
    context = ExecutionContext(; event_sink=event -> push!(events, event))
    preview = emit_protocol_progress!(CodeModePolicy(), raw"""{"kind":"answer","content":"live""", context)
    @test preview.text == "live"
    @test length(events) == 1
    @test events[1].kind == :response_progress
    @test events[1].data.operation_id == operation_id(context)
    @test events[1].data.progress === preview
    cancel!(context)
    @test isnothing(emit_protocol_progress!(CodeModePolicy(), raw"""{"kind":"answer","content":"ignored""", context))
    @test length(events) == 1
    close(context)
end
