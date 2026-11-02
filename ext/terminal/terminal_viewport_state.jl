"""An immutable timer token is valid only for its current App viewport owner."""
Base.@kwdef struct TerminalSelectionExpiry
    owner::Base.RefValue{Nothing}
    epoch::UInt
end

"""Keep document scroll, selection and component mouse capture under one UI owner."""
Base.@kwdef mutable struct TerminalViewport
    scroll::TerminalScrollHost
    selection::TerminalSelectionControl
    owner::Base.RefValue{Nothing}=Ref(nothing)
    component::Union{Nothing,Tuple{Symbol,Vector{String},UInt}}=nothing
    press::Union{Nothing,Tuple{Int,Int}}=nothing
    moved::Bool=false
    wheel_delta::Int=0
    indicator::Union{Nothing,TerminalScrollIndicator}=nothing
    search::TerminalTranscriptSearch=TerminalTranscriptSearch()
    tracking::Symbol=:none
    tracking_sink::Union{Nothing,IO}=nothing
end
