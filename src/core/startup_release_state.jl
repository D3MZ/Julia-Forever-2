"""Read only bounded installed-version acknowledgement state, independently of fetched release notes."""
function startup_release_state(path::AbstractString)
    islink(path) && error("Startup release state cannot be a symbolic link")
    if !isfile(path)
        (;version=nothing,digest=nothing)
    else
        filesize(path)<=1024 || error("Startup release state exceeds its size bound")
        text=open(path,"r") do input
            String(read(input,1025))
        end
        sizeof(text)<=1024 || error("Startup release state changed beyond its size bound")
        value=JSON.parse(text;dicttype=Dict{String,Any})
        value isa AbstractDict && get(value,"format",nothing)=="JuliaForever2.startup-release.v1" || error("Invalid startup release state")
        version=startup_release_version(get(value,"version",nothing))
        isnothing(version) && error("Invalid acknowledged release version")
        (;version,digest=timeline_digest(text))
    end
end
startup_release_version(value::AbstractString) = startup_release_version(String(value))
function startup_release_version(text::String)
    sizeof(text)<=100 && occursin(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?$",text) ? tryparse(VersionNumber,text) : nothing
end
startup_release_version(value)=nothing

"""Offer only real cached notes newer than the acknowledgement and no newer than the installed package."""
function startup_release_notes(snapshot::Union{Nothing,ReleaseChangelog},previous::VersionNumber,current::VersionNumber)
    notes=ReleaseNote[]
    if !isnothing(snapshot)
        for note in snapshot.entries
            version=startup_release_version(note.tag)
            !isnothing(version) && previous<version<=current && push!(notes,note)
        end
        sort!(notes;by=note->something(startup_release_version(note.tag),v"0.0.0"),rev=true)
    end
    notes
end
function acknowledge_startup_release!(path::AbstractString,version::VersionNumber,expected)
    mkpath(dirname(path);mode=0o700)
    text=JSON.json(Dict("format"=>"JuliaForever2.startup-release.v1","version"=>string(version)))*"\n"
    digest=timeline_replace_file(path,text,expected)
    actual=startup_release_state(path)
    actual.version==version && actual.digest==digest || error("Startup release acknowledgement readback failed")
    actual
end
