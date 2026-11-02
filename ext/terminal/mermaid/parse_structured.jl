# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
function mermaid_state_decl!(st::String,graph::MermaidGraph)
    rest=String(mermaid_trim(replace(mermaid_trim(chop(st;head=5,tail=0)),r"\{$"=>"")))
    isempty(rest)&&return true
    if startswith(rest,"\"")
        close=findnext('"',rest,2)
        isnothing(close)&&return false
        label=String(SubString(rest,2,prevind(rest,close)));after=String(mermaid_trim(SubString(rest,nextind(rest,close))))
        id=startswith(after,"as") ? String(mermaid_trim(chop(after;head=2,tail=0))) : label
        mermaid_node_label!(graph,id,mermaid_decode_entities(label))>0
    else
        shape=:round;id=rest;stereotyped=false;parts=mermaid_splitonce(rest,"<<")
        if !isnothing(parts)
            stereo=mermaid_trim(replace(parts[2],r">>$"=>""));shape=stereo=="choice" ? :diamond : :round
            id=String(mermaid_trim(parts[1]));stereotyped=true
        end
        !isempty(id)&&!any(mermaid_space,id)&&mermaid_node!(graph,id,stereotyped ? id : nothing,shape)>0
    end
end
mermaid_state_endpoint!(g,id,source)=id=="[*]" ? mermaid_node!(g,source ? "[*]start" : "[*]end","●",:round) : mermaid_node!(g,id,nothing,:round)
function mermaid_state_transition!(st::String,graph::MermaidGraph)
    rest=st;previous=0
    while true
        parts=mermaid_splitonce(rest,"-->");isnothing(parts)&&break
        lhs,rhs=parts;fromid=String(mermaid_trim(replace(mermaid_rtrim(lhs),r"-+$"=>"")))
        from=previous
        if previous>0
            isempty(fromid)||return false
        else
            isempty(fromid)&&return false
            from=mermaid_state_endpoint!(graph,fromid,true);from==0&&return false
        end
        next=mermaid_splitonce(rhs,"-->")
        raw=isnothing(next) ? rhs : next[1];tail=isnothing(next) ? "" : "-->"*next[2]
        colon=mermaid_splitonce(raw,":");topart=isnothing(colon) ? raw : colon[1]
        label=isnothing(colon) ? nothing : mermaid_nonempty(mermaid_decode_entities(mermaid_trim(colon[2])))
        toid=String(mermaid_trim(replace(replace(mermaid_ltrim(topart),r"^>+"=>""),r"-+\s*$"=>"")))
        isempty(toid)&&return false
        to=mermaid_state_endpoint!(graph,toid,false);to==0&&return false
        mermaid_edge!(graph,MermaidEdge(;from,to,label))||return true
        previous=to;rest=tail
    end
    true
end
function mermaid_state_description!(st::String,graph::MermaidGraph)
    parts=mermaid_splitonce(st,":")
    if isnothing(parts)
        !any(mermaid_space,st)&&mermaid_node!(graph,st,nothing,:round)>0
    else
        id=mermaid_trim(parts[1]);description=mermaid_trim(parts[2])
        !isempty(id)&&!any(mermaid_space,id)&&!isempty(description)&&mermaid_node_label!(graph,id,mermaid_decode_entities(description))>0
    end
end
function mermaid_parse_state(statements::Vector{String})
    graph=MermaidGraph();note=false
    for raw in statements[2:end]
        if note
            mermaid_lower(raw)=="end note"&&(note=false)
            continue
        end
        st=mermaid_drop_styles(raw);first=mermaid_lower(mermaid_firstword(st))
        if first=="direction"
            words=mermaid_words(st);graph.direction=mermaid_direction(length(words)>1 ? words[2] : "")
        elseif first=="note"
            occursin(':',st)||(note=true)
        elseif first=="state"
            mermaid_state_decl!(st,graph)||return nothing
        elseif first in ("classdef","class","hide","scale","}","--")
            nothing
        elseif occursin("-->",st)
            mermaid_state_transition!(st,graph)||return nothing
        else
            mermaid_state_description!(st,graph)||return nothing
        end
        graph.over_cap&&return nothing
    end
    isempty(graph.nodes) ? nothing : graph
end
const MERMAID_CLASS_OPS=[("<|--",:triangle,:none,:solid),("--|>",:none,:triangle,:solid),
    ("<|..",:triangle,:none,:dotted),("..|>",:none,:triangle,:dotted),("*--",:diamondFill,:none,:solid),
    ("--*",:none,:diamondFill,:solid),("o--",:diamondOpen,:none,:solid),("--o",:none,:diamondOpen,:solid),
    ("<--",:arrow,:none,:solid),("-->",:none,:arrow,:solid),("<..",:arrow,:none,:dotted),
    ("..>",:none,:arrow,:dotted),("--",:none,:none,:solid),("..",:none,:none,:dotted)]
function mermaid_class_declare!(graph::MermaidGraph,infos::Vector{MermaidClass},name::AbstractString)
    index=mermaid_node!(graph,name)
    while length(infos)<length(graph.nodes)
        push!(infos,MermaidClass())
    end
    index
end
function mermaid_member!(info::MermaidClass,raw::String)
    if startswith(raw,"<<")
        parts=mermaid_splitonce(chop(raw;head=2,tail=0),">>")
        isnothing(parts)||(info.annotation=String(mermaid_trim(parts[1])))
    else
        member=mermaid_decode_entities(mermaid_generics(mermaid_trim(raw)))
        list=occursin('(',member) ? info.methods : info.attrs
        if length(list)<MERMAID_MAX_MEMBERS
            push!(list,member)
        elseif length(list)==MERMAID_MAX_MEMBERS
            push!(list,"…")
        end
    end
    nothing
end
function mermaid_cardinality(s::String,prefix::Bool)
    t=String(prefix ? mermaid_ltrim(s) : mermaid_rtrim(s))
    if prefix&&startswith(t,"\"")
        close=findnext('"',t,2)
        if !isnothing(close)
            return String(mermaid_ltrim(SubString(t,nextind(t,close)))),String(SubString(t,2,prevind(t,close)))
        end
    elseif !prefix&&endswith(t,"\"")
        rest=chop(t);open=findlast('"',rest)
        if !isnothing(open)
            return String(mermaid_rtrim(SubString(rest,1,prevind(rest,open)))),String(SubString(rest,nextind(rest,open)))
        end
    end
    t,""
end
function mermaid_class_relation(st::String)
    chars=collect(st)
    for position in eachindex(chars)
        tail=mermaid_slice(chars,position,min(length(chars),position+3))
        for (op,head_from,head_to,line) in MERMAID_CLASS_OPS
            startswith(tail,op)||continue
            startswith(op,"o")&&position>1&&mermaid_id(chars[position-1])&&continue
            endswith(op,"o")&&mermaid_id(mermaid_char(chars,position+length(op)))&&continue
            lhs,cardfrom=mermaid_cardinality(String(mermaid_trim(mermaid_slice(chars,1,position-1))),false)
            rhs,cardto=mermaid_cardinality(String(mermaid_trim(mermaid_slice(chars,position+length(op)))),true)
            parts=mermaid_splitonce(rhs,":");to=String(mermaid_trim(isnothing(parts) ? rhs : parts[1]))
            label=isnothing(parts) ? "" : mermaid_decode_entities(mermaid_trim(parts[2]))
            isempty(lhs)||isempty(to)||any(mermaid_space,lhs)||any(mermaid_space,to) ? (return nothing) : nothing
            return (from=lhs,to,head_from,head_to,line,label=mermaid_nonempty(join(filter(!isempty,[cardfrom,label,cardto])," ")))
        end
    end
    nothing
end
function mermaid_parse_class(statements::Vector{String})
    graph=MermaidGraph();infos=MermaidClass[];current=0
    for raw in statements[2:end]
        if current>0
            raw=="}" ? (current=0) : mermaid_member!(infos[current],raw)
            continue
        end
        st=mermaid_drop_styles(raw);first=mermaid_lower(mermaid_firstword(st))
        if first=="direction"
            words=mermaid_words(st);graph.direction=mermaid_direction(length(words)>1 ? words[2] : "")
        elseif first in ("note","callback","click","link","style","cssclass","classdef","namespace","}")
            nothing
        elseif first=="class"
            rest=String(mermaid_trim(chop(st;head=5,tail=0)));open=endswith(rest,"{")
            name=String(mermaid_trim(open ? chop(rest) : rest))
            isempty(name)||any(mermaid_space,name) ? (return nothing) : nothing
            index=mermaid_class_declare!(graph,infos,name);index==0&&return nothing
            open&&(current=index)
        elseif startswith(st,"<<")
            parts=mermaid_splitonce(chop(st;head=2,tail=0),">>");isnothing(parts)&&return nothing
            name=String(mermaid_trim(parts[2]));isempty(name)||any(mermaid_space,name) ? (return nothing) : nothing
            index=mermaid_class_declare!(graph,infos,name);index==0&&return nothing
            infos[index].annotation=String(mermaid_trim(parts[1]))
        else
            relation=mermaid_class_relation(st)
            if !isnothing(relation)
                from=mermaid_class_declare!(graph,infos,relation.from);to=mermaid_class_declare!(graph,infos,relation.to)
                from==0||to==0 ? (return nothing) : nothing
                mermaid_edge!(graph,MermaidEdge(;from,to,label=relation.label,head_from=relation.head_from,head_to=relation.head_to,line=relation.line))||return nothing
            else
                parts=mermaid_splitonce(st,":");isnothing(parts)&&return nothing
                id=String(mermaid_trim(parts[1]));text=String(mermaid_trim(parts[2]))
                isempty(id)||any(mermaid_space,id)||isempty(text) ? (return nothing) : nothing
                index=mermaid_class_declare!(graph,infos,id);index==0&&return nothing
                mermaid_member!(infos[index],text)
            end
        end
    end
    isempty(graph.nodes) ? nothing : (;graph,infos)
end
mermaid_er_card(s)=get(Dict("|o"=>"0..1","o|"=>"0..1","||"=>"1","}o"=>"0..*","o{"=>"0..*","}|"=>"1..*","|{"=>"1..*"),s,nothing)
function mermaid_er_op(token::String)
    ncodeunits(token)==6&&isascii(token)||return nothing
    line=token[3:4]=="--" ? :solid : token[3:4]==".." ? :dotted : :none
    left=mermaid_er_card(token[1:2]);right=mermaid_er_card(token[5:6])
    line==:none||isnothing(left)||isnothing(right) ? nothing : (;left,right,line)
end
function mermaid_er_entity!(graph::MermaidGraph,infos::Vector{MermaidClass},token::String)
    parts=mermaid_splitonce(token,"[")
    index=if isnothing(parts)
        mermaid_node!(graph,token)
    else
        id=parts[1];label=mermaid_clean_label(replace(parts[2],r"\]+$"=>""))
        isempty(id)||isempty(label) ? 0 : mermaid_node_label!(graph,id,label)
    end
    while length(infos)<length(graph.nodes)
        push!(infos,MermaidClass())
    end
    index
end
function mermaid_er_attribute!(info::MermaidClass,raw::String)
    parts=String[]
    for token in mermaid_words(raw)
        startswith(token,"\"")&&break
        push!(parts,token)
    end
    if !isempty(parts)
        line=mermaid_decode_entities(join(parts," "))
        if length(info.attrs)<MERMAID_MAX_MEMBERS
            push!(info.attrs,line)
        elseif length(info.attrs)==MERMAID_MAX_MEMBERS
            push!(info.attrs,"…")
        end
    end
    nothing
end
function mermaid_parse_er(statements::Vector{String})
    graph=MermaidGraph();infos=MermaidClass[];current=0
    for st in statements[2:end]
        if current>0
            st=="}" ? (current=0) : mermaid_er_attribute!(infos[current],st)
            continue
        end
        parts=mermaid_splitonce(st,":");rel=isnothing(parts) ? st : parts[1]
        words=mermaid_words(rel);relation=any(w->!isnothing(mermaid_er_op(w)),words)
        if relation
            length(words)==3||return nothing
            op=mermaid_er_op(words[2]);isnothing(op)&&return nothing
            from=mermaid_er_entity!(graph,infos,words[1]);to=mermaid_er_entity!(graph,infos,words[3])
            from==0||to==0 ? (return nothing) : nothing
            label=isnothing(parts) ? "" : mermaid_clean_label(mermaid_trim(parts[2]))
            mermaid_edge!(graph,MermaidEdge(;from,to,label=mermaid_nonempty(join(filter(!isempty,[op.left,label,op.right])," ")),head_to=:none,line=op.line))||return nothing
        else
            open=endswith(st,"{");decl=String(mermaid_trim(open ? chop(st) : st))
            isempty(decl)||length(mermaid_words(decl))!=1 ? (return nothing) : nothing
            index=mermaid_er_entity!(graph,infos,decl);index==0&&return nothing
            open&&(current=index)
        end
    end
    isempty(graph.nodes) ? nothing : (;graph,infos)
end
