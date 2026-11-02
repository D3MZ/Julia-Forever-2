using Downloads

const JF2_RELEASES_API="https://api.github.com/repos/D3MZ/Julia-Forever-2/releases"
const JF2_RELEASES_PAGE="https://github.com/D3MZ/Julia-Forever-2/releases"
const RELEASE_RESPONSE_LIMIT=2*1024*1024

"""Explicit authorization for one public, credential-free release-note refresh."""
Base.@kwdef struct ReleaseFetchPolicy
    allow_network::Bool = false
    response_limit::Int = RELEASE_RESPONSE_LIMIT
    maximum_pages::Int = 10
    timeout::Float64 = 30.0
end
struct ReleaseNote
    tag::String
    title::String
    published_at::String
    body::String
    url::String
end
struct ReleaseChangelog
    source::String
    checked_at::String
    entries::Vector{ReleaseNote}
end

mutable struct ReleaseResponseBuffer <: IO
    buffer::IOBuffer
    limit::Int
end
Base.isopen(buffer::ReleaseResponseBuffer)=isopen(buffer.buffer)
Base.iswritable(::ReleaseResponseBuffer)=true
Base.close(buffer::ReleaseResponseBuffer)=close(buffer.buffer)
function Base.unsafe_write(buffer::ReleaseResponseBuffer,pointer::Ptr{UInt8},count::UInt)
    if count>UInt(buffer.limit) || position(buffer.buffer)>buffer.limit-Int(count)
        error("Public release response exceeds the configured limit")
    end
    Base.unsafe_write(buffer.buffer,pointer,count)
end

"""Request only the fixed HTTPS endpoint, without credentials or redirects to linked hosts."""
function public_release_transport(url::AbstractString,context::ExecutionContext,policy::ReleaseFetchPolicy)
    expected=Regex("^"*replace(JF2_RELEASES_API,"."=>"\\.")*"\\?per_page=100&page=[1-9][0-9]*\$")
    occursin(expected,url) || error("Release endpoint is not authorized")
    downloader=Downloads.Downloader()
    downloader.easy_hook=(easy,info)->Downloads.Curl.setopt(easy,Downloads.Curl.CURLOPT_FOLLOWLOCATION,false)
    sink=ReleaseResponseBuffer(IOBuffer(),policy.response_limit)
    interrupt=Base.Event()
    register_cancellation!(context,interrupt;owned=false)
    ownership=own_resource!(context,interrupt;cleanup=event->unregister_cancellation!(context,event))
    response=Downloads.request(url;method="GET",headers=["Accept"=>"application/vnd.github+json","User-Agent"=>"Julia-Forever-2-changelog"],output=sink,
        downloader,timeout=min(policy.timeout,remaining_time(context)),interrupt,throw=false)
    release!(ownership)
    HTTPTransport.response_result(response,String(take!(sink.buffer)))
end

function release_text(value,label::AbstractString;limit::Int=RELEASE_RESPONSE_LIMIT)
    value isa AbstractString || error("Release "*label*" must be text")
    ncodeunits(value)<=limit && isvalid(value) || error("Release "*label*" exceeds bounds or is invalid UTF-8")
    String(value)
end
function release_note(value::AbstractDict)
    tag=release_text(get(value,"tag_name",nothing),"tag";limit=512)
    title=release_text(something(get(value,"name",nothing),tag),"title";limit=2048)
    body=release_text(something(get(value,"body",nothing),""),"body")
    published=release_text(something(get(value,"published_at",nothing),"Unknown"),"publication date";limit=100)
    url=release_text(get(value,"html_url",nothing),"URL";limit=4096)
    startswith(url,JF2_RELEASES_PAGE*"/tag/") || error("Release URL is outside the configured public repository")
    ReleaseNote(tag,title,published,body,url)
end
release_note(value)=error("Release records must be objects")

"""Fetch all bounded pages or fail explicitly; an incomplete page set never becomes a valid cache."""
function fetch_release_changelog(context::ExecutionContext;policy=ReleaseFetchPolicy(),transport=public_release_transport)
    policy.allow_network || error("Public release retrieval requires explicit authorization")
    1<=policy.response_limit<=8RELEASE_RESPONSE_LIMIT || error("Invalid release response limit")
    1<=policy.maximum_pages<=100 && isfinite(policy.timeout) && policy.timeout>0 || error("Invalid release request limits")
    entries=ReleaseNote[]
    identities=Set{String}()
    complete=false
    page=1
    received=0
    while !complete && page<=policy.maximum_pages
        cancelled(context) && error("Release retrieval cancelled")
        response=transport(JF2_RELEASES_API*"?per_page=100&page="*string(page),context,policy)
        response.status==200 || error(transport_reason(response,"Public release retrieval"))
        text=release_text(response.body,"response";limit=policy.response_limit)
        received+=ncodeunits(text)
        received<=8RELEASE_RESPONSE_LIMIT || error("Public release notes exceed aggregate size bound")
        records=JSON.parse(text;dicttype=Dict{String,Any})
        records isa AbstractVector && length(records)<=100 || error("Invalid public release response")
        for value in records
            value isa AbstractDict || error("Invalid release object")
            draft=get(value,"draft",false)
            draft isa Bool || error("Invalid draft release flag")
            if !draft
                note=release_note(value)
                note.tag in identities && error("Public releases changed during pagination; retry explicitly")
                push!(identities,note.tag)
                push!(entries,note)
            end
        end
        complete=length(records)<100
        page+=1
    end
    complete || error("Release pagination exceeds the configured bound; no incomplete cache saved")
    cancelled(context) && error("Release retrieval cancelled")
    ReleaseChangelog(JF2_RELEASES_PAGE,timeline_timestamp(),entries)
end

function release_changelog_json(snapshot::ReleaseChangelog)
    JSON.json(Dict("format"=>"JuliaForever2.release-changelog.v1","source"=>snapshot.source,"checkedAt"=>snapshot.checked_at,
        "entries"=>[Dict("tag_name"=>note.tag,"name"=>note.title,"published_at"=>note.published_at,"body"=>note.body,"html_url"=>note.url) for note in snapshot.entries]))*"\n"
end
function read_release_changelog_state(path::AbstractString)
    islink(path) && error("Release cache cannot be a symbolic link")
    if !isfile(path)
        (;snapshot=nothing,digest=nothing)
    else
        filesize(path)<=8RELEASE_RESPONSE_LIMIT || error("Release cache is too large")
        text=open(path,"r") do input
            String(read(input,8RELEASE_RESPONSE_LIMIT+1))
        end
        ncodeunits(text)<=8RELEASE_RESPONSE_LIMIT || error("Release cache changed beyond the size bound")
        data=JSON.parse(text;dicttype=Dict{String,Any})
        data isa AbstractDict && get(data,"format",nothing)=="JuliaForever2.release-changelog.v1" && get(data,"source",nothing)==JF2_RELEASES_PAGE || error("Invalid release cache identity")
        values=get(data,"entries",nothing)
        values isa AbstractVector && length(values)<=10000 || error("Invalid cached release collection")
        snapshot=ReleaseChangelog(JF2_RELEASES_PAGE,release_text(get(data,"checkedAt",nothing),"cache timestamp";limit=100),release_note.(values))
        (;snapshot,digest=timeline_digest(text))
    end
end
read_release_changelog(path::AbstractString)=read_release_changelog_state(path).snapshot

function save_release_changelog!(path::AbstractString,snapshot::ReleaseChangelog;expected=nothing)
    snapshot.source==JF2_RELEASES_PAGE || error("Invalid release source")
    text=release_changelog_json(snapshot)
    ncodeunits(text)<=8RELEASE_RESPONSE_LIMIT || error("Release cache exceeds the size bound")
    timeline_replace_file(path,text,expected)
end
