const JF2_ISSUE_PAGE="https://github.com/D3MZ/Julia-Forever-2/issues/new"
const BUG_REPORT_LIMIT=32*1024*1024

"""Only explicitly selected report data enters a local bundle; credentials/settings are never read."""
struct LocalBugReport
    id::String
    created_at::String
    files::Vector{Pair{String,Vector{UInt8}}}
    transcript_included::Bool
    summary_included::Bool
end
function bug_report_bytes(text::AbstractString)
    plain=String(text)::String
    collect(codeunits(plain))
end
function bug_report_text(text::AbstractString,label::String,limit::Int)::String
    isvalid(text) && ncodeunits(text)<=limit || error("Bug report "*label*" exceeds bounds or is not UTF-8")
    String(text)
end

function local_bug_report(description::AbstractString;version::AbstractString=string(something(pkgversion(@__MODULE__),v"0.0.0")),provider=nothing,model=nothing,
        transcript::Union{Nothing,AbstractString}=nothing,summary::Union{Nothing,AbstractString}=nothing,
        id::AbstractString=string(uuid4()),created_at::AbstractString=timeline_timestamp())
    occursin(r"^[A-Za-z0-9-]{1,100}$",id) || error("Invalid report identity")
    hint=bug_report_text(description,"description",65536)
    version=bug_report_text(version,"version",128)
    metadata=Dict{String,Any}("format"=>"JuliaForever2.bug-report.v1","id"=>String(id),"createdAt"=>String(created_at),
        "application"=>"Julia Forever 2","version"=>version,"juliaVersion"=>string(VERSION),"os"=>string(Sys.KERNEL),"architecture"=>string(Sys.ARCH),
        "transcriptIncluded"=>!isnothing(transcript),"summaryIncluded"=>!isnothing(summary))
    for (key,value) in (("provider",provider),("model",model))
        if !isnothing(value)
            value isa AbstractString || error("Bug report model identity must be text")
            metadata[key]=bug_report_text(value,key,1024)
        end
    end
    report="# Julia Forever 2 bug report\n\n"*hint*"\n\nThis report was exported locally. It has not been uploaded or submitted.\n"*JF2_ISSUE_PAGE*"\n"
    files=Pair{String,Vector{UInt8}}["metadata.json"=>bug_report_bytes(JSON.json(metadata)*"\n"),"report.md"=>bug_report_bytes(report)]
    if !isnothing(summary)
        push!(files,"summary.md"=>bug_report_bytes(bug_report_text(summary,"summary",1024*1024)))
    end
    if !isnothing(transcript)
        push!(files,"session.jsonl"=>bug_report_bytes(bug_report_text(transcript,"transcript",BUG_REPORT_LIMIT-2*1024*1024)))
    end
    sum(file->length(last(file)),files)<=BUG_REPORT_LIMIT || error("Bug report bundle exceeds size limit")
    LocalBugReport(String(id),String(created_at),files,!isnothing(transcript),!isnothing(summary))
end

"""Compute ZIP's mandated IEEE CRC32 without executing an external archiver."""
function bug_report_crc(data::AbstractVector{UInt8})
    crc=typemax(UInt32)
    for byte in data
        crc=xor(crc,UInt32(byte))
        for bit in 1:8
            crc=(crc>>1) ⊻ (isodd(crc) ? UInt32(0xedb88320) : UInt32(0))
        end
    end
    ~crc
end
bug_report_u16(io::IO,value::Integer)=write(io,htol(UInt16(value)))
bug_report_u32(io::IO,value::Integer)=write(io,htol(UInt32(value)))

"""Create a bounded, standard stored ZIP with fixed safe member names and a verified central directory."""
function bug_report_zip(report::LocalBugReport)
    sum(file->length(last(file)),report.files)<=BUG_REPORT_LIMIT || error("Bug report bundle exceeds size limit")
    io=IOBuffer()
    directory=IOBuffer()
    names=Set{String}()
    allowed=Set(["metadata.json","report.md","summary.md","session.jsonl","issue.md"])
    for (name,bytes) in report.files
        name in allowed && !(name in names) || error("Unsafe or duplicate bug-report member")
        push!(names,name)
        length(bytes)<=BUG_REPORT_LIMIT || error("Bug-report member exceeds size bound")
        encoded=bug_report_bytes(name)
        offset=position(io)
        crc=bug_report_crc(bytes)
        bug_report_u32(io,0x04034b50)
        for value in (20,0,0,0,33);bug_report_u16(io,value);end
        for value in (crc,length(bytes),length(bytes));bug_report_u32(io,value);end
        bug_report_u16(io,length(encoded));bug_report_u16(io,0)
        write(io,encoded);write(io,bytes)
        bug_report_u32(directory,0x02014b50)
        for value in (20,20,0,0,0,33);bug_report_u16(directory,value);end
        for value in (crc,length(bytes),length(bytes));bug_report_u32(directory,value);end
        for value in (length(encoded),0,0,0,0);bug_report_u16(directory,value);end
        bug_report_u32(directory,0);bug_report_u32(directory,offset);write(directory,encoded)
    end
    start=position(io)
    central=take!(directory);write(io,central)
    bug_report_u32(io,0x06054b50)
    for value in (0,0,length(report.files),length(report.files));bug_report_u16(io,value);end
    bug_report_u32(io,length(central));bug_report_u32(io,start);bug_report_u16(io,0)
    result=take!(io)
    length(result)<=BUG_REPORT_LIMIT+65536 || error("Bug report ZIP exceeds size bound")
    result
end

"""Export an exclusive private file and read it back; existing user files are never overwritten."""
function export_bug_report!(report::LocalBugReport,path::AbstractString)
    bytes=bug_report_zip(report)
    expected=timeline_digest(bytes)
    timeline_replace_file(path,bytes,nothing)
    isfile(path) && !islink(path) && timeline_digest(read(path))==expected || error("Bug report archive readback failed")
    (;path=abspath(path),sha256=expected,bytes=length(bytes),id=report.id)
end
