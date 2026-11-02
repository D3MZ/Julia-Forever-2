"""Retain startup update content and a pending local acknowledgement, never credentials or provider messages."""
Base.@kwdef mutable struct StartupUpdateNotice
    markdown::String=""
    version::String=""
    collapsed::Bool=false
    pending::Bool=false
    acknowledgement_path::String=""
    expected::Union{Nothing,String}=nothing
    installed::VersionNumber=v"0.0.0"
end
