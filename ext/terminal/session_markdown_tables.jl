# Native width allocation follows pinned Pi markdown.ts renderTable (MIT; licenses/pi-LICENSE).
session_markdown_table_width(text::AbstractString)=sum(menu_search_grapheme_width(String(glyph)) for glyph in Base.Unicode.graphemes(text);init=0)
session_markdown_table_text(spans::Vector{Tachikoma.Span})=join(span.content for span in spans)

"""Allocate real table column widths by longest words and proportional growth, preserving source rounding order."""
function session_markdown_table_widths(cells::Vector{Vector{Vector{Tachikoma.Span}}},columns::Int,width::Int)
    natural=zeros(Int,columns);minimum=ones(Int,columns)
    for row in cells,(index,cell) in enumerate(row)
        text=session_markdown_table_text(cell)
        natural[index]=max(natural[index],session_markdown_table_width(text))
        longest=maximum((session_markdown_table_width(word) for word in split(text));init=0)
        minimum[index]=max(minimum[index],min(30,longest))
    end
    available=width-(3columns+1)
    if sum(minimum)>available
        weights=max.(0,minimum.-1);total=sum(weights);remaining=available-columns
        growth=total>0 ? [floor(Int,(weight/total)*remaining) for weight in weights] : zeros(Int,columns)
        minimum=1 .+ growth
        leftover=remaining-sum(growth)
        for index in 1:min(columns,leftover)
            minimum[index]+=1
        end
    end
    result=if sum(natural)+3columns+1<=width
        max.(natural,minimum)
    else
        potential=max.(0,natural.-minimum);total=sum(potential);extra=max(0,available-sum(minimum))
        minimum .+ (total>0 ? [floor(Int,(value/total)*extra) for value in potential] : zeros(Int,columns))
    end
    remaining=available-sum(result)
    while remaining>0
        grew=false
        for index in 1:columns
            if remaining>0&&result[index]<natural[index]
                result[index]+=1;remaining-=1;grew=true
            end
        end
        grew||(remaining=0)
    end
    result
end

function session_markdown_table_cell(node::CommonMark.Node,context::SessionMarkdownBlocks)
    style=session_display_style(context.kind;italic=context.italic)
    prefix=context.quote_context ? session_markdown_default_prefix(session_display_style(:muted;italic=true);heading=true) : session_markdown_default_prefix(style)
    program=session_markdown_children_program(node,style;prefix,hyperlinks=context.hyperlinks)
    rows=session_markdown_program_rows(program)
    result=Tachikoma.Span[]
    for (index,row) in enumerate(rows)
        index>1&&push!(result,Tachikoma.Span("\n",style))
        append!(result,row)
    end
    result
end

function session_markdown_table_border(widths::Vector{Int},left::String,middle::String,right::String)
    [Tachikoma.Span(left*join([repeat("─",width) for width in widths],middle)*right,Tachikoma.Style())]
end

function session_markdown_table_row(cells::Vector{Vector{Tachikoma.Span}},widths::Vector{Int},context::SessionMarkdownBlocks;header::Bool=false)
    wrapped=[session_markdown_table_wrap(cell,width) for (cell,width) in zip(cells,widths)]
    count=maximum(length,wrapped;init=0);result=SessionDisplayRows()
    tail=context.quote_context ? session_display_style(:muted;italic=true) : session_display_style(context.kind;italic=context.italic)
    for index in 1:count
        row=Tachikoma.Span[Tachikoma.Span("│ ",Tachikoma.Style())]
        for (column,lines) in enumerate(wrapped)
            content=index<=length(lines) ? lines[index] : Tachikoma.Span[]
            context.quote_context&&(content=session_markdown_quote_spans(content))
            for span in content
                style=header ? session_markdown_inline_style(span.style;bold=true) : span.style
                push!(row,Tachikoma.Span(span.content,style))
            end
            used=session_markdown_table_width(session_markdown_table_text(content))
            push!(row,Tachikoma.Span(repeat(" ",max(0,widths[column]-used)),header ? session_markdown_inline_style(tail;bold=true) : tail))
            push!(row,Tachikoma.Span(column==length(widths) ? " │" : " │ ",tail))
        end
        push!(result,row)
    end
    result
end

"""Render native parsed table cells; narrow terminals show the actual inert Markdown source rather than a stub."""
function session_markdown_table(node::CommonMark.Node,context::SessionMarkdownBlocks)
    rows=CommonMark.Node[child for (child,entering) in node if entering&&child.t isa CommonMark.TableRow]
    columns=length((node.t::CommonMark.Table).spec)
    if columns==0
        SessionDisplayRows()
    elseif context.width-(3columns+1)<columns
        metadata=node.meta
        raw=isnothing(metadata) ? nothing : get(metadata,"JuliaForever2.tableRaw",nothing)
        text=raw isa String ? raw : String(CommonMark.markdown(node))
        next=node.nxt
        gap=!CommonMark.isnull(next)&&(next.sourcepos[1][1]>node.sourcepos[2][1]+1||node.last_line_blank)
        gap&&(text=String(chopsuffix(text,"\n")))
        result=SessionDisplayRows()
        for line in split(text,'\n';keepempty=true)
            append!(result,session_markdown_wrap([Tachikoma.Span(String(line),Tachikoma.Style())],context.width))
        end
        result
    else
        cells=[[session_markdown_table_cell(cell,context) for cell in session_markdown_children(row)] for row in rows]
        widths=session_markdown_table_widths(cells,columns,context.width)
        result=SessionDisplayRows([session_markdown_table_border(widths,"┌─","─┬─","─┐")])
        for (index,row) in enumerate(cells)
            append!(result,session_markdown_table_row(row,widths,context;header=index==1))
            (index==1||index<length(cells))&&push!(result,session_markdown_table_border(widths,"├─","─┼─","─┤"))
        end
        push!(result,session_markdown_table_border(widths,"└─","─┴─","─┘"))
        result
    end
end

function session_markdown_table_tokens(spans::Vector{Tachikoma.Span})
    tokens=Vector{Vector{Tachikoma.Span}}();current=Tachikoma.Span[];previous=""
    for span in spans,glyph in Base.Unicode.graphemes(span.content)
        text=String(glyph)
        whitespace=text==" "
        boundary=!isempty(current)&&(whitespace!=(previous==" ")||!whitespace&&(session_display_cjk(text)||session_display_cjk(previous)))
        if boundary
            push!(tokens,current);current=Tachikoma.Span[]
        end
        push!(current,Tachikoma.Span(text,span.style));previous=text
    end
    !isempty(current)&&push!(tokens,current)
    tokens
end

session_markdown_table_active(style::Tachikoma.Style)=!(style.fg isa Tachikoma.NoColor)||!(style.bg isa Tachikoma.NoColor)||style.bold||style.dim||style.italic||style.underline||style.strikethrough||!isempty(style.hyperlink)

function session_markdown_table_trim(spans::Vector{Tachikoma.Span})
    stop=findlast(span->!all(isspace,span.content),spans)
    isnothing(stop) ? Tachikoma.Span[] : spans[1:stop]
end

"""Preserve real word-breaking and active-style-only rows before overlong tokens, using typed spans rather than ANSI."""
function session_markdown_table_wrap(spans::Vector{Tachikoma.Span},width::Int)
    if session_markdown_table_width(session_markdown_table_text(spans))<=width
        [spans]
    else
        rows=SessionDisplayRows();current=Tachikoma.Span[];used=0;prefix=false
        for token in session_markdown_table_tokens(spans)
            text=session_markdown_table_text(token);size=session_markdown_table_width(text);whitespace=all(isspace,text)
            if size>width&&!whitespace
                if !isempty(current)||prefix
                    push!(rows,session_markdown_table_trim(current));current=Tachikoma.Span[];used=0
                end
                for glyph in token
                    glyphwidth=session_markdown_table_width(glyph.content)
                    if used+glyphwidth>width
                        push!(rows,current);current=Tachikoma.Span[];used=0
                    end
                    push!(current,glyph);used+=glyphwidth
                end
                prefix=false
            elseif used+size>width&&used>0
                push!(rows,session_markdown_table_trim(current))
                current=whitespace ? Tachikoma.Span[] : copy(token)
                used=whitespace ? 0 : size
                prefix=whitespace&&session_markdown_table_active(last(token).style)
            elseif whitespace&&used+size>width&&session_markdown_table_active(last(token).style)
                prefix=true
            else
                append!(current,token);used+=size
            end
        end
        (!isempty(current)||prefix)&&push!(rows,session_markdown_table_trim(current))
        isempty(rows) ? SessionDisplayRows([Tachikoma.Span[]]) : rows
    end
end
