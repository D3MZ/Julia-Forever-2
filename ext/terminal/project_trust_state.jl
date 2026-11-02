# Project trust interaction semantics are derived from Pi 1.4.0 (MIT); see licenses/pi-LICENSE.
Base.@kwdef struct ProjectTrustOption
    label::String
    trusted::Bool
    updates::Vector{Pair{String,Union{Nothing,Bool}}}=Pair{String,Union{Nothing,Bool}}[]
    saved_path::Union{Nothing,String}=nothing
end

Base.@kwdef mutable struct ProjectTrustState
    directory::String
    canonical::String
    path::String
    trusted::Bool=false
    resource_admitted::Bool=false
    pending::Bool=false
    startup_prompt::Bool=false
    saved_path::Union{Nothing,String}=nothing
    saved_decision::Union{Nothing,Bool}=nothing
    revision::Union{Nothing,String}=nothing
    error::String=""
    store_error::String=""
    options::Vector{ProjectTrustOption}=ProjectTrustOption[]
    cursor::Int=1
    pasting::Bool=false
    paste_marker::String=""
end

"""Build explicit canonical scope choices without saving or granting any decision."""
function project_trust_options(canonical::String;session_only::Bool=false)
    updates(path,decision)=Pair{String,Union{Nothing,Bool}}[path=>decision]
    options=ProjectTrustOption[ProjectTrustOption(;label="Trust",trusted=true,updates=updates(canonical,true),saved_path=canonical)]
    parent=dirname(canonical)
    if parent!=canonical
        changes=Pair{String,Union{Nothing,Bool}}[parent=>true,canonical=>nothing]
        push!(options,ProjectTrustOption(;label="Trust parent folder ($parent)",trusted=true,updates=changes,saved_path=parent))
    end
    session_only && push!(options,ProjectTrustOption(;label="Trust (this session only)",trusted=true))
    push!(options,ProjectTrustOption(;label="Do not trust",trusted=false,updates=updates(canonical,false),saved_path=canonical))
    session_only && push!(options,ProjectTrustOption(;label="Do not trust (this session only)",trusted=false))
    options
end
