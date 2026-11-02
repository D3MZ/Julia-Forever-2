"""Keep visible menu order independent from actual builtin, extension, then resource execution."""
command_execution_priority(origin::Symbol) = origin == :builtin ? 0 : origin == :prompt ? 2 : origin == :skill ? 3 : 1

"""Select the first highest-precedence matching command without rearranging or mutating registrations."""
function command_dispatch_index(commands::AbstractVector{<:CommandSpec}, name::AbstractString)
    selected = nothing
    priority = typemax(Int)
    for index in eachindex(commands)
        command = commands[index]
        candidate = command_execution_priority(command.origin)
        if command.name == name && candidate < priority
            selected = index
            priority = candidate
        end
    end
    selected
end
