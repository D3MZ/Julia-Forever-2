# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
"""Split semicolons and comments only outside double-quoted source spans."""
function mermaid_statements(source::AbstractString)
    result=String[]
    for line in mermaid_lines(source)
        chars=collect(line);buffer=IOBuffer();quoted=false;i=1
        while i<=length(chars)
            c=chars[i]
            if quoted
                c=='"'&&(quoted=false);print(buffer,c)
            elseif c=='"'
                quoted=true;print(buffer,c)
            elseif c=='%'&&mermaid_char(chars,i+1)=='%'
                break
            elseif c==';'
                statement=String(mermaid_trim(String(take!(buffer))))
                isempty(statement)||push!(result,statement)
            else
                print(buffer,c)
            end
            i+=1
        end
        statement=String(mermaid_trim(String(take!(buffer))))
        isempty(statement)||push!(result,statement)
    end
    result
end
function mermaid_kind(statements::Vector{String})
    kind=isempty(statements) ? "" : mermaid_lower(mermaid_firstword(first(statements)))
    kind in ("graph","flowchart") ? :flowchart : startswith(kind,"statediagram") ? :state :
        startswith(kind,"classdiagram") ? :class : kind=="erdiagram" ? :er : kind=="sequencediagram" ? :sequence : :unsupported
end
function mermaid_spaces(chars::Vector{Char},i::Int)
    while mermaid_char(chars,i) in (' ','\t')
        i+=1
    end
    i
end
function mermaid_shape(chars::Vector{Char},start::Int,closer::String,shape::Symbol)
    firstnonspace=mermaid_spaces(chars,start);quoted=mermaid_char(chars,firstnonspace)=='"'
    closing=collect(closer);i=start;buffer=IOBuffer();inside=false
    while i<=length(chars)
        c=chars[i]
        if quoted&&c=='"'
            inside=!inside;print(buffer,c);i+=1
        elseif !inside&&i+length(closing)-1<=length(chars)&&chars[i:i+length(closing)-1]==closing
            return (shape,label=mermaid_clean_label(String(take!(buffer))),next=i+length(closing),unclosed="")
        else
            print(buffer,c);i+=1
        end
    end
    (shape,label=mermaid_clean_label(String(take!(buffer))),next=i,unclosed=closer)
end
function mermaid_shape_at(chars::Vector{Char},i::Int)
    c=mermaid_char(chars,i);n=mermaid_char(chars,i+1)
    if c=='['
        n=='[' ? mermaid_shape(chars,i+2,"]]",:rect) : n=='(' ? mermaid_shape(chars,i+2,")]",:round) : mermaid_shape(chars,i+1,"]",:rect)
    elseif c=='('
        n=='(' ? mermaid_shape(chars,i+2,"))",:round) : n=='[' ? mermaid_shape(chars,i+2,"])",:round) : mermaid_shape(chars,i+1,")",:round)
    elseif c=='{'
        n=='{' ? mermaid_shape(chars,i+2,"}}",:diamond) : mermaid_shape(chars,i+1,"}",:diamond)
    elseif c=='>'
        mermaid_shape(chars,i+1,"]",:rect)
    else
        (shape=:rect,label=nothing,next=i,unclosed="")
    end
end
function mermaid_style_end(chars::Vector{Char},i::Int)
    if mermaid_char(chars,i)==':'&&mermaid_char(chars,i+1)==':'&&mermaid_char(chars,i+2)==':'
        k=i+3
        while mermaid_id(mermaid_char(chars,k))||mermaid_char(chars,k)=='-'
            k+=1
        end
        while k>i+3&&mermaid_char(chars,k-1)=='-'
            k-=1
        end
        k>i+3 ? k : i
    else
        i
    end
end
function mermaid_parse_node!(chars::Vector{Char},start::Int,graph::MermaidGraph)
    i=mermaid_spaces(chars,start);beginning=i
    while mermaid_id(mermaid_char(chars,i))
        i+=1
    end
    if i==beginning
        nothing
    else
        id=mermaid_slice(chars,beginning,i-1);shape=mermaid_shape_at(chars,i)
        isempty(shape.unclosed)||push!(graph.warnings,"node \"$id\": label is missing its closing `$(shape.unclosed)`")
        index=mermaid_node!(graph,id,shape.label,shape.shape)
        index==0 ? nothing : (index,next=mermaid_style_end(chars,shape.next))
    end
end
function mermaid_parse_node_group!(chars::Vector{Char},start::Int,graph::MermaidGraph)
    first=mermaid_parse_node!(chars,start,graph)
    isnothing(first)&&return nothing
    group=Int[first.index];i=first.next
    while true
        j=mermaid_spaces(chars,i)
        mermaid_char(chars,j)=='&'||break
        next=mermaid_parse_node!(chars,j+1,graph)
        isnothing(next)&&return nothing
        push!(group,next.index);i=next.next
    end
    (;group,next=i)
end
mermaid_linkchar(c::Char)=c in ('-','.','=','<','>')
mermaid_linekind(op::AbstractString)=occursin('=',op) ? :thick : occursin('.',op) ? :dotted : :solid
function mermaid_trailing_head(chars::Vector{Char},i::Int)
    head=mermaid_char(chars,i)=='o' ? :circle : mermaid_char(chars,i)=='x' ? :cross : :none
    head!=:none&&mermaid_char(chars,i+1) in ('\0',' ','\t','|','&',';') ? (head,next=i+1) : nothing
end
function mermaid_parse_link(chars::Vector{Char},start::Int)
    i=mermaid_spaces(chars,start);left=:none
    if mermaid_char(chars,i) in ('o','x')&&mermaid_char(chars,i+1) in ('-','.','=')
        left=chars[i]=='o' ? :circle : :cross;i+=1
    end
    beginning=i
    while mermaid_linkchar(mermaid_char(chars,i))
        i+=1
    end
    i==beginning&&return nothing
    op=mermaid_slice(chars,beginning,i-1)
    left==:none&&startswith(op,"<")&&(left=:arrow)
    line=mermaid_linekind(op);right=occursin('>',op) ? :arrow : :none
    trailing=right==:none ? mermaid_trailing_head(chars,i) : nothing
    if !isnothing(trailing)
        right=trailing.head;i=trailing.next
    end
    if mermaid_char(chars,i)=='|'
        i+=1;beginning=i
        while i<=length(chars)&&chars[i]!='|'
            i+=1
        end
        label=mermaid_nonempty(mermaid_clean_label(mermaid_slice(chars,beginning,i-1)))
        mermaid_char(chars,i)=='|'&&(i+=1)
        return (left,right,line,label,next=i)
    end
    if right==:none
        beginning=mermaid_spaces(chars,i);j=beginning
        while j<=length(chars)&&!mermaid_linkchar(chars[j])
            j+=1
        end
        if j<=length(chars)&&j>beginning&&chars[j]!='<'
            text=mermaid_slice(chars,beginning,j-1);opstart=j
            while mermaid_linkchar(mermaid_char(chars,j))
                j+=1
            end
            op2=mermaid_slice(chars,opstart,j-1)
            if occursin('>',op2)
                right=:arrow
            else
                trailing=mermaid_trailing_head(chars,j)
                if !isnothing(trailing)
                    right=trailing.head;j=trailing.next
                end
            end
            line==:solid&&(line=mermaid_linekind(op2))
            return (left,right,line,label=mermaid_nonempty(mermaid_clean_label(text)),next=j)
        end
    end
    (left,right,line,label=nothing,next=i)
end
function mermaid_flow_statement!(statement::String,graph::MermaidGraph)
    chars=collect(statement);first=mermaid_parse_node_group!(chars,1,graph)
    if isnothing(first)
        push!(graph.warnings,"dropped, does not start with a node: \"$statement\"")
    else
        previous=first.group;i=first.next
        while true
            i=mermaid_spaces(chars,i);i>length(chars)&&break
            link=mermaid_parse_link(chars,i)
            if isnothing(link)
                push!(graph.warnings,"dropped, expected a link: \"$(mermaid_slice(chars,i))\"");break
            end
            target=mermaid_parse_node_group!(chars,mermaid_spaces(chars,link.next),graph)
            if isnothing(target)
                push!(graph.warnings,"dropped, link has no target: \"$statement\"");break
            end
            for from in previous,to in target.group
                reverse=link.left==:arrow&&link.right!=:arrow
                mermaid_edge!(graph,MermaidEdge(;from=reverse ? to : from,to=reverse ? from : to,label=link.label,
                    head_to=reverse ? :arrow : link.right,head_from=reverse ? link.right : link.left,line=link.line))||return nothing
            end
            previous=target.group;i=target.next
        end
    end
    nothing
end
function mermaid_subgraph(rest::String)
    if startswith(rest,"\"")
        close=findnext('"',rest,2)
        if !isnothing(close)
            label=String(SubString(rest,2,prevind(rest,close)))
            return label,mermaid_decode_entities(label)
        end
    end
    op=findfirst('[',rest)
    if !isnothing(op)
        id=String(mermaid_trim(SubString(rest,1,prevind(rest,op))))
        label=mermaid_clean_label(mermaid_trim(replace(SubString(rest,nextind(rest,op)),r"\]+$"=>"")))
        !isempty(id)&&!isempty(label)&&return (id,label)
    end
    rest,rest
end
function mermaid_parse_flow(statements::Vector{String})
    words=mermaid_words(first(statements));graph=MermaidGraph(;direction=mermaid_direction(length(words)>1 ? words[2] : "TB"));stack=Int[]
    for st in statements[2:end]
        keyword=mermaid_lower(mermaid_firstword(st))
        if keyword=="subgraph"
            length(graph.groups)>=MERMAID_MAX_GROUPS||length(stack)>=MERMAID_MAX_DEPTH ? (return nothing) : nothing
            id,label=mermaid_subgraph(String(mermaid_trim(chop(st;head=8,tail=0))))
            push!(graph.groups,MermaidGroup(;id,label,parent=isempty(stack) ? 0 : last(stack)))
            push!(stack,length(graph.groups));graph.current_group=last(stack)
        elseif keyword=="end"
            isempty(stack)||pop!(stack);graph.current_group=isempty(stack) ? 0 : last(stack)
        elseif keyword in ("classdef","class","style","linkstyle","click","direction")
            nothing
        else
            mermaid_flow_statement!(st,graph)
            graph.over_cap&&return nothing
        end
    end
    isempty(graph.nodes) ? nothing : graph
end
function mermaid_drop_styles(st::AbstractString)
    chars=collect(st);io=IOBuffer();i=1
    while i<=length(chars)
        next=mermaid_style_end(chars,i)
        if next>i
            i=next
        else
            print(io,chars[i]);i+=1
        end
    end
    String(take!(io))
end
