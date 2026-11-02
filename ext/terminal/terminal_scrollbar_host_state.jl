public TerminalScrollHost, TerminalScrollbarExpiry

Base.@kwdef struct TerminalScrollbarExpiry
    owner::Base.RefValue{Nothing}
    generation::UInt
end

"""Bind a native viewport to the actual App event queue without retaining mutable selection output."""
Base.@kwdef struct TerminalScrollHost
    control::TerminalScrollControl
    wheel::TerminalWheelScroll = TerminalWheelScroll()
    owner::Base.RefValue{Nothing} = Ref(nothing)
end
