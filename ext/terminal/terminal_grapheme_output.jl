public GraphemeFrameResult, fullscreen_grapheme_frame

"""Report a complete-frame rewrite without disguising unsupported packets as corrected output."""
Base.@kwdef struct GraphemeFrameResult
    text::String
    status::Symbol = :unchanged
    corrections::Int = 0
    reason::String = ""
end

Base.@kwdef mutable struct GraphemeFrameCursor
    row::Int = 0
    column::Int = 0
    pending::Bool = false
end

"""Resolve the producer's absolute cursor coordinates without executing terminal input."""
function grapheme_frame_position(parameters::String,width::Int,height::Int)
    fields=split(parameters,';';keepempty=true)
    values=[isempty(field) ? 1 : something(tryparse(Int,field),0) for field in fields]
    if isempty(parameters)
        (ok=true,row=1,column=1)
    elseif length(values)==2 && 1<=values[1]<=height && 1<=values[2]<=width
        (ok=true,row=values[1],column=values[2])
    else
        (ok=false,row=0,column=0)
    end
end

"""Accept only the non-moving CSI forms emitted by the owned framebuffer serializer."""
grapheme_frame_stationary(parameters::String,final::UInt8)=
    final==0x6d && all(character->'0'<=character<='9'||character in (';',':'),parameters) ||
    final==0x4a && parameters in ("","0","1","2","3") ||
    final==0x4b && parameters in ("","0","1","2")

function grapheme_frame_csi!(cursor::GraphemeFrameCursor,text::String,start::Int,limit::Int,width::Int,height::Int)
    bytes=codeunits(text);stop=start+2
    while stop<=limit && !(0x40<=bytes[stop]<=0x7e)
        stop+=1
    end
    reason=""
    if stop>limit
        reason="Truncated CSI packet"
    else
        parameters=String(bytes[start+2:stop-1]);final=bytes[stop]
        if final in (0x48,0x66)
            position=grapheme_frame_position(parameters,width,height)
            if position.ok
                cursor.row=position.row;cursor.column=position.column;cursor.pending=false
            else
                reason="Unsupported cursor position"
            end
        elseif !grapheme_frame_stationary(parameters,final)
            reason="Unsupported CSI packet"
        end
    end
    (;stop,reason)
end

"""Preserve opaque links, graphics and string controls byte-for-byte, including their terminators."""
function grapheme_frame_string!(cursor::GraphemeFrameCursor,text::String,start::Int,limit::Int)
    bytes=codeunits(text);kind=bytes[start+1];stop=start+2;complete=false
    while stop<=limit && !complete
        if kind==0x5d && bytes[stop]==0x07
            complete=true
        elseif stop<limit && bytes[stop]==0x1b && bytes[stop+1]==0x5c
            stop+=1;complete=true
        else
            stop+=1
        end
    end
    if kind!=0x5d
        cursor.row=0;cursor.column=0;cursor.pending=false
    end
    (stop=stop,reason=complete ? "" : "Unterminated string control")
end

function grapheme_frame_escape!(cursor::GraphemeFrameCursor,text::String,start::Int,limit::Int,width::Int,height::Int)
    bytes=codeunits(text)
    if start>=limit
        (stop=start,reason="Truncated escape packet")
    elseif bytes[start+1]==0x5b
        grapheme_frame_csi!(cursor,text,start,limit,width,height)
    elseif bytes[start+1] in (0x5d,0x5f,0x50,0x5e,0x58)
        grapheme_frame_string!(cursor,text,start,limit)
    else
        (stop=start,reason="Unsupported escape packet")
    end
end

"""Insert a cursor address only when the framework would otherwise trust a mismatched width."""
function grapheme_frame_printable!(insertions::Vector{Pair{Int,String}},cursor::GraphemeFrameCursor,text::String,start::Int,stop::Int,width::Int,height::Int)
    part=SubString(text,start,prevind(text,stop));offset=start;reason=""
    if isascii(part)
        if cursor.pending && cursor.row>0
            if 1<=cursor.row<=height && 1<=cursor.column<=width
                push!(insertions,start=>string("\e[",cursor.row,";",cursor.column,"H"))
            else
                reason="Producer cursor lies outside the frame"
            end
        end
        cursor.column+=ncodeunits(part);cursor.pending=false
    else
        for glyph in Base.Unicode.graphemes(part)
            if any(iscntrl,glyph)
                reason="Unexpected Unicode control outside a string packet"
            elseif cursor.pending && cursor.row>0 && isempty(reason)
                if 1<=cursor.row<=height && 1<=cursor.column<=width
                    push!(insertions,offset=>string("\e[",cursor.row,";",cursor.column,"H"))
                else
                    reason="Producer cursor lies outside the frame"
                end
            end
            producer=max(1,textwidth(glyph))
            cursor.column+=producer
            cursor.pending=ncodeunits(glyph)>1 && menu_search_grapheme_width(glyph)!=producer
            offset+=ncodeunits(glyph)
        end
    end
    reason
end

function grapheme_frame_scan(text::String,width::Int,height::Int)
    bytes=codeunits(text);limit=ncodeunits(text)-8;index=9
    cursor=GraphemeFrameCursor();insertions=Pair{Int,String}[];reason=""
    while index<=limit && isempty(reason)
        if bytes[index]==0x1b
            result=grapheme_frame_escape!(cursor,text,index,limit,width,height)
            reason=result.reason;index=result.stop+1
        elseif bytes[index]<0x20 || bytes[index]==0x7f
            reason="Unexpected control outside a string packet"
        else
            stop=index
            while stop<=limit && bytes[stop]>=0x20 && bytes[stop]!=0x7f
                stop+=1
            end
            reason=grapheme_frame_printable!(insertions,cursor,text,index,stop,width,height)
            index=stop
        end
    end
    (;insertions,reason)
end

"""Rewrite only complete owned synchronized frames; every unrecognized input is returned unchanged."""
function fullscreen_grapheme_frame(text::String;width::Int,height::Int,max_bytes::Int=16_777_216)
    result=GraphemeFrameResult(;text)
    if width<=0 || height<=0 || max_bytes<0
        result=GraphemeFrameResult(;text,status=:unsupported,reason="Invalid frame geometry or byte limit")
    elseif !(startswith(text,"\e[?2026h")&&endswith(text,"\e[?2026l")) || ncodeunits(text)<16
        result=GraphemeFrameResult(;text,status=:unsupported,reason="Not one complete synchronized frame")
    elseif ncodeunits(text)>max_bytes || !isvalid(text)
        result=GraphemeFrameResult(;text,status=:unsupported,reason="Frame exceeds byte limit or contains invalid UTF-8")
    elseif !isascii(text)
        scanned=grapheme_frame_scan(text,width,height)
        if !isempty(scanned.reason)
            result=GraphemeFrameResult(;text,status=:unsupported,reason=scanned.reason)
        elseif !isempty(scanned.insertions)
            output=sprint() do io
                position=1
                for (offset,packet) in scanned.insertions
                    write(io,codeunits(text)[position:offset-1]);write(io,packet);position=offset
                end
                write(io,codeunits(text)[position:end])
            end
            result=GraphemeFrameResult(;text=output,status=:corrected,corrections=length(scanned.insertions))
        end
    end
    result
end
