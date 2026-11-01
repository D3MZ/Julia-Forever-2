"""Wrap printable ASCII by byte offsets; Unicode and control characters keep the grapheme path."""
function wrap_printable_ascii_line(line::Union{String,SubString{String}}, width::Int)
    stop = ncodeunits(line)
    stop == 0 && return [""]
    lines = String[]
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

function wrap_conversation_line(line::AbstractString, width::Int)
    if line isa Union{String,SubString{String}} &&
            all(byte -> 0x20 <= byte <= 0x7e, codeunits(line))
        return wrap_printable_ascii_line(line, width)
    end
    graphemes = Base.Unicode.graphemes(line)
    current = iterate(graphemes)
    isnothing(current) && return [""]
    lines = String[]
    first_index = firstindex(line)
    while !isnothing(current)
        next_index = first_index
        last_space = first_index
        after_space = current
        columns = 0
        while !isnothing(current)
            grapheme, state = current
            size = textwidth(grapheme)
            if columns + size > width
                if next_index == first_index
                    next_index += ncodeunits(grapheme)
                    current = iterate(graphemes, state)
                end
                break
            end
            columns += size
            next_index += ncodeunits(grapheme)
            current = iterate(graphemes, state)
            if all(isspace, grapheme)
                last_space = next_index
                after_space = current
            end
        end
        if !isnothing(current) && first_index < last_space < next_index
            next_index = last_space
            current = after_space
        end
        push!(lines, String(SubString(line, first_index, prevind(line, next_index))))
        first_index = next_index
    end
    return lines
end

function wrap_markdown_spans(spans::Vector{Tachikoma.Span}, width::Int)
    lines = Vector{Tachikoma.Span}[]
    line = Tachikoma.Span[]
    columns = 0
    for span in spans
        text = IOBuffer()
        for grapheme in Base.Unicode.graphemes(span.content)
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

function transcript_lines!(app::App, width::Int)
    snapshot = history_snapshot(app.session, app.transcript.revision)
    width_changed = app.transcript.width != width
    isnothing(snapshot) && !width_changed && return app.transcript.lines
    previous_messages = app.transcript.messages
    messages = isnothing(snapshot) ? previous_messages : snapshot.messages
    first_changed = width_changed ? 1 : max(1, min(snapshot.changed_from, length(messages) + 1) - 1)
    first_changed = min(first_changed, length(app.transcript.chunks) + 1)
    prefix = first_changed - 1
    resize!(app.transcript.lines, prefix == 0 ? 0 : app.transcript.offsets[prefix])
    previous_count = length(app.transcript.chunks)
    for index in first_changed:length(messages)
        reusable = !width_changed && index <= length(previous_messages) && index <= previous_count && message_layout_key(previous_messages, index) == message_layout_key(messages, index)
        lines = reusable ? app.transcript.chunks[index] : message_lines(messages, index, width)
        append!(app.transcript.lines, lines)
        if index <= previous_count
            app.transcript.chunks[index] = lines
            app.transcript.offsets[index] = length(app.transcript.lines)
        else
            push!(app.transcript.chunks, lines)
            push!(app.transcript.offsets, length(app.transcript.lines))
        end
    end
    resize!(app.transcript.chunks, length(messages))
    resize!(app.transcript.offsets, length(messages))
    app.transcript.width = width
    app.transcript.messages = messages
    isnothing(snapshot) || (app.transcript.revision = snapshot.revision)
    return app.transcript.lines
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
    active_operation(app, value.operation_id) || return nothing
    value.progress.kind in (:answer, :code) || return nothing
    transcript = app.transcript
    previous = transcript.preview
    if isnothing(previous) || previous.kind != value.progress.kind || previous.text != value.progress.text
        transcript.preview = value.progress
        transcript.preview_operation_id = value.operation_id
        transcript.preview_dirty = true
    end
    return nothing
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
    if isnothing(progress)
        return transcript.preview_lines
    end
    if transcript.preview_dirty || transcript.preview_width != width
        messages = Message[Message(:assistant, progress.text, progress.kind)]
        empty!(transcript.preview_lines)
        append!(transcript.preview_lines, message_lines(messages, 1, width))
        transcript.preview_width = width
        transcript.preview_dirty = false
    end
    return transcript.preview_lines
end
