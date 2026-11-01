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

@testset "SSE decoder constructor defaults preserve isolation and positional compatibility" begin
    events = JuliaForever2.SSEEvent[]
    sink = event -> push!(events, event)
    first = @inferred JuliaForever2.SSEDecoder(; sink)
    second = JuliaForever2.SSEDecoder(; sink)
    positional = JuliaForever2.SSEDecoder(sink)
    complete = JuliaForever2.SSEDecoder(sink, UInt8[], String[], "", "", false, true)

    @test first isa JuliaForever2.SSEDecoder{typeof(sink)}
    @test all(decoder -> isempty(decoder.line) && isempty(decoder.data) &&
        decoder.event == "" && decoder.id == "" &&
        !decoder.after_cr && decoder.first_line, (first, second, positional, complete))
    @test first.line !== second.line
    @test first.data !== second.data
    push!(first.line, 0x61)
    push!(first.data, "changed")
    @test isempty(second.line)
    @test isempty(second.data)
    @test isempty(positional.line)
    @test isempty(complete.data)

    write(second, "id: retained\ndata: keyword\n\n")
    @test length(events) == 1
    @test only(events).data == "keyword"
    @test only(events).id == "retained"
end

@testset "Incremental SSE fields preserve framing, colons, and Unicode" begin
    events = JuliaForever2.SSEEvent[]
    decoder = JuliaForever2.SSEDecoder(event -> push!(events, event))

    wire = "\ufeff: comment\r\nid: first\r\nevent: update\r\ndata: λ:one\r\ndata:two:three\r\n\r\n"
    for byte in codeunits(wire)
        write(decoder, byte)
    end
    @test length(events) == 1
    @test events[1].event == "update"
    @test events[1].data == "λ:one\ntwo:three"
    @test events[1].id == "first"

    write(decoder, "id\r\nevent\r\ndata\r\n\r\n")
    @test length(events) == 2
    @test events[2].event == "message"
    @test events[2].data == ""
    @test events[2].id == ""

    write(decoder, "id:\r\nevent:\r\ndata: \r\n\r\n")
    @test length(events) == 3
    @test events[3].data == ""
    @test events[3].id == ""
    @test events[3].event == "message"

    write(decoder, "id: invalid\0id\nż: ignored\nretry: 1000\ndata:  leading space\n\n")
    @test length(events) == 4
    @test events[4].data == " leading space"
    @test events[4].id == ""
    @test events[4].event == "message"

    write(decoder, ": comment\n\n")
    @test length(events) == 4
end

@testset "Protocol strings preserve complete UTF-8 prefixes and reject invalid sequences" begin
    policy = CodeModePolicy()
    prefix = "{\"kind\":\"answer\",\"content\":\"safe"
    suffix = "\"}"
    for character in ('\u0080', '\u07ff', '\u0800', '\ud7ff', '\ue000', '\uffff', '\U00010000', '\U0010ffff')
        bytes = collect(codeunits(string(character)))
        for count in 0:(length(bytes) - 1)
            wire = String(vcat(codeunits(prefix), bytes[1:count]))
            @test protocol_progress(policy, wire).text == "safe"
        end
        wire = prefix * string(character) * suffix
        @test protocol_progress(policy, wire).text == "safe" * string(character)
    end

    invalid_sequences = (
        UInt8[0x80],
        UInt8[0xc0, 0xaf],
        UInt8[0xc2, 0x20],
        UInt8[0xe0, 0x9f, 0xbf],
        UInt8[0xed, 0xa0, 0x80],
        UInt8[0xe2, 0x28, 0xa1],
        UInt8[0xf0, 0x8f, 0xbf, 0xbf],
        UInt8[0xf4, 0x90, 0x80, 0x80],
        UInt8[0xf5, 0x80, 0x80, 0x80],
    )
    for bytes in invalid_sequences
        wire = String(vcat(codeunits(prefix), bytes, codeunits(suffix)))
        @test isnothing(protocol_progress(policy, wire))
    end
end

@testset "UTF-8 scalar validation agrees with Julia's String validator" begin
    # Boundary values exercise overlong encodings, surrogate exclusions,
    # incomplete continuations and the maximal Unicode scalar.
    for lead in UInt8[0xc2, 0xdf, 0xe0, 0xe1, 0xed, 0xef, 0xf0, 0xf1, 0xf4],
            second in UInt8[0x00, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0],
            third in UInt8[0x7f, 0x80, 0xbf, 0xc0],
            fourth in UInt8[0x7f, 0x80, 0xbf, 0xc0]
        bytes = UInt8[lead, second, third, fourth]
        size = JuliaForever2.protocol_utf8_size(lead)
        @test JuliaForever2.protocol_utf8_valid(bytes, 1, size) ==
            isvalid(String, @view bytes[1:size])
    end
end

@testset "Protocol strings combine unchanged spans and decoded escapes" begin
    policy = CodeModePolicy()
    for expected in ("", "unchanged ASCII", "λ你好🚀", "\nleading", "trailing\t", "a\nb\tc\\d\"e", "λ\n你好\t🚀", "\0\b\f\r/\x1f")
        wire = JSON.json((kind="answer", content=expected))
        @test protocol_progress(policy, wire).text == expected
        wrapped = " " * wire * " "
        @test protocol_progress(policy, SubString(wrapped, 2, prevind(wrapped, lastindex(wrapped)))).text == expected
    end
    @test protocol_progress(policy, raw"""{"kind":"answer","content":"first\nlast\uD800""").text == "first\nlast"
    @test isnothing(protocol_progress(policy, raw"""{"kind":"answer","content":"first\nlast\q"}"""))
end


@testset "JSON-RPC fragmented notifications preserve frames and malformed-line recovery" begin
    payload = repeat("λ / 你好 / accented é / message ", 175)
    first_frame = JSON.json(Dict("jsonrpc" => "2.0", "method" => "payload/update",
        "params" => Dict("text" => payload)))
    second_frame = JSON.json(Dict("jsonrpc" => "2.0", "method" => "payload/update",
        "params" => Dict("text" => "recovered")))
    wire = first_frame * "\n" * "{not valid json}\n" * second_frame * "\n"
    bytes = collect(codeunits(wire))
    for width in (1, 7, 64, 1024, length(bytes))
        received = String[]
        peer = JuliaForever2.JsonRpcPeer(IOBuffer(), IOBuffer();
            on_notification = (method, params) -> push!(received, string(method, ": ", params["text"])))
        for offset in 1:width:length(bytes)
            JuliaForever2.feed!(peer, @view(bytes[offset:min(offset + width - 1, length(bytes))]))
        end
        JuliaForever2.drain!(peer)
        @test received == ["payload/update: " * payload, "payload/update: recovered"]
        @test isempty(peer.buffer)
        @test isopen(peer)
        JuliaForever2.feed!(peer, "{\"jsonrpc\":")
        @test !isempty(peer.buffer)
        JuliaForever2.feed!(peer, "\"2.0\",\"method\":\"payload/update\",\"params\":{\"text\":\"tail\"}}\n")
        JuliaForever2.drain!(peer)
        @test received[end] == "payload/update: tail"
        @test isempty(peer.buffer)
    end
end


function escapeallocations(policy, text)
    JuliaForever2.protocol_progress(policy, text)
    @allocated JuliaForever2.protocol_progress(policy, text)
end

@testset "Escaped previews retain bounded allocation after constructor composition" begin
    policy = JuliaForever2.CodeModePolicy()
    content = repeat("quoted \"text\"\n\tpath\\segment", 120)
    text = JSON.json((kind="answer", content))
    escapeallocations(policy, text)
    allocated = minimum(escapeallocations(policy, text) for _ in 1:3)
    println("Warmed escaped preview: ", allocated, " bytes; allocation budget <= 32768 bytes")
    @test JuliaForever2.protocol_progress(policy, text).text == content
    @test allocated <= 32768
end
