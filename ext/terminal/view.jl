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
    runtime = ACTIVE_NATIVE_THEME[]
    if !isnothing(runtime)
        theme_style(runtime, style)
    else
    color = style == :menu_border ? Tachikoma.ColorRGB(95, 168, 204) :
        style == :muted ? Tachikoma.ColorRGB(157, 165, 169) :
        style == :accent ? Tachikoma.ColorRGB(167, 152, 215) :
        style == :border ? Tachikoma.ColorRGB(151, 118, 229) :
        style == :text_dim ? Tachikoma.ColorRGB(126, 136, 142) : Tachikoma.ColorRGB(222, 224, 225)
    style == :terminal_default ? Tachikoma.Style() : Tachikoma.Style(; fg=color)
    end
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

function draw_conversation_line!(buffer, x, y, width, line::AbstractString, style; padding::Int=1)
    if style in (:user_message, :code_result)
        color = style == :user_message ? Tachikoma.ColorRGB(33, 59, 73) : Tachikoma.ColorRGB(37, 65, 49)
        bg = Tachikoma.Style(; fg=pi_style(:text).fg, bg=color)
        Tachikoma.set_string!(buffer, x, y, repeat(" ", width), bg; max_x=x + width - 1)
        Tachikoma.set_string!(buffer, x + padding, y, line, bg; max_x=x + width - padding - 1)
    else
        drawline!(buffer, x + padding, y, width - 2padding, line, style)
    end
end

function draw_conversation_line!(buffer, x, y, width, spans::Vector{Tachikoma.Span}, style; padding::Int=1)
    if style == :archive
        draw_session_display_line!(buffer, x, y, width, spans)
    elseif style == :markdown
        rendered=session_display_wrap(spans,width,padding;boundary_styles=true)
        draw_session_display_line!(buffer,x,y,width,first(rendered))
    else
    column = x + padding
    for span in spans
        column = Tachikoma.set_string!(buffer, column, y, span.content, span.style; max_x=x + width - padding - 1)
    end
    end
end

function default_view!(app::App, frame::Frame)
    if frame.area.width >= 5 && frame.area.height >= 5
        page_view!(app, Val(app.page), frame)
    else
        terminal_output_cursor!(app,nothing)
    end
    nothing
end

function page_view!(app::App, page::Val, frame::Frame)
    startup_host_view!(app,frame)
    nothing
end
