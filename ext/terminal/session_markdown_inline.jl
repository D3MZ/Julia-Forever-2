"""Compose native inline styles without discarding spaces inside formatted text."""
function session_markdown_inline_style(style::Tachikoma.Style;fg=style.fg,bold=style.bold,italic=style.italic,underline=style.underline)
    Tachikoma.Style(;fg,bg=style.bg,bold,italic,underline,dim=style.dim,strikethrough=style.strikethrough)
end

function session_markdown_paragraph(node::CommonMark.Node,kind::Symbol,italic::Bool)
    spans=Tachikoma.Span[]
    stack=Tachikoma.Style[session_display_style(kind;italic)]
    for (child,entering) in node
        data=child.t
        if child!==node
            if data isa CommonMark.Text || data isa CommonMark.HtmlInline
                entering && push!(spans,Tachikoma.Span(child.literal,last(stack)))
            elseif data isa CommonMark.Code
                entering && push!(spans,Tachikoma.Span(child.literal,session_markdown_inline_style(last(stack);fg=session_display_style(:code).fg)))
            elseif data isa CommonMark.SoftBreak || data isa CommonMark.LineBreak
                entering && push!(spans,Tachikoma.Span("\n",last(stack)))
            elseif data isa CommonMark.Strong || data isa CommonMark.Emph || data isa CommonMark.Link
                if entering
                    old=last(stack)
                    style=data isa CommonMark.Strong ? session_markdown_inline_style(old;bold=true) :
                        data isa CommonMark.Emph ? session_markdown_inline_style(old;italic=true) :
                        session_markdown_inline_style(old;fg=session_display_style(:link).fg,underline=true)
                    push!(stack,style)
                elseif length(stack)>1
                    pop!(stack)
                end
            end
        end
    end
    rows=SessionDisplayRows([Tachikoma.Span[]])
    for span in spans
        for (index,part) in enumerate(split(span.content,'\n';keepempty=true))
            index>1 && push!(rows,Tachikoma.Span[])
            !isempty(part) && push!(last(rows),Tachikoma.Span(String(part),span.style))
        end
    end
    rows
end
