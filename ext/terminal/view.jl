function draw_footer!(buffer, x, y, width, app::App)
    right = provider_selection_snapshot(app.session.kernel).detail
    left = usage_label(app.session)
    app.status == "Ready" || (left = isempty(left) ? app.status : left * " · " * app.status)
    drawline!(buffer, x, y, width, left, :text_dim)
    available = max(0, width - textwidth(left) - (isempty(left) ? 0 : 1))
    clipped = Tachikoma.truncate_to_width(right, available)
    drawline!(buffer, x + width - textwidth(clipped), y, textwidth(clipped), clipped, :text_dim)
end

function pi_style(style::Symbol)
    color = style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
        style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
        style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
    return Tachikoma.Style(; fg=color)
end

function drawline!(buffer, x, y, width, text, style=:text)
    y < 1 && return
    Tachikoma.set_string!(buffer, x, y, text, pi_style(style); max_x=x + width - 1)
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
    drawline!(buf, x, border, w, repeat("─", w), :border)
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
