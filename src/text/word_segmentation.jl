module WordSegmentation

import ICU_jll
import Libdl

"""Owned native ICU function handles are initialized only when dictionary segmentation is needed."""
struct Functions
    open::Ptr{Cvoid}
    next::Ptr{Cvoid}
    status::Ptr{Cvoid}
    close::Ptr{Cvoid}
    version::VersionNumber
end
const FUNCTIONS=Ref{Union{Nothing,Functions}}(nothing)
const FUNCTIONS_LOCK=ReentrantLock()

function __init__()
    FUNCTIONS[]=nothing
    nothing
end

function functions()
    lock(FUNCTIONS_LOCK) do
        cached=FUNCTIONS[]
        if isnothing(cached)
            version=Base.pkgversion(ICU_jll)::VersionNumber
            handle=ICU_jll.libicuuc_handle::Ptr{Cvoid}
            symbol(name)=Libdl.dlsym(handle,Symbol(name,"_",version.major))::Ptr{Cvoid}
            loaded=Functions(symbol("ubrk_open"),symbol("ubrk_next"),symbol("ubrk_getRuleStatus"),symbol("ubrk_close"),version)
            FUNCTIONS[]=loaded
            loaded
        else
            cached
        end
    end
end

"""Use ICU word boundaries and word-like rule status with owned UTF-16 backing storage."""
function segments(text::AbstractString)
    # Track UTF-8 boundary indices with ICU's UTF-16 and character offsets.
    # This avoids re-traversing the entire source for each word's substring.
    source=String(text)
    api=functions();utf16=transcode(UInt16,source);errorcode=Ref{Cint}(0)
    result=NamedTuple{(:text,:start,:stop,:word),Tuple{String,Int,Int,Bool}}[]
    GC.@preserve utf16 begin
        iterator=ccall(api.open,Ptr{Cvoid},(Cint,Cstring,Ptr{UInt16},Cint,Ref{Cint}),1,"en-US",utf16,length(utf16),errorcode)
        if iterator==C_NULL || errorcode[]>0
            iterator!=C_NULL && ccall(api.close,Cvoid,(Ptr{Cvoid},),iterator)
            error("Native ICU word iterator unavailable (status $(errorcode[]))")
        else
            offsets=Dict{Int,Tuple{Int,Int}}(0=>(0,firstindex(source)))
            units=0;after=firstindex(source)
            for (index,char) in enumerate(source)
                units+=Int(char)>0xffff ? 2 : 1
                after=nextind(source,after)
                offsets[units]=(index,after)
            end
            final=(length(source),ncodeunits(source)+1)
            previous=0;next=ccall(api.next,Cint,(Ptr{Cvoid},),iterator)
            while next!=-1
                status=ccall(api.status,Cint,(Ptr{Cvoid},),iterator)
                start,first_byte=get(offsets,previous,(0,firstindex(source)))
                stop,last_byte=get(offsets,Int(next),final)
                word=first_byte==last_byte ? "" :
                    String(SubString(source,first_byte,prevind(source,last_byte)))
                push!(result,(text=word,start,stop,word=status>=100))
                previous=next;next=ccall(api.next,Cint,(Ptr{Cvoid},),iterator)
            end
            ccall(api.close,Cvoid,(Ptr{Cvoid},),iterator)
        end
    end
    result
end


end
