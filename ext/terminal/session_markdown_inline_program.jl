# Native rendering contract follows Pi 2c8d1feb147f6b3d97e855da803bfe7b19f3c403 (MIT; licenses/pi-LICENSE).
"""Owned style operations preserve nested Markdown scope semantics without parsing terminal controls."""
struct SessionMarkdownStyleOp
    kind::Symbol
    color::Tachikoma.AbstractColor
    destination::String
end
SessionMarkdownStyleOp(kind::Symbol,color::Tachikoma.AbstractColor)=SessionMarkdownStyleOp(kind,color,"")
SessionMarkdownStyleOp(kind::Symbol)=SessionMarkdownStyleOp(kind,Tachikoma.NoColor())
const SessionMarkdownPart=Union{String,SessionMarkdownStyleOp}
const SessionMarkdownProgram=Vector{SessionMarkdownPart}

function session_markdown_attribute(program::SessionMarkdownProgram,open::Symbol,close::Symbol)
    inside=SessionMarkdownProgram()
    for item in program
        push!(inside,item)
        item isa SessionMarkdownStyleOp&&item.kind==close&&push!(inside,SessionMarkdownStyleOp(open))
    end
    SessionMarkdownPart[SessionMarkdownStyleOp(open);inside;SessionMarkdownStyleOp(close)]
end

function session_markdown_foreground(program::SessionMarkdownProgram,style::Tachikoma.Style)
    if style.fg isa Tachikoma.NoColor
        program
    elseif style.dim
        SessionMarkdownPart[SessionMarkdownStyleOp(:foreground,style.fg);SessionMarkdownStyleOp(:dim_on);program;SessionMarkdownStyleOp(:dim_foreground_off)]
    else
        SessionMarkdownPart[SessionMarkdownStyleOp(:foreground,style.fg);program;SessionMarkdownStyleOp(:foreground_off)]
    end
end

function session_markdown_default_program(program::SessionMarkdownProgram,style::Tachikoma.Style;heading=false)
    value=heading ? program : session_markdown_foreground(program,style)
    style.bold&&(value=session_markdown_attribute(value,:bold_on,:bold_off))
    style.italic&&(value=session_markdown_attribute(value,:italic_on,:italic_off))
    style.strikethrough&&(value=session_markdown_attribute(value,:strike_on,:strike_off))
    style.underline&&(value=session_markdown_attribute(value,:underline_on,:underline_off))
    heading ? session_markdown_foreground(value,style) : value
end

function session_markdown_default_prefix(style::Tachikoma.Style;heading=false)
    program=session_markdown_default_program(SessionMarkdownPart[""],style;heading)
    boundary=findfirst(item->item isa String,program)::Int
    program[1:boundary-1]
end

function session_markdown_literal_program(text::String,style::Tachikoma.Style;heading=false)
    result=SessionMarkdownProgram()
    for (index,part) in enumerate(split(text,'\n';keepempty=true))
        index>1&&push!(result,"\n")
        append!(result,session_markdown_default_program(SessionMarkdownPart[String(part)],style;heading))
    end
    result
end

function session_markdown_children_program(node::CommonMark.Node,style::Tachikoma.Style;heading=false,prefix::SessionMarkdownProgram=session_markdown_default_prefix(style;heading),hyperlinks::Bool=false)
    result=SessionMarkdownProgram()
    for child in session_markdown_children(node)
        append!(result,session_markdown_node_program(child,style,prefix;heading,hyperlinks))
    end
    while !isempty(prefix)&&length(result)>=length(prefix)&&isequal(result[end-length(prefix)+1:end],prefix)
        resize!(result,length(result)-length(prefix))
    end
    result
end

function session_markdown_node_program(node::CommonMark.Node,style::Tachikoma.Style,prefix::SessionMarkdownProgram;heading=false,hyperlinks::Bool=false)
    data=node.t
    if data isa SessionMarkdownMathInline
        session_math_inline_program(data,style;heading)
    elseif data isa CommonMark.Text || data isa CommonMark.HtmlInline
        session_markdown_literal_program(node.literal,style;heading)
    elseif data isa CommonMark.Image
        session_markdown_literal_program(replace(session_markdown_raw_label(node),r"\\([\[\]])"=>s"\1"),style;heading)
    elseif data isa CommonMark.Code
        SessionMarkdownPart[session_markdown_foreground(SessionMarkdownPart[node.literal],session_display_style(:code));prefix]
    elseif data isa CommonMark.SoftBreak || data isa CommonMark.LineBreak
        SessionMarkdownPart["\n"]
    elseif data isa CommonMark.Link
        body=session_markdown_children_program(node,style;heading,prefix,hyperlinks)
        result=session_markdown_foreground(session_markdown_attribute(body,:underline_on,:underline_off),session_display_style(:link))
        href=session_markdown_display_href(node);label=session_markdown_raw_label(node)
        comparison=startswith(href,"mailto:") ? String(chopprefix(href,"mailto:")) : href
        target=hyperlinks ? session_markdown_link_target(data.destination) : ""
        if !isempty(target)
            result=SessionMarkdownPart[SessionMarkdownStyleOp(:hyperlink,Tachikoma.NoColor(),target);result;SessionMarkdownStyleOp(:hyperlink_off)]
        elseif label!=href&&label!=comparison
            append!(result,session_markdown_foreground(SessionMarkdownPart[" ("*href*")"],session_display_style(:linkurl)))
        end
        append!(result,prefix)
        result
    elseif data isa CommonMark.Strong || data isa CommonMark.Emph || data isa CommonMark.Strikethrough
        body=session_markdown_children_program(node,style;heading,prefix,hyperlinks)
        open,close=data isa CommonMark.Strong ? (:bold_on,:bold_off) : data isa CommonMark.Emph ? (:italic_on,:italic_off) : (:strike_on,:strike_off)
        SessionMarkdownPart[session_markdown_attribute(body,open,close);prefix]
    else
        session_markdown_literal_program(node.literal,style;heading)
    end
end

function session_markdown_apply_op(style::Tachikoma.Style,operation::SessionMarkdownStyleOp)
    kind=operation.kind
    fg=kind==:foreground ? operation.color : kind in (:foreground_off,:dim_foreground_off) ? Tachikoma.NoColor() : style.fg
    bold=kind==:bold_on || !(kind in (:bold_off,:dim_foreground_off))&&style.bold
    dim=kind==:dim_on || !(kind in (:bold_off,:dim_foreground_off))&&style.dim
    italic=kind==:italic_on || kind!=:italic_off&&style.italic
    underline=kind==:underline_on || kind!=:underline_off&&style.underline
    strikethrough=kind==:strike_on || kind!=:strike_off&&style.strikethrough
    hyperlink=kind==:hyperlink ? operation.destination : kind==:hyperlink_off ? "" : style.hyperlink
    Tachikoma.Style(;fg,bg=style.bg,bold,dim,italic,underline,strikethrough,hyperlink)
end

function session_markdown_program_rows(program::SessionMarkdownProgram)
    rows=SessionDisplayRows([Tachikoma.Span[]]);style=Tachikoma.Style()
    for item in program
        if item isa SessionMarkdownStyleOp
            style=session_markdown_apply_op(style,item)
        else
            for (index,part) in enumerate(split(item,'\n';keepempty=true))
                index>1&&push!(rows,Tachikoma.Span[])
                !isempty(part)&&push!(last(rows),Tachikoma.Span(String(part),style))
            end
        end
    end
    rows
end
