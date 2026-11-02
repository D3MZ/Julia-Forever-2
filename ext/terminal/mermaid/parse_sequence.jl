# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
const MERMAID_SEQUENCE_OPS=[("-->>",true,:arrow),("->>",false,:arrow),("--x",true,:cross),("-x",false,:cross),
    ("--)",true,:arrow),("-)",false,:arrow),("-->",true,:arrow),("->",false,:arrow)]
function mermaid_sequence_message(st::String,sequence::MermaidSequence)
    chars=collect(st)
    for position in eachindex(chars)
        tail=mermaid_slice(chars,position,min(length(chars),position+3))
        for (op,dashed,head) in MERMAID_SEQUENCE_OPS
            startswith(tail,op)||continue
            fromid=String(mermaid_trim(mermaid_slice(chars,1,position-1)));isempty(fromid)&&return nothing
            rest=replace(mermaid_ltrim(mermaid_slice(chars,position+length(op))),r"^[+-]+"=>"")
            parts=mermaid_splitonce(rest,":");toid=String(mermaid_trim(isnothing(parts) ? rest : parts[1]))
            isempty(toid)&&return nothing
            text=isnothing(parts) ? nothing : mermaid_nonempty(mermaid_decode_entities(mermaid_trim(parts[2])))
            from=mermaid_participant!(sequence,fromid);to=mermaid_participant!(sequence,toid)
            from==0||to==0 ? (return nothing) : nothing
            return MermaidSequenceItem(;kind=:message,from,to,text,dashed,head)
        end
    end
    nothing
end
function mermaid_sequence_note(rest::String,sequence::MermaidSequence)
    lower=mermaid_lower(rest)
    anchor,prefix=startswith(lower,"over ") ? (:over,5) : startswith(lower,"left of ") ? (:left,8) : startswith(lower,"right of ") ? (:right,9) : (:none,0)
    anchor==:none&&return nothing
    parts=mermaid_splitonce(chop(rest;head=prefix,tail=0),":");isnothing(parts)&&return nothing
    ids=filter(!isempty,mermaid_trim.(split(parts[1],',')));isempty(ids)&&return nothing
    from=mermaid_participant!(sequence,ids[1]);from==0&&return nothing
    to=anchor==:over&&length(ids)>1 ? mermaid_participant!(sequence,ids[2]) : from
    to==0&&return nothing
    MermaidSequenceItem(;kind=:note,from=min(from,to),to=max(from,to),text=mermaid_decode_entities(mermaid_trim(parts[2])),anchor)
end
function mermaid_parse_sequence(statements::Vector{String})
    sequence=MermaidSequence();autonumber=false;count=0;blocks=Bool[]
    for st in statements[2:end]
        word=mermaid_firstword(st);first=mermaid_lower(word)
        if first in ("participant","actor")
            rest=String(mermaid_trim(chop(st;head=length(word),tail=0)));isempty(rest)&&return nothing
            parts=mermaid_splitonce(rest," as ")
            mermaid_participant!(sequence,isnothing(parts) ? rest : mermaid_trim(parts[1]),isnothing(parts) ? nothing : mermaid_clean_label(parts[2]))==0&&return nothing
        elseif first=="autonumber"
            autonumber=true
        elseif first in ("activate","deactivate","create","destroy","title","acctitle","accdescr","links","link","properties")
            nothing
        elseif first=="note"
            note=mermaid_sequence_note(String(mermaid_trim(chop(st;head=length(word),tail=0))),sequence)
            isnothing(note)&&return nothing
            length(sequence.items)>=MERMAID_MAX_EDGES&&return nothing
            push!(sequence.items,note)
        elseif first in ("loop","alt","opt","par","critical","break","else","and","option")
            if first in ("else","and","option")
                (isempty(blocks)||!last(blocks))&&continue
            else
                length(blocks)>=MERMAID_MAX_EDGES&&return nothing
                push!(blocks,true)
            end
            length(sequence.items)>=MERMAID_MAX_EDGES&&return nothing
            push!(sequence.items,MermaidSequenceItem(;kind=:divider,text=mermaid_decode_entities(st)))
        elseif first in ("rect","box")
            length(blocks)>=MERMAID_MAX_EDGES&&return nothing
            push!(blocks,false)
        elseif first=="end"
            if !isempty(blocks)&&pop!(blocks)
                length(sequence.items)>=MERMAID_MAX_EDGES&&return nothing
                push!(sequence.items,MermaidSequenceItem(;kind=:divider,text="end"))
            end
        else
            message=mermaid_sequence_message(st,sequence);isnothing(message)&&return nothing
            length(sequence.items)>=MERMAID_MAX_EDGES&&return nothing
            if autonumber
                count+=1;text=string(count,".")*(isnothing(message.text) ? "" : " "*message.text)
                message=MermaidSequenceItem(;kind=:message,from=message.from,to=message.to,text,dashed=message.dashed,head=message.head)
            end
            push!(sequence.items,message)
        end
    end
    isempty(sequence.labels) ? nothing : sequence
end
