"""Wrap printable ASCII by byte offsets; Unicode and control characters keep the grapheme path."""
function wrap_printable_ascii_line(line::Union{String,SubString{String}}, width::Int)
    stop = ncodeunits(line)
    lines = stop == 0 ? [""] : String[]
    offset = 1
    capacity = max(1, width)
    while offset <= stop
        endpoint = offset + min(capacity, stop - offset + 1) - 1
        boundary = endpoint + 1
        if endpoint < stop
            space_boundary = offset
            for index in offset:endpoint
                codeunit(line, index) == 0x20 && (space_boundary = index + 1)
            end
            offset < space_boundary < boundary && (boundary = space_boundary)
        end
        push!(lines, String(SubString(line, offset, boundary - 1)))
        offset = boundary
    end
    return lines
end

printable_ascii(::AbstractString) = false
printable_ascii(line::Union{String,SubString{String}}) = all(byte -> 0x20 <= byte <= 0x7e, codeunits(line))

wrap_conversation_line(line::AbstractString, width::Int) = wrapgraphemes(line, width)
wrap_conversation_line(line::Union{String,SubString{String}}, width::Int) = printable_ascii(line) ? wrap_printable_ascii_line(line, width) : wrapgraphemes(line, width)

function wrapgraphemes(line::AbstractString, width)
    graphemes = Base.Unicode.graphemes(line)
    current = iterate(graphemes)
    lines = isnothing(current) ? [""] : String[]
    first = firstindex(line)
    while !isnothing(current)
        next, current = boundary(graphemes, current, first, width)
        push!(lines, String(SubString(line, first, prevind(line, next))))
        first = next
    end
    lines
end

function boundary(graphemes, current, first, width)
    next = first
    space = first
    afterspace = current
    columns = 0
    full = false
    while !isnothing(current) && !full
        grapheme, state = current
        size = textwidth(grapheme)
        full = columns + size > width
        if full
            if next == first
                next += ncodeunits(grapheme)
                current = iterate(graphemes, state)
            end
        else
            columns += size
            next += ncodeunits(grapheme)
            current = iterate(graphemes, state)
            if all(isspace, grapheme)
                space, afterspace = next, current
            end
        end
    end
    !isnothing(current) && first < space < next ? (space, afterspace) : (next, current)
end
"""Wrap printable ASCII spans by byte ranges; retain grapheme-aware fallback for all other text."""
function wrap_markdown_spans(spans::Vector{Tachikoma.Span}, width::Int)
    lines = Vector{Tachikoma.Span}[]
    line = Tachikoma.Span[]
    columns = 0
    for span in spans
        content = span.content
        if printable_ascii(content)
            # Printable ASCII graphemes each occupy one byte and one column.
            # Preserve boundaries and styles when a span crosses display lines.
            index = 1
            stop = ncodeunits(content)
            while index <= stop
                if columns > 0 && columns >= width
                    push!(lines, line)
                    line = Tachikoma.Span[]
                    columns = 0
                end
                count = min(stop - index + 1, max(1, width - columns))
                push!(line, Tachikoma.Span(String(SubString(content, index, index + count - 1)), span.style))
                columns += count
                index += count
            end
        else
            text = IOBuffer()
            for grapheme in Base.Unicode.graphemes(content)
                size = textwidth(grapheme)
                if columns + size > width && columns > 0
                    position(text) > 0 && push!(line, Tachikoma.Span(String(take!(text)), span.style))
                    push!(lines, line)
                    line = Tachikoma.Span[]
                    columns = 0
                end
                print(text, grapheme)
                columns += size
            end
            position(text) > 0 && push!(line, Tachikoma.Span(String(take!(text)), span.style))
        end
    end
    push!(lines, line)
    return lines
end

function markdown_lines(content::AbstractString, width::Int)
    heading = Tachikoma.Style(; fg=Tachikoma.ColorRGB(205, 154, 34), bold=true)
    bold = Tachikoma.Style(; fg=pi_style(:text).fg, bold=true)
    emph = Tachikoma.Style(; fg=pi_style(:text).fg, italic=true)
    code = Tachikoma.Style(; fg=Tachikoma.ColorRGB(104, 183, 141))
    link = Tachikoma.Style(; fg=Tachikoma.ColorRGB(105, 173, 208), underline=true)
    spans = Tachikoma.markdown_to_spans(content, width; h1_style=heading, h2_style=heading, h3_style=heading,
        bold_style=bold, emph_style=emph, code_style=code, link_style=link,
        quote_style=pi_style(:text_dim), text_style=pi_style(:text), hr_style=pi_style(:text_dim))
    return [wrapped for line in spans for wrapped in wrap_markdown_spans(line, width)]
end

function message_layout_key(messages, index)
    message = messages[index]
    code = message.role == :assistant && message.kind == :code
    paired = code && index < length(messages) && messages[index + 1].role == :code_result
    continuation = message.role == :code_result && index > 1 && messages[index - 1].kind == :code
    return message, paired, continuation
end

function message_lines(messages, index, width)
    message, paired, continuation = message_layout_key(messages, index)
    code = message.role == :assistant && message.kind == :code
    style = message.role == :user ? :user_message : (message.role == :code_result || code) ? :code_result : :text
    lines = TranscriptLine[]
    style in (:user_message, :code_result) && !continuation && push!(lines, ("", style))
    if message.role == :assistant && !code
        append!(lines, ((line, :markdown) for line in markdown_lines(message.content, max(1, width - 2))))
    else
        for line in split(message.content, '\n'; keepempty=true)
            append!(lines, ((chunk, style) for chunk in wrap_conversation_line(line, max(1, width - 2))))
        end
    end
    style in (:user_message, :code_result) && push!(lines, ("", style))
    paired || push!(lines, ("", :text))
    return lines
end

function conversation_lines(messages, width)
    lines = TranscriptLine[]
    for index in eachindex(messages)
        append!(lines, message_lines(messages, index, width))
    end
    return lines
end

struct TranscriptLayout{M}
    messages::M
    revision::UInt
    width::Int
    first::Int
    resized::Bool
end

function TranscriptLayout(transcript::TranscriptState, snapshot, width::Int)
    resized = transcript.width != width
    messages = isnothing(snapshot) ? transcript.messages : snapshot.messages
    revision = isnothing(snapshot) ? transcript.revision : snapshot.revision
    first = resized ? 1 : max(1, min(snapshot.changed_from, length(messages) + 1) - 1)
    TranscriptLayout(messages, revision, width, min(first, length(transcript.chunks) + 1), resized)
end

function transcript_lines!(app::App, width::Int)
    snapshot = history_snapshot(app.session, app.transcript.revision)
    if !isnothing(snapshot) || app.transcript.width != width
        layout!(app.transcript, TranscriptLayout(app.transcript, snapshot, width))
    end
    app.transcript.lines
end

function layout!(transcript::TranscriptState, layout::TranscriptLayout)
    prefix = layout.first - 1
    resize!(transcript.lines, prefix == 0 ? 0 : transcript.offsets[prefix])
    count = length(transcript.chunks)
    for index in layout.first:length(layout.messages)
        reusable = !layout.resized && index <= length(transcript.messages) && index <= count && message_layout_key(transcript.messages, index) == message_layout_key(layout.messages, index)
        lines = reusable ? transcript.chunks[index] : message_lines(layout.messages, index, layout.width)
        append!(transcript.lines, lines)
        if index <= count
            transcript.chunks[index] = lines
            transcript.offsets[index] = length(transcript.lines)
        else
            push!(transcript.chunks, lines)
            push!(transcript.offsets, length(transcript.lines))
        end
    end
    resize!(transcript.chunks, length(layout.messages))
    resize!(transcript.offsets, length(layout.messages))
    transcript.width = layout.width
    transcript.messages = layout.messages
    transcript.revision = layout.revision
    transcript.lines
end
"""Discard transient output without changing committed conversation history."""
function clear_preview!(app::App)
    transcript = app.transcript
    transcript.preview = nothing
    transcript.preview_operation_id = UInt64(0)
    transcript.preview_dirty = false
    empty!(transcript.preview_lines)
    return nothing
end

function active_operation(app::App, identity::UInt64)
    handle = app.operations.active
    return !app.operations.closing[] && !isnothing(handle) &&
        operation_id(handle.context) == identity && !cancelled(handle.context)
end

response_progress_received!(app::App, value) = nothing

function response_progress_received!(app::App, value::NamedTuple{(:operation_id, :progress),Tuple{UInt64,ResponseProgress}})
    if active_operation(app, value.operation_id) && value.progress.kind in (:answer, :code)
        preview!(app.transcript, value.progress, value.operation_id)
    end
    nothing
end

function preview!(transcript::TranscriptState, progress::ResponseProgress, id::UInt64)
    previous = transcript.preview
    if isnothing(previous) || previous.kind != progress.kind || previous.text != progress.text
        transcript.preview = progress
        transcript.preview_operation_id = id
        transcript.preview_dirty = true
    end
    nothing
end
response_committed!(app::App, value) = nothing

function response_committed!(app::App, value::NamedTuple{(:operation_id,),Tuple{UInt64}})
    if value.operation_id == app.transcript.preview_operation_id
        clear_preview!(app)
    end
    return nothing
end

"""Lay out the active response separately so completion cannot append it twice."""
function preview_lines!(app::App, width::Int)
    transcript = app.transcript
    progress = transcript.preview
    if !isnothing(progress) && !active_operation(app, transcript.preview_operation_id)
        clear_preview!(app)
        progress = nothing
    end
    if !isnothing(progress) && (transcript.preview_dirty || transcript.preview_width != width)
        messages = Message[Message(:assistant, progress.text, progress.kind)]
        empty!(transcript.preview_lines)
        append!(transcript.preview_lines, message_lines(messages, 1, width))
        transcript.preview_width = width
        transcript.preview_dirty = false
    end
    return transcript.preview_lines
end
