# Native fullscreen transcript search derived from Pi (MIT), pinned 2c8d1feb147f6b3d97e855da803bfe7b19f3c403.
# See licenses/pi-LICENSE. Original-only runtime evidence is maintained outside the repository.
Base.@kwdef struct TerminalSearchSpan
    first::Int
    last::Int
    row::Int
    column::Int
    stop::Int
    linear::Bool = false
end
Base.@kwdef struct TerminalSearchSegment
    row::Int
    first::Int
    last::Int
end
Base.@kwdef struct TerminalSearchMatch
    segments::Vector{TerminalSearchSegment} = TerminalSearchSegment[]
end
Base.@kwdef mutable struct TerminalSearchIndex
    source::Vector{String} = String[]
    corpus::String = ""
    spans::Vector{TerminalSearchSpan} = TerminalSearchSpan[]
    query::Union{Nothing,String} = nothing
    matches::Vector{TerminalSearchMatch} = TerminalSearchMatch[]
    initialized::Bool = false
    error::Union{Nothing,String} = nothing
end
Base.@kwdef mutable struct TerminalTranscriptSearch
    active::Bool = false
    focused::Bool = false
    owner::String = ""
    epoch::UInt = UInt(0)
    input::MenuSearchInput = MenuSearchInput(;prompt=" ")
    index::TerminalSearchIndex = TerminalSearchIndex()
    query::String = ""
    input_error::Union{Nothing,String} = nothing
    matches::Vector{TerminalSearchMatch} = TerminalSearchMatch[]
    selected::Int = -1
    selected_key::Union{Nothing,NTuple{4,Int}} = nothing
    anchor::Int = 0
    mode::Symbol = :query
    bounds::Tachikoma.Rect = Tachikoma.Rect()
    previous::UnitRange{Int} = -1:-2
    next::UnitRange{Int} = -1:-2
    cursor_column::Union{Nothing,Int} = nothing
    hovered::Int = 0
end

terminal_search_focused(state::TerminalTranscriptSearch) = state.active && state.focused
terminal_search_focus!(state::TerminalTranscriptSearch,focused::Bool) = (state.focused=focused; nothing)
