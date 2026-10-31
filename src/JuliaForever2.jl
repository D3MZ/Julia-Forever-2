module JuliaForever2

export greet, Kernel, ComponentSpec, component, install!, remove!, acquire!, release!, Session, Message, Reply, run_turn!, spawn_agent!

include("kernel.jl")
include("agent.jl")
include("providers.jl")
include("tui.jl")

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
