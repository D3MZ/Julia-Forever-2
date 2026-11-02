"""A whole-block native syntax policy; source is inert and bounded before grammar parsing."""
Base.@kwdef struct SessionMarkdownSyntax
    phase::Symbol = :full
    max_bytes::Int = 262_144
end

const SESSION_MARKDOWN_ALIASES=Dict("js"=>"javascript","ts"=>"typescript","py"=>"python","sh"=>"bash","shell"=>"bash","rb"=>"ruby","rs"=>"rust","c++"=>"cpp","c#"=>"csharp","cs"=>"csharp","yml"=>"yaml","md"=>"markdown")

function session_markdown_language(info::String)
    get(SESSION_MARKDOWN_ALIASES,lowercase(info),lowercase(info))
end

function (policy::SessionMarkdownSyntax)(info::String,text::String)
    policy.phase in (:eager,:full)||error("Unsupported syntax initialization phase")
    language=session_markdown_language(info)
    result=language=="julia" ? JuliaForever2.julia_source_highlight(text;max_bytes=policy.max_bytes) : source_syntax_highlight(language,text;phase=policy.phase,max_bytes=policy.max_bytes)
    styles=fill(session_display_style(:codeblock),length(text))
    if language in ("text","txt","plaintext")
        fill!(styles,session_syntax_style(:default))
    elseif result.status==:success
        fill!(styles,session_syntax_style(:default))
        positions=session_syntax_positions(text)
        colors=sort(session_markdown_fragment_colors(result,language,text,policy);by=color->(color.priority>=1000,-(color.last-color.first),color.priority))
        for color in colors
            if 1<=color.first<=color.last<=ncodeunits(text)&&isvalid(text,color.first)&&(color.last==ncodeunits(text)||isvalid(text,color.last+1))
                styles[positions[color.first]:positions[color.last+1]-1].=Ref(session_parser_style(color.kind))
            end
        end
    elseif result.status==:unsupported&&language in values(SESSION_SYNTAX_EXTENSIONS)&&ncodeunits(text)<=policy.max_bytes&&!(policy.phase==:eager&&!(language in SESSION_PARSER_EAGER))
        fill!(styles,session_syntax_style(:default))
        positions=session_syntax_positions(text)
        if language in ("markdown","html")
            session_syntax_markup!(styles,positions,text,language)
        else
            session_syntax_lex!(styles,positions,text,language)
            session_syntax_semantics!(styles,positions,text,language)
            language=="yaml"&&session_syntax_markup!(styles,positions,text,language)
        end
    end
    session_syntax_lines(text,styles;keep_trailing=true)
end

"""Render code-bearing Markdown branches without changing third-party renderer methods."""
Base.@kwdef struct SessionMarkdownBlocks{H}
    width::Int
    highlighter::H = SessionMarkdownSyntax()
    kind::Symbol = :default
    italic::Bool = false
    terminal_newline::Bool = false
    quote_context::Bool = false
    hyperlinks::Bool = false
end

function session_markdown_plain(text::String,width::Int;kind::Symbol=:default,italic::Bool=false)
    Tachikoma.markdown_to_spans(text,max(1,width);
        h1_style=session_display_style(:heading;bold=true),h2_style=session_display_style(:heading;bold=true),h3_style=session_display_style(:heading;bold=true),
        bold_style=session_display_style(kind;bold=true,italic),emph_style=session_display_style(kind;italic=true),
        code_style=session_display_style(:code),link_style=session_display_style(:link),quote_style=session_display_style(:muted),
        text_style=session_display_style(kind;italic),hr_style=session_display_style(:muted))
end

function session_markdown_children(node::CommonMark.Node)
    result=CommonMark.Node[]
    child=node.first_child
    while !CommonMark.isnull(child)
        push!(result,child)
        child=child.nxt
    end
    result
end

session_markdown_has_code(node::CommonMark.Node)=any(item->item[2]&&item[1].t isa CommonMark.CodeBlock,node)

"""Empty boundary spans retain owned wrap-state styles without embedding terminal controls."""
function session_markdown_wrap(line::Vector{Tachikoma.Span},width::Int;boundaries=false)
    rows=session_display_wrap(line,max(1,width),0;preserve_gap_style=true,boundary_styles=true)
    boundaries ? [vcat([Tachikoma.Span("",first(row).style)],row[2:end-1],[Tachikoma.Span("",last(row).style)]) for row in rows] : [row[2:end-1] for row in rows]
end

function session_markdown_code(node::CommonMark.Node,context::SessionMarkdownBlocks,terminal::Bool)
    code=node.t::CommonMark.CodeBlock
    text=String(chopsuffix(node.literal,"\n"))
    if code.is_fenced&&terminal&&!context.terminal_newline
        lines=split(text,'\n';keepempty=true)
        tail=String(last(lines))
        if 0<length(tail)<code.fence_length&&all(==(code.fence_char),tail)
            pop!(lines)
            text=join(lines,'\n')
        end
    end
    rows=SessionDisplayRows([[Tachikoma.Span("```"*code.info,session_display_style(:muted))]])
    for line in context.highlighter(code.info,text)
        push!(rows,vcat([Tachikoma.Span("  ",Tachikoma.Style())],line))
    end
    push!(rows,[Tachikoma.Span("```",session_display_style(:muted))])
    rows
end

function session_markdown_quote_style(style::Tachikoma.Style)
    fg=style.fg isa Tachikoma.NoColor ? session_display_style(:muted).fg : style.fg
    Tachikoma.Style(;fg,bg=style.bg,bold=style.bold,dim=style.dim,italic=true,underline=style.underline,strikethrough=style.strikethrough,hyperlink=style.hyperlink)
end

"""Reapply quote style only until a real foreground scope closes, matching code-token resets."""
function session_markdown_quote_spans(line::Vector{Tachikoma.Span})
    result=Tachikoma.Span[];colored=false
    for span in line
        if !isempty(span.content)
            old=span.style
            fg=old.fg isa Tachikoma.NoColor && !colored ? session_display_style(:muted).fg : old.fg
            colored|=!(old.fg isa Tachikoma.NoColor)
            style=Tachikoma.Style(;fg,bg=old.bg,bold=old.bold,dim=old.dim,italic=true,underline=old.underline,strikethrough=old.strikethrough,hyperlink=old.hyperlink)
            push!(result,Tachikoma.Span(span.content,style))
        end
    end
    result
end

function session_markdown_quote(node::CommonMark.Node,context::SessionMarkdownBlocks,terminal::Bool)
    width=context.width
    inner=width<3 ? context : SessionMarkdownBlocks(;width=width-2,highlighter=context.highlighter,kind=:default,terminal_newline=context.terminal_newline,quote_context=true,hyperlinks=context.hyperlinks)
    content=session_markdown_sequence(node,inner,terminal)
    rows=SessionDisplayRows()
    for line in content
        if width<3
            push!(rows,line)
        else
            styled=session_markdown_quote_spans(line)
            for wrapped in session_markdown_wrap(styled,width-2;boundaries=true)
                border=session_display_style(:muted)
                push!(rows,vcat([first(wrapped),Tachikoma.Span("│ ",border)],wrapped[2:end]))
            end
        end
    end
    rows
end

function session_markdown_list(node::CommonMark.Node,context::SessionMarkdownBlocks,terminal::Bool;depth::Int=0)
    data=(node.t::CommonMark.List).list_data
    items=session_markdown_children(node)
    rows=SessionDisplayRows()
    for (index,item) in enumerate(items)
        marker=data.type==:ordered ? string(data.start+index-1,". ") : "- "
        item.t isa CommonMark.TaskItem && (marker*=item.t.checked ? "[x] " : "[ ] ")
        indent=repeat("    ",depth)
        firstprefix=[Tachikoma.Span(indent,Tachikoma.Style()),Tachikoma.Span(marker,session_display_style(:accent))]
        continuation=[Tachikoma.Span(indent*repeat(" ",textwidth(marker)),Tachikoma.Style())]
        itemwidth=max(1,context.width-textwidth(indent)-textwidth(marker))
        inner=SessionMarkdownBlocks(;width=itemwidth,highlighter=context.highlighter,kind=context.kind,italic=context.italic,terminal_newline=context.terminal_newline,quote_context=context.quote_context,hyperlinks=context.hyperlinks)
        children=session_markdown_children(item)
        rendered=false
        for (childindex,child) in enumerate(children)
            tail=terminal&&index==length(items)&&childindex==length(children)
            if child.t isa CommonMark.List
                append!(rows,session_markdown_list(child,context,tail;depth=depth+1))
                rendered=true
            else
                if childindex>1&&!data.tight&&child.sourcepos[1][1]>children[childindex-1].sourcepos[2][1]+1
                    push!(rows,copy(continuation))
                end
                for line in session_markdown_block(child,inner,tail)
                    for wrapped in session_markdown_wrap(line,itemwidth)
                        push!(rows,vcat(rendered ? continuation : firstprefix,wrapped))
                        rendered=true
                    end
                end
            end
        end
        rendered||push!(rows,firstprefix)
        !data.tight&&index<length(items)&&push!(rows,Tachikoma.Span[])
    end
    rows
end

function session_markdown_block(node::CommonMark.Node,context::SessionMarkdownBlocks,terminal::Bool)
    if node.t isa CommonMark.CodeBlock
        session_markdown_code(node,context,terminal)
    elseif node.t isa CommonMark.BlockQuote
        session_markdown_quote(node,context,terminal)
    elseif node.t isa CommonMark.List
        session_markdown_list(node,context,terminal)
    elseif node.t isa CommonMark.Table
        session_markdown_table(node,context)
    elseif node.t isa CommonMark.ReferenceDefinition
        SessionDisplayRows()
    elseif node.t isa CommonMark.Heading
        level=node.t.level
        style=session_markdown_inline_style(session_display_style(:heading;bold=true);underline=level==1)
        rows=session_markdown_paragraph(node,:heading,false;base_style=style,hyperlinks=context.hyperlinks)
        level>=3&&!isempty(rows)&&pushfirst!(first(rows),Tachikoma.Span(repeat("#",level)*" ",style))
        rows
    elseif node.t isa CommonMark.Paragraph
        session_markdown_paragraph(node,context.kind,context.italic;restore_style=context.quote_context ? session_display_style(:muted;italic=true) : nothing,hyperlinks=context.hyperlinks)
    else
        session_markdown_plain(String(CommonMark.markdown(node)),context.width;kind=context.kind,italic=context.italic)
    end
end

function session_markdown_sequence(node::CommonMark.Node,context::SessionMarkdownBlocks,terminal::Bool)
    children=session_markdown_children(node)
    rows=SessionDisplayRows()
    for (index,child) in enumerate(children)
        append!(rows,session_markdown_block(child,context,terminal&&index==length(children)))
        if index<length(children)
            next=children[index+1]
            gap=next.sourcepos[1][1]>child.sourcepos[2][1]+1 || child.last_line_blank
            spacing=gap||!(child.t isa CommonMark.List)&&!(child.t isa CommonMark.ReferenceDefinition)&&!(child.t isa CommonMark.Paragraph&&next.t isa CommonMark.List)
            spacing&&push!(rows,Tachikoma.Span[])
        end
    end
    rows
end

"""Return logical native Markdown rows with explicit, whole-block code rendering."""
function session_markdown_spans(raw::AbstractString,width::Int;kind::Symbol=:default,italic=false,highlighter=SessionMarkdownSyntax(),hyperlinks::Bool=session_markdown_hyperlinks())
    text=String(session_display_safe(raw))
    parser=CommonMark.Parser()
    CommonMark.disable!(parser,CommonMark.HtmlEntityRule())
    CommonMark.enable!(parser,SessionMarkdownReferenceRule(String.(split(text,'\n';keepempty=true))))
    CommonMark.enable!(parser,SessionMarkdownLabelRule())
    CommonMark.enable!(parser,CommonMark.StrikethroughRule())
    table_rule=SessionMarkdownTableRule(text)
    CommonMark.enable!(parser,table_rule)
    CommonMark.enable!(parser,SessionMarkdownTableBodyRule(table_rule))
    CommonMark.enable!(parser,CommonMark.TaskListRule())
    ast=parser(text)
    session_markdown_resolve_references!(ast)
    context=SessionMarkdownBlocks(;width=max(1,width),highlighter,kind,italic,terminal_newline=endswith(text,'\n'),hyperlinks)
    rows=SessionDisplayRows()
    for line in session_markdown_sequence(ast,context,true)
        append!(rows,session_markdown_wrap(line,max(1,width);boundaries=true))
    end
    rows
end
