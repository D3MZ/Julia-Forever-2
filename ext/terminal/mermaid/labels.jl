# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
mermaid_strip_controls(s::AbstractString)=replace(String(s),r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]"=>"")
mermaid_lines(s::AbstractString)=[String(chopsuffix(line,"\r")) for line in split(chopsuffix(String(s),"\n"),'\n';keepempty=true)]

"""Use the pinned code-point width table and one shared grapheme measuring contract."""
function mermaid_codepoint_width(c::Char)
    point=UInt32(c);lo=1;hi=length(MERMAID_WIDTH_RUNS)
    while lo<=hi
        mid=(lo+hi)÷2;a,b,w=MERMAID_WIDTH_RUNS[mid]
        if point<a
            hi=mid-1
        elseif point>b
            lo=mid+1
        else
            return w
        end
    end
    1
end
function mermaid_cluster_width(cluster::AbstractString)
    width=0;variation=false;regional=0
    for c in cluster
        variation|=UInt32(c)==0xfe0f
        regional+=0x1f1e6<=UInt32(c)<=0x1f1ff
        width=max(width,mermaid_codepoint_width(c))
    end
    variation||regional>=2 ? 2 : width
end
mermaid_measured(s::AbstractString)=((String(g),mermaid_cluster_width(g)) for g in Base.Unicode.graphemes(s))
mermaid_width(s::AbstractString)=sum((w for (_,w) in mermaid_measured(s));init=0)

"""Decode only bounded entities into non-control Unicode scalar values."""
function mermaid_entity(body::String)
    named=get(Dict("lt"=>"<","gt"=>">","amp"=>"&","quot"=>"\"","apos"=>"'"),body,nothing)
    if !isnothing(named)
        named
    elseif startswith(body,"#")
        hex=startswith(body,"#x")||startswith(body,"#X")
        digits=chopprefix(body,hex ? first(body,2) : "#")
        valid=occursin(hex ? r"^[0-9a-fA-F]+$" : r"^[0-9]+$",digits)
        code=valid ? tryparse(UInt32,digits;base=hex ? 16 : 10) : nothing
        isnothing(code)||code>0x10ffff||0xd800<=code<=0xdfff||code<0x20||0x7f<=code<=0x9f ? nothing : string(Char(code))
    else
        nothing
    end
end
function mermaid_decode_entities(s::AbstractString)
    chars=collect(s);io=IOBuffer();i=1
    while i<=length(chars)
        decoded=nothing;semi=0
        if chars[i]=='&'
            for j in i+1:min(i+10,length(chars))
                if chars[j]==';'
                    semi=j;break
                end
            end
            semi>0&&(decoded=mermaid_entity(mermaid_slice(chars,i+1,semi-1)))
        end
        if isnothing(decoded)
            print(io,chars[i]);i+=1
        else
            print(io,decoded);i=semi+1
        end
    end
    String(take!(io))
end
const MERMAID_FORMAT_TAGS=Set(split("b strong i em u s strike del ins mark small big sub sup code kbd samp var tt span font q abbr cite pre"))
function mermaid_strip_html(s::AbstractString)
    replace(String(s),r"</?[0-9A-Za-z]+[^<>]*>"=>tag->begin
        matched=match(r"^</?([0-9A-Za-z]+)",tag)
        name=isnothing(matched) ? "" : lowercase(matched.captures[1])
        name=="br" ? " " : name in MERMAID_FORMAT_TAGS ? "" : String(tag)
    end)
end
function mermaid_unwrap(s::AbstractString,opener::AbstractString,closer::AbstractString)
    ncodeunits(s)>=ncodeunits(opener)+ncodeunits(closer)&&startswith(s,opener)&&endswith(s,closer) ? String(chopsuffix(chopprefix(s,opener),closer)) : nothing
end
function mermaid_strip_markdown(s::AbstractString)
    chars=collect(replace(String(s),"`"=>"","**"=>"","__"=>""))
    String(mermaid_trim(join(c for (i,c) in enumerate(chars) if !(c in ('*','_')) ||
        i>1&&i<length(chars)&&mermaid_alphanumeric(chars[i-1])&&mermaid_alphanumeric(chars[i+1]))))
end
function mermaid_clean_label(s::AbstractString)
    trimmed=String(mermaid_trim(mermaid_strip_html(mermaid_trim(s))))
    unquoted=something(mermaid_unwrap(trimmed,"\"","\""),mermaid_unwrap(trimmed,"'","'"),trimmed)
    unquoted=String(mermaid_trim(unquoted));markdown=mermaid_unwrap(unquoted,"`","`")
    mermaid_decode_entities(isnothing(markdown) ? unquoted : mermaid_strip_markdown(mermaid_trim(markdown)))
end
function mermaid_fit_label(label::AbstractString,width::Int)
    if mermaid_width(label)<=width
        String(label)
    else
        io=IOBuffer();used=0
        for (g,w) in mermaid_measured(label)
            used+w+1>width&&break
            print(io,g);used+=w
        end
        String(take!(io))*"…"
    end
end
function mermaid_wrap_label(label::AbstractString,width::Int=24,maxlines::Int=4)
    width=max(1,width);lines=String[];cur="";used=0
    for word in mermaid_words(label)
        w=mermaid_width(word)
        if w>width
            isempty(cur)||push!(lines,cur)
            cur="";parts=String[];cw=0
            for (g,gw) in mermaid_measured(word)
                if cw+gw>width&&!isempty(parts)
                    chunk=join(parts)
                    boundary=findlast(c->c in ('_','-','.','/'),chunk)
                    carry=isnothing(boundary) ? "" : String(SubString(chunk,nextind(chunk,boundary)))
                    push!(lines,isnothing(boundary) ? chunk : String(SubString(chunk,1,boundary)))
                    empty!(parts);isempty(carry)||push!(parts,carry);cw=mermaid_width(carry)
                end
                push!(parts,g);cw+=gw
            end
            cur=join(parts);used=cw
        elseif isempty(cur)
            cur=String(word);used=w
        elseif used+1+w<=width
            cur*=" "*word;used+=1+w
        else
            push!(lines,cur);cur=String(word);used=w
        end
    end
    isempty(cur)||push!(lines,cur)
    isempty(lines)&&push!(lines,"")
    if length(lines)>maxlines
        resize!(lines,maxlines)
        io=IOBuffer();used=0
        for (g,w) in mermaid_measured(last(lines))
            used+w>max(1,width-1)&&break
            print(io,g);used+=w
        end
        lines[end]=String(take!(io))*"…"
    end
    lines
end
function mermaid_generics(s::AbstractString)
    io=IOBuffer();opened=false
    for c in s
        if c=='~'
            print(io,opened ? '>' : '<');opened=!opened
        else
            print(io,c)
        end
    end
    String(take!(io))
end
