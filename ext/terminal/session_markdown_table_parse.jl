# Native GFM row semantics follow marked18.0.11 used by pinned Pi (MIT; licenses/marked-LICENSE).
"""Recognize source table rows while the maintained CommonMark parser owns all inline semantics."""
struct SessionMarkdownTableRule
    line_count::Int
    triggers::String
end

function SessionMarkdownTableRule(text::String)
    lines=split(text,'\n';keepempty=true);triggers=Char['|','-',':','\0']
    for line in lines
        content=strip(replace(line,r"^\s*(?:(?:>\s*)|(?:(?:[-+*]|[0-9]+[.)])\s+))*"=>""))
        !isempty(content)&&push!(triggers,first(content))
    end
    SessionMarkdownTableRule(length(lines),String(unique(triggers)))
end

function session_markdown_table_header(node::CommonMark.Node)
    buffer=node.literal_buffer
    text=isnothing(buffer) ? node.literal : String(take!(copy(buffer)))
    String(chopsuffix(text,"\n"))
end

"""Split only unescaped pipes, retaining arbitrary Unicode and literal code-cell spelling."""
function session_markdown_table_split(line::AbstractString)
    fields=String[];buffer=Char[];slashes=0
    for character in line
        if character=='|'&&iseven(slashes)
            push!(fields,String(buffer));empty!(buffer)
        else
            character=='|'&&isodd(slashes)&&pop!(buffer)
            push!(buffer,character)
        end
        slashes=character=='\\' ? slashes+1 : 0
    end
    push!(fields,String(buffer))
    !isempty(fields)&&isempty(strip(first(fields)))&&popfirst!(fields)
    !isempty(fields)&&isempty(strip(last(fields)))&&pop!(fields)
    String.(strip.(fields))
end

function session_markdown_table_spec(line::String)
    fields=session_markdown_table_split(line)
    if !isempty(fields)&&all(field->occursin(r"^:?-+:?$",field),fields)
        Symbol[startswith(field,':')&&endswith(field,':') ? :center : endswith(field,':') ? :right : :left for field in fields]
    else
        Symbol[]
    end
end

function session_markdown_table_node_row(values::Vector{String},spec::Vector{Symbol},position;header::Bool=false)
    cells=CommonMark.Node[]
    for (index,align) in enumerate(spec)
        cell=CommonMark.Node(CommonMark.TableCell;align,header,column=index)
        cell.literal=index<=length(values) ? values[index] : ""
        cell.sourcepos=position;cell.is_open=false
        push!(cells,cell)
    end
    row=CommonMark.Node(CommonMark.TableRow,cells...)
    row.sourcepos=position;row.is_open=false
    row
end

function session_markdown_table_start!(parser::CommonMark.Parser,container::CommonMark.Node,header::String,line::String,spec::Vector{Symbol},suffix::String;prefix::String="")
    position=((parser.line_number-1,container.sourcepos[1][2]),(parser.line_number-1,length(header)))
    row=session_markdown_table_node_row(session_markdown_table_split(header),spec,position;header=true)
    head=CommonMark.Node(CommonMark.TableHeader,row);head.sourcepos=position;head.is_open=false
    table=CommonMark.Node(CommonMark.Table,head;align=spec)
    table.sourcepos=position;table.last_child.is_open=false
    table.meta=Dict{String,Any}("JuliaForever2.tableRaw"=>header*"\n"*line*suffix)
    CommonMark.insert_after(container,table)
    if isempty(prefix)
        CommonMark.unlink(container)
    else
        container.literal_buffer=nothing;container.literal=prefix*"\n";container.is_open=false
        container.sourcepos=(container.sourcepos[1],(parser.line_number-2,length(last(split(prefix,'\n')))))
    end
    parser.tip=table;CommonMark.advance_to_end(parser)
    2
end

function session_markdown_table_append!(parser::CommonMark.Parser,table::CommonMark.Node,line::String,suffix::String)
    spec=(table.t::CommonMark.Table).spec
    row=session_markdown_table_node_row(session_markdown_table_split(line),spec,((parser.line_number,1),(parser.line_number,length(line))))
    CommonMark.append_child(table.last_child,row)
    existing=table.meta;metadata=isnothing(existing) ? Dict{String,Any}() : copy(existing)
    raw=get(metadata,"JuliaForever2.tableRaw","")
    metadata["JuliaForever2.tableRaw"]=(raw isa String ? raw : "")*line*suffix
    table.meta=metadata
    CommonMark.advance_to_end(parser)
    2
end

struct SessionMarkdownTableBodyRule
    table::SessionMarkdownTableRule
end

function session_markdown_table_parse(rule::SessionMarkdownTableRule,parser::CommonMark.Parser,container::CommonMark.Node)
    line=String(CommonMark.rest_from_nonspace(parser))
    suffix=parser.line_number<rule.line_count ? "\n" : ""
    if parser.indented||parser.blank
        0
    elseif container.t isa CommonMark.Paragraph && (startswith(line,'|')||startswith(line,'-')||startswith(line,':'))
        lines=split(session_markdown_table_header(container),'\n';keepempty=true);header=String(last(lines));spec=session_markdown_table_spec(line)
        prefix=String(join(lines[1:end-1],'\n'))
        valid=(occursin('|',line)||occursin(':',line))&&!isempty(spec)&&length(session_markdown_table_split(header))==length(spec)
        valid ? session_markdown_table_start!(parser,container,header,line,spec,suffix;prefix) : 0
    else
        0
    end
end
CommonMark.block_rule(rule::SessionMarkdownTableRule)=CommonMark.Rule((parser,container)->session_markdown_table_parse(rule,parser,container),0.4,"|-:")

function session_markdown_table_body(rule::SessionMarkdownTableBodyRule,parser::CommonMark.Parser,container::CommonMark.Node)
    if !parser.indented&&!parser.blank&&container.t isa CommonMark.Table
        line=String(CommonMark.rest_from_nonspace(parser))
        suffix=parser.line_number<rule.table.line_count ? "\n" : ""
        session_markdown_table_append!(parser,container,line,suffix)
    else
        0
    end
end
CommonMark.block_rule(rule::SessionMarkdownTableBodyRule)=CommonMark.Rule((parser,container)->session_markdown_table_body(rule,parser,container),1000,rule.table.triggers)
