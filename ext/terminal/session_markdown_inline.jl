"""Compose native inline styles without discarding spaces inside formatted text."""
function session_markdown_inline_style(style::Tachikoma.Style;fg=style.fg,bold=style.bold,italic=style.italic,underline=style.underline,strikethrough=style.strikethrough)
    Tachikoma.Style(;fg,bg=style.bg,bold,italic,underline,dim=style.dim,strikethrough,hyperlink=style.hyperlink)
end

"""Render real Markdown syntax through typed native style operations, never raw terminal escape programs."""
function session_markdown_paragraph(node::CommonMark.Node,kind::Symbol,italic::Bool;base_style::Tachikoma.Style=session_display_style(kind;italic),restore_style::Union{Nothing,Tachikoma.Style}=nothing,hyperlinks::Bool=false)
    heading=node.t isa CommonMark.Heading
    prefix=isnothing(restore_style) ? session_markdown_default_prefix(base_style;heading) : session_markdown_default_prefix(restore_style;heading=true)
    session_markdown_program_rows(session_markdown_children_program(node,base_style;heading,prefix,hyperlinks))
end
