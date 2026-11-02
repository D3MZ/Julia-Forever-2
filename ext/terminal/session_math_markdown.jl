# App-owned native CommonMark integration; math is inert source data, never a process or TeX interpreter.
struct SessionMarkdownMathInline <: CommonMark.AbstractInline
    token::SessionMathToken
    enabled::Bool
end
struct SessionMarkdownMathBlock <: CommonMark.AbstractBlock
    token::SessionMathToken
    ending::Int
    enabled::Bool
end
struct SessionMarkdownMathRule
    source_lines::Vector{String}
    enabled::Bool
end
SessionMarkdownMathRule(source::String,enabled::Bool=true)=SessionMarkdownMathRule(String.(split(replace(source,r"\r\n?"=>"\n"),'\n';keepempty=true)),enabled)

function session_math_parse_inline!(rule::SessionMarkdownMathRule,parser::CommonMark.InlineParser,node::CommonMark.Node)
    source=String(SubString(parser.buf,position(parser)))
    token=session_math_inline_token(source)
    if isnothing(token)
        false
    else
        child=CommonMark.Node(SessionMarkdownMathInline(token,rule.enabled));child.literal=token.text
        CommonMark.append_child(node,child);seek(parser,position(parser)+ncodeunits(token.raw))
        true
    end
end
CommonMark.inline_rule(rule::SessionMarkdownMathRule)=CommonMark.Rule((parser,node)->session_math_parse_inline!(rule,parser,node),0.5,"\$\\")

function session_math_ancestors(node::CommonMark.Node)
    ancestors=CommonMark.Node[];current=node
    while !CommonMark.isnull(current)
        (current.t isa CommonMark.BlockQuote||current.t isa CommonMark.Item)&&push!(ancestors,current)
        current=current.parent
    end
    reverse(ancestors)
end

"""Ask maintained native quote/list continuation rules for logical lines without mutating their archival nodes."""
function session_math_logical_source(rule::SessionMarkdownMathRule,parser::CommonMark.Parser,container::CommonMark.Node)
    lines=String[String(CommonMark.rest(parser))];ancestors=session_math_ancestors(container);matched=true
    probe=CommonMark.Parser()
    for number in parser.line_number+1:length(rule.source_lines)
        if matched
            probe.buf=rule.source_lines[number];probe.len=length(probe.buf);probe.pos=1;probe.column=0
            probe.blank=false;probe.partially_consumed_tab=false;probe.line_number=number
            for ancestor in ancestors
                if matched
                    CommonMark.find_next_nonspace(probe)
                    if ancestor.t isa CommonMark.Item&&probe.blank&&CommonMark.isnull(ancestor.first_child)
                        CommonMark.advance_next_nonspace(probe)
                    else
                        matched=CommonMark.continue_(ancestor.t,probe,ancestor)==0
                    end
                end
            end
            matched&&push!(lines,String(CommonMark.rest(probe)))
        end
    end
    join(lines,'\n')
end

function session_math_parse_block!(rule::SessionMarkdownMathRule,parser::CommonMark.Parser,container::CommonMark.Node)
    prefix=String(CommonMark.rest(parser))
    if parser.indented||!occursin(r"^ {0,3}(?:\$\$|\\\[)",prefix)
        0
    else
        token=session_math_block_token(session_math_logical_source(rule,parser,container))
        if isnothing(token)
            0
        else
            ending=parser.line_number+count(==('\n'),chopsuffix(token.raw,"\n"))
            CommonMark.close_unmatched_blocks(parser)
            CommonMark.add_child(parser,SessionMarkdownMathBlock(token,ending,rule.enabled),parser.next_nonspace)
            CommonMark.advance_to_end(parser)
            2
        end
    end
end
CommonMark.block_rule(rule::SessionMarkdownMathRule)=CommonMark.Rule((parser,node)->session_math_parse_block!(rule,parser,node),0.3,"\$\\")
CommonMark.accepts_lines(::SessionMarkdownMathBlock)=true
CommonMark.can_contain(::SessionMarkdownMathBlock,::Any)=false
function CommonMark.continue_(data::SessionMarkdownMathBlock,parser::CommonMark.Parser,node::CommonMark.Node)
    if parser.line_number>data.ending
        1
    else
        CommonMark.advance_to_end(parser);0
    end
end
function CommonMark.finalize(data::SessionMarkdownMathBlock,parser::CommonMark.Parser,node::CommonMark.Node)
    node.literal=data.token.raw;node.literal_buffer=nothing
    nothing
end

function session_math_inline_program(data::SessionMarkdownMathInline,style::Tachikoma.Style;heading::Bool=false)
    rendered=data.enabled&&!data.token.pending ? session_math_render(data.token.text) : nothing
    session_markdown_literal_program(something(rendered,data.token.raw),style;heading)
end
function session_math_block_rows(data::SessionMarkdownMathBlock,context::SessionMarkdownBlocks)
    rendered=data.enabled&&!data.token.pending ? session_math_render(data.token.text;display=true) : nothing
    text=if isnothing(rendered)
        String(strip(data.token.raw))
    elseif any(line->session_math_width(line)>context.width,split(rendered,'\n';keepempty=true))
        String(strip(data.token.raw))
    else
        rendered
    end
    SessionDisplayRows([[Tachikoma.Span(String(line),session_display_style(context.kind;italic=context.italic))] for line in split(text,'\n';keepempty=true)])
end
