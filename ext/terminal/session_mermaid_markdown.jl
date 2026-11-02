# Native presentation adaptation of Pi 1.4.0 (MIT); see licenses/pi-LICENSE.
"""Apply semantic diagram colors without embedding untrusted terminal programs or reparsing labels."""
function session_mermaid_style(kind::Symbol)
    token=kind==:border ? :borderMuted : kind==:edge || kind==:title ? :accent : kind==:edgeLabel ? :muted : kind==:text ? :text : :code
    kind==:none ? Tachikoma.Style() : session_display_style(token;bold=kind==:title)
end

"""Transform only top-level code fences in eligible message phases, preserving readable source on decline."""
function session_mermaid_block(node::CommonMark.Node,source::String,context::SessionMarkdownBlocks)
    unchanged=(rows=nothing,warning="")
    mode=context.mermaid_mode
    if !(mode in (:final,:streaming))||context.kind==:thinking||(context.is_streaming&&mode!=:streaming)||!(node.parent.t isa CommonMark.Document)
        unchanged
    else
        words=mermaid_words((node.t::CommonMark.CodeBlock).info)
        if isempty(words)||lowercase(first(words))!="mermaid"
            unchanged
        else
            art=mermaid_cached(context.mermaid_cache,source)
            if isnothing(art)||art.width>context.width
                unchanged
            elseif !context.is_streaming&&!isempty(art.warnings)
                suffix=length(art.warnings)>1 ? " (+$(length(art.warnings)-1) more)" : ""
                (rows=nothing,warning="Mermaid diagram not rendered: "*first(art.warnings)*suffix)
            else
                rows=SessionDisplayRows()
                for (index,line) in enumerate(art.styled)
                    row=Tachikoma.Span[];colored=false
                    for span in line
                        style=span.kind==:none&&!colored ? session_display_style(:code) : session_mermaid_style(span.kind)
                        push!(row,Tachikoma.Span(span.text,style))
                        colored|=span.kind!=:none&&!isempty(span.text)
                    end
                    isempty(art.plain[index])&&(row=[Tachikoma.Span("\u00a0",session_display_style(:code))])
                    context.kind==:user&&index<length(art.styled)&&push!(row,Tachikoma.Span("",session_display_style(:user)))
                    push!(rows,row)
                end
                (rows,warning="")
            end
        end
    end
end
