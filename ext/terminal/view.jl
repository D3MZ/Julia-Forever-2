"""Compute two non-overlapping footer fields before drawing either field."""
function footer_line_parts(app::App, width::Integer)
    snapshot = JuliaForever2.session_footer_snapshot(app.session)
    left = JuliaForever2.footer_usage_label(snapshot.usage, snapshot.provider)
    if app.status != "Ready"
        left = isempty(left) ? app.status : left * " · " * app.status
    end
    full_right = JuliaForever2.footer_model_label(snapshot.provider)
    compact_right = JuliaForever2.footer_model_label(snapshot.provider; include_provider=false)
    gap = 2
    parts = if textwidth(left) + gap + textwidth(full_right) <= width
        (left=left, right=full_right)
    elseif textwidth(left) + gap + textwidth(compact_right) <= width
        (left=left, right=compact_right)
    else
        # A narrow terminal retains a useful model ID instead of clipping it behind the provider prefix.
        right = Tachikoma.truncate_to_width(compact_right, max(0, min(textwidth(compact_right), cld(width, 2))))
        room = max(0, width - textwidth(right) - (isempty(right) ? 0 : gap))
        (left=Tachikoma.truncate_to_width(left, room), right=right)
    end
    return parts
end

function draw_footer!(buffer, x, y, width, app::App)
    parts = footer_line_parts(app, width)
    isempty(parts.left) || drawline!(buffer, x, y, textwidth(parts.left), parts.left, :text_dim)
    isempty(parts.right) || drawline!(buffer, x + width - textwidth(parts.right), y,
        textwidth(parts.right), parts.right, :text_dim)
end

function pi_style(style::Symbol)
    color = style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
        style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
        style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
    return Tachikoma.Style(; fg=color)
end

function drawline!(buffer, x, y, width, text, style=:text)
    if y >= 1
        Tachikoma.set_string!(buffer, x, y, text, pi_style(style); max_x=x + width - 1)
    end
end

const WORKING_SPINNER_FRAMES = ("⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏")

"""Select the working indicator frame at an 80 millisecond interval."""
working_spinner(ticks::Integer) = WORKING_SPINNER_FRAMES[mod(fld(ticks, 80_000_000), length(WORKING_SPINNER_FRAMES)) + 1]

"""Show active operation status inside the editor border without changing input layout."""
function draw_input_border!(buffer, x, y, width, app::App; ticks::Integer=time_ns())
    drawline!(buffer, x, y, width, repeat("─", width), :border)
    if app.busy && !isnothing(app.operations.active) && !app.operations.closing[]
        spinner = working_spinner(ticks)
        label = string(spinner, ' ', app.status)
        label_width = textwidth(label)
        if label_width + 5 <= width
            drawline!(buffer, x + 2, y, 1, " ", :border)
            drawline!(buffer, x + 3, y, label_width, label, :accent)
            drawline!(buffer, x + 3 + label_width, y, 1, " ", :border)
        elseif width >= 5
            drawline!(buffer, x + 3, y, 1, spinner, :accent)
        end
    end
    return nothing
end

function draw_conversation_line!(buffer, x, y, width, line::AbstractString, style)
    if style in (:user_message, :code_result)
        color = style == :user_message ? Tachikoma.ColorRGB(33, 59, 73) : Tachikoma.ColorRGB(37, 65, 49)
        bg = Tachikoma.Style(; fg=pi_style(:text).fg, bg=color)
        Tachikoma.set_string!(buffer, x, y, repeat(" ", width), bg; max_x=x + width - 1)
        Tachikoma.set_string!(buffer, x + 1, y, line, bg; max_x=x + width - 2)
    else
        drawline!(buffer, x + 1, y, width - 2, line, style)
    end
end

function draw_conversation_line!(buffer, x, y, width, spans::Vector{Tachikoma.Span}, style)
    column = x + 1
    for span in spans
        column = Tachikoma.set_string!(buffer, column, y, span.content, span.style; max_x=x + width - 2)
    end
end

function default_view!(app::App, frame::Frame)
    app.area = frame.area
    if frame.area.width >= 5 && frame.area.height >= 5
        page_view!(app, Val(app.page), frame)
    end
    return nothing
end

function page_view!(app::App, page::Val, frame::Frame)
    area, buf = frame.area, frame.buffer
    x, y, w, h = area.x, area.y, area.width, area.height
    lines = transcript_lines!(app, w)
    preview = preview_lines!(app, w)
    matches, first, count = command_menu(app, h)
    border = y + h - 5 - count
    maxlines = max(0, border - y)
    lastline = max(0, length(lines) + length(preview) - app.scroll)
    firstline = max(1, lastline - maxlines + 1)
    for (i, index) in enumerate(firstline:lastline)
        line, style = index <= length(lines) ? lines[index] : preview[index - length(lines)]
        draw_conversation_line!(buf, x, y + i - 1, w, line, style)
    end
    draw_input_border!(buf, x, border, w, app)
    Tachikoma.render(app.input, Rect(x, border + 1, w, 1), buf)
    drawline!(buf, x, border + 2, w, repeat("─", w), :border)
    for offset in 0:(count - 1)
        index = first + offset
        name, description = matches[index]
        selected = app.selected == index
        label = (selected ? "→ " : "  ") * rpad(name, 15) * description
        drawline!(buf, x, border + 3 + offset, w, label, selected ? :accent : :text_dim)
    end
    drawline!(buf, x, y + h - 2, w, app.directory, :text_dim)
    draw_footer!(buf, x, y + h - 1, w, app)
end
