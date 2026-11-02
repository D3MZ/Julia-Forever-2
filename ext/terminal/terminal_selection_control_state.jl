# Native selection behavior derived from Pi (MIT), copyright (c) 2025 Mario Zechner.
# Pinned upstream: 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""Own one fullscreen selection, real clipboard adapter and expiring display-only confirmations."""
Base.@kwdef mutable struct TerminalSelectionControl
    state::TerminalSelectionState=TerminalSelectionState()
    flashes::TerminalSelectionFlashes=TerminalSelectionFlashes()
    view::TerminalSelectionView=TerminalSelectionView()
    owner::Union{Nothing,String}=nothing
    fullscreen::Bool=false
    generation::UInt=0
    closed::Bool=false
    on_change::Function=Returns(nothing)
    copy::Function=Returns(:none)
    on_timer::Function=Returns(nothing)
    timer::Union{Nothing,Timer}=nothing
    timer_epoch::UInt=0
end
