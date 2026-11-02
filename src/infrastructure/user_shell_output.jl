module UserShellOutput

"""Decode fragmented UTF-8 with replacement semantics and a single optional leading BOM."""
Base.@kwdef mutable struct Decoder
    pending::Vector{UInt8}=UInt8[]
    beginning::Bool=true
end
utf8_width(byte::UInt8)=byte<0x80 ? 1 : 0xc2<=byte<=0xdf ? 2 : 0xe0<=byte<=0xef ? 3 : 0xf0<=byte<=0xf4 ? 4 : 0
utf8_continuation(lead::UInt8,byte::UInt8,index::Int)=0x80<=byte<=0xbf &&
    (index!=2 || (lead!=0xe0 || byte>=0xa0) && (lead!=0xed || byte<=0x9f) && (lead!=0xf0 || byte>=0x90) && (lead!=0xf4 || byte<=0x8f))
function decoded_character!(io::IO,decoder::Decoder,point::UInt32)
    decoder.beginning && point==0xfeff || print(io,Char(point))
    decoder.beginning=false
    nothing
end
function decode!(decoder::Decoder,bytes::AbstractVector{UInt8};final::Bool=false)
    append!(decoder.pending,bytes)
    data=decoder.pending;index=1;io=IOBuffer()
    while index<=length(data)
        lead=data[index];width=utf8_width(lead);valid=1
        while width>1 && valid<width && index+valid<=length(data) && utf8_continuation(lead,data[index+valid],valid+1)
            valid+=1
        end
        incomplete=width>1 && valid<width && index+valid>length(data)
        if incomplete && !final
            break
        elseif width==0 || valid<width
            decoded_character!(io,decoder,UInt32(0xfffd));index+=valid
        else
            point=UInt32(width==1 ? lead : lead & (0x7f>>width))
            for offset in 1:width-1
                point=(point<<6)|UInt32(data[index+offset]&0x3f)
            end
            decoded_character!(io,decoder,point);index+=width
        end
    end
    index>1 && deleteat!(data,1:index-1)
    String(take!(io))
end

# The ANSI-recognition expressions are adapted from Pi's test-pinned ANSI utility,
# derived from ansi-regex and strip-ansi (MIT), copyright Sindre Sorhus.
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
const ANSI_STOP="(?:\\x07|\\x1b\\\\|\u009c)"
const ANSI_START="(?:(?:\\x1b\\[|\u009b)[<=>]|[\\x1b\u009b][[\\]()#;?]*)(?:\\d{1,4}(?:[;:]\\d{0,4})*)?"
const ANSI_COMPLETE=Regex("(?:\\x1b\\][\\s\\S]*?"*ANSI_STOP*")|"*ANSI_START*"[\\dA-PR-TZcf-nq-uy=><~]")
const ANSI_INCOMPLETE=Regex("(?:\\x1b\\](?:[^\\x07\u009c\\x1b]|\\x1b(?!\\\\))*|"*ANSI_START*")\$")
utf16_length(text::String)=sum(ch->UInt32(ch)>0xffff ? 2 : 1,text;init=0)
function ansi_suffix(text::String)
    chars=collect(text);units=0;start=length(chars)+1
    while start>1 && units<256
        start-=1;units+=UInt32(chars[start])>0xffff ? 2 : 1
    end
    prefix=join(chars[1:start-1]);window=join(chars[start:end]);matched=match(ANSI_INCOMPLETE,window)
    if isnothing(matched)
        (complete=text,pending="")
    else
        split=matched.offset
        (complete=prefix*String(SubString(window,1,prevind(window,split))),pending=String(SubString(window,split)))
    end
end
shell_character(ch::Char)=!(UInt32(ch)<=8 || UInt32(ch) in (11,12,13) || 14<=UInt32(ch)<=31 || 0xfff9<=UInt32(ch)<=0xfffb)
sanitize(text::String)=String(filter(shell_character,replace(text,ANSI_COMPLETE=>"")))

"""Retain the original final-line semantics without splitting UTF-8 codepoints."""
function truncate_tail(text::String;max_lines::Int=2000,max_bytes::Int=50*1024)
    max_lines>=0 && max_bytes>=0 || error("Shell output limits must be nonnegative")
    lines=isempty(text) ? String[] : String.(split(text,'\n';keepempty=true))
    !isempty(lines) && endswith(text,'\n') && pop!(lines)
    total_bytes=ncodeunits(text);total_lines=length(lines)
    content=text;truncated=total_lines>max_lines || total_bytes>max_bytes;by=nothing;partial=false;output_lines=total_lines
    if truncated
        kept=String[];count=0;by="lines"
        for line in Iterators.take(Iterators.reverse(lines),max_lines)
            bytes=ncodeunits(line)+(isempty(kept) ? 0 : 1)
            if count+bytes>max_bytes
                by="bytes"
                if isempty(kept)
                    start=max(1,ncodeunits(line)-max_bytes+1)
                    while start<=ncodeunits(line) && !isvalid(line,start)
                        start+=1
                    end
                    pushfirst!(kept,String(SubString(line,start)));partial=true
                end
                break
            else
                pushfirst!(kept,line);count+=bytes
            end
        end
        length(kept)>=max_lines && count<=max_bytes && (by="lines")
        content=join(kept,'\n');output_lines=length(kept)
    end
    (content,truncated,truncatedBy=by,totalLines=total_lines,totalBytes=total_bytes,
        outputLines=output_lines,
        outputBytes=ncodeunits(content),lastLinePartial=partial,firstLineExceedsLimit=false,maxLines=max_lines,maxBytes=max_bytes)
end

"""Own bounded sanitized streaming memory and an optional private full-output spill file."""
Base.@kwdef mutable struct Accumulator
    decoder::Decoder=Decoder()
    pending_ansi::String=""
    chunks::Vector{String}=String[]
    buffered_units::Int=0
    raw_bytes::Int=0
    directory::String=tempdir()
    path::Union{Nothing,String}=nothing
    stream::Union{Nothing,IOStream}=nothing
    closed::Bool=false
end
function spill!(state::Accumulator)
    if isnothing(state.path)
        path,stream=mktemp(state.directory;cleanup=false)
        chmod(path,0o600)
        state.path=path;state.stream=stream
        foreach(chunk->write(stream,chunk),state.chunks)
    end
    nothing
end
function append_text!(state::Accumulator,text::String)
    cleaned=sanitize(text)
    if !isempty(cleaned)
        state.raw_bytes>50*1024 && spill!(state)
        stream=state.stream
        isnothing(stream) || write(stream,cleaned)
        push!(state.chunks,cleaned);state.buffered_units+=utf16_length(cleaned)
        while state.buffered_units>100*1024 && length(state.chunks)>1
            state.buffered_units-=utf16_length(popfirst!(state.chunks))
        end
    end
    cleaned
end
function feed!(state::Accumulator,bytes::AbstractVector{UInt8})
    state.closed && error("Shell output accumulator is closed")
    state.raw_bytes+=length(bytes)
    suffix=ansi_suffix(state.pending_ansi*decode!(state.decoder,bytes))
    state.pending_ansi=suffix.pending
    append_text!(state,suffix.complete)
end
function finish!(state::Accumulator)
    state.closed && error("Shell output accumulator is closed")
    tail=append_text!(state,state.pending_ansi*decode!(state.decoder,UInt8[];final=true));state.pending_ansi=""
    result=truncate_tail(join(state.chunks))
    result.truncated && spill!(state)
    stream=state.stream
    isnothing(stream) || close(stream)
    state.closed=true
    (output=result.content,truncated=result.truncated,full_output_path=state.path,final_chunk=tail)
end
function close!(state::Accumulator)
    stream=state.stream
    isnothing(stream) || isopen(stream) && close(stream)
    state.closed=true
    nothing
end
end
