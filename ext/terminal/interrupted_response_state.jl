"""Bind a semantic preview to one live operation and its existing archive branch."""
Base.@kwdef struct PreviewOwnership
    runtime::String
    timeline::String
    anchor::Union{Nothing,String}
    operation::UInt64
    token::String=string(JuliaForever2.uuid4())
end
PreviewOwnership(runtime,timeline,anchor,operation)=PreviewOwnership(;runtime,timeline,anchor,operation)

"""Keep an interrupted answer visible while its guarded display-only archive write is settled."""
Base.@kwdef mutable struct InterruptedResponseView
    owner::PreviewOwnership
    text::String
    stop::Symbol
    attempted::Bool=false
    saved::Bool=false
    discarded::Bool=false
end
