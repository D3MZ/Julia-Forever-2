# Native token boundaries mirror pinned Pi Markdown's terminal-math extension (MIT).
struct SessionMathToken
    raw::String
    text::String
    pending::Bool
    block::Bool
end
session_math_pending(source::String)=occursin(r"\\[A-Za-z]+|[_^=+*/<>()[\]|±≤≥≠≈∈→⇒∞∫∑√-]",source)
function session_math_escaped(source::String,index::Int)
    slashes=0;position=prevind(source,index)
    while position>=firstindex(source)&&source[position]=='\\'
        slashes+=1;position=prevind(source,position)
    end
    isodd(slashes)
end
function session_math_closing(source::String,closing::String,start::Int)
    found=findnext(closing,source,start)
    while !isnothing(found)&&session_math_escaped(source,first(found))
        found=findnext(closing,source,nextind(source,last(found)))
    end
    found
end
function session_math_inline_token(source::String)
    opening,closing=if startswith(source,"\$\$")
        ("\$\$","\$\$")
    elseif startswith(source,"\\(")
        ("\\(","\\)")
    elseif startswith(source,"\\[")
        ("\\[","\\]")
    elseif startswith(source,'\$')&&!occursin(r"^\$\s",source)
        ("\$","\$")
    else
        ("","")
    end
    if isempty(opening)
        nothing
    else
        start=ncodeunits(opening)+1;ending=session_math_closing(source,closing,start)
        if isnothing(ending)
            text=String(SubString(source,start))
            startswith(opening,'\\')||session_math_pending(text) ? SessionMathToken(source,text,true,false) : nothing
        else
            text=first(ending)==start ? "" : String(SubString(source,start,prevind(source,first(ending))))
            tail=String(SubString(source,nextind(source,last(ending))))
            invalid=opening=="\$"&&(occursin(r"\s$",text)||occursin(r"^\d",tail)||occursin(r"^[A-Z_][A-Z0-9_]*(?:[^A-Za-z0-9_\s])?$",text)&&occursin(r"^[A-Za-z_][A-Za-z0-9_]*",tail)||occursin('`',text))
            if invalid||isempty(text)||occursin('\n',text)
                nothing
            else
                SessionMathToken(String(SubString(source,firstindex(source),last(ending))),text,false,false)
            end
        end
    end
end
function session_math_contains_table(source::String)
    lines=split(source,'\n';keepempty=true)
    any(index->(occursin('|',lines[index+1])||occursin('|',lines[index]))&&occursin(r"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$",lines[index+1]),1:length(lines)-1)
end
function session_math_block_token(source::String)
    patterns=((r"^ {0,3}\$\$[ \t]*(?:\n)?([\s\S]*?)\$\$[ \t]*(?:\n|$)",false,false),(r"^ {0,3}\\\[[ \t]*(?:\n)?([\s\S]*?)\\\][ \t]*(?:\n|$)",false,false),(r"^ {0,3}\\\[[ \t]*(?:\n)?([\s\S]*)$",true,false),(r"^ {0,3}\$\$[ \t]*(?:\n)?([\s\S]*)$",true,true))
    token=nothing
    for (pattern,pending,require_math) in patterns
        if isnothing(token)
            found=match(pattern,source);capture=isnothing(found) ? nothing : only(found.captures)
            if !isnothing(found)&&!isnothing(capture)&&!isempty(capture)&&!session_math_contains_table(String(capture))&&(!require_math||session_math_pending(String(capture)))
                token=SessionMathToken(String(found.match),pending ? String(capture) : String(strip(capture)),pending,true)
            end
        end
    end
    token
end
