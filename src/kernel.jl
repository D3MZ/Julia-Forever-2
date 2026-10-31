struct ComponentSpec{T,F}
    name::Symbol
    value::T
    requires::Vector{Symbol}
    cleanup::F
end

ComponentSpec(name::Symbol, value; requires=Symbol[], cleanup=Returns(nothing)) = ComponentSpec(name, value, collect(Symbol, requires), cleanup)

mutable struct ComponentEntry
    spec::ComponentSpec
    users::Int
    retired::Bool
    cleaned::Bool
end

mutable struct Kernel
    lock::ReentrantLock
    entries::Dict{Symbol,ComponentEntry}
end

Kernel() = Kernel(ReentrantLock(), Dict{Symbol,ComponentEntry}())

mutable struct ComponentLease{T}
    kernel::Kernel
    entry::ComponentEntry
    value::T
    released::Bool
end

function component(kernel::Kernel, name::Symbol)
    lock(kernel.lock) do
        entry = get(kernel.entries, name, nothing)
        return isnothing(entry) ? nothing : entry.spec.value
    end
end

function cyclic(kernel::Kernel, spec::ComponentSpec)
    pending = copy(spec.requires)
    seen = Set{Symbol}()
    while !isempty(pending)
        name = pop!(pending)
        name == spec.name && return true
        name in seen && continue
        push!(seen, name)
        entry = get(kernel.entries, name, nothing)
        isnothing(entry) || append!(pending, entry.spec.requires)
    end
    return false
end

function retire!(entry::ComponentEntry)
    entry.retired = true
    if entry.users == 0 && !entry.cleaned
        entry.cleaned = true
        return entry.spec
    end
    return nothing
end

function cleanup(spec)
    isnothing(spec) || Base.invokelatest(spec.cleanup, spec.value)
    return nothing
end

function install!(kernel::Kernel, spec::ComponentSpec)
    result, old = lock(kernel.lock) do
        missing = filter(name -> !haskey(kernel.entries, name), spec.requires)
        isempty(missing) || return ((ok=false, reason="Missing dependencies: $(join(missing, ", "))"), nothing)
        cyclic(kernel, spec) && return ((ok=false, reason="Cyclic dependencies"), nothing)
        previous = get(kernel.entries, spec.name, nothing)
        kernel.entries[spec.name] = ComponentEntry(spec, 0, false, false)
        return ((ok=true, reason=""), isnothing(previous) ? nothing : retire!(previous))
    end
    cleanup(old)
    return result
end

function remove!(kernel::Kernel, name::Symbol)
    result, old = lock(kernel.lock) do
        entry = get(kernel.entries, name, nothing)
        isnothing(entry) && return ((ok=false, reason="Component not found"), nothing)
        dependents = [key for (key, other) in kernel.entries if name in other.spec.requires]
        isempty(dependents) || return ((ok=false, reason="Required by: $(join(dependents, ", "))"), nothing)
        delete!(kernel.entries, name)
        return ((ok=true, reason=""), retire!(entry))
    end
    cleanup(old)
    return result
end

function acquire!(kernel::Kernel, name::Symbol)
    lock(kernel.lock) do
        entry = get(kernel.entries, name, nothing)
        isnothing(entry) && return nothing
        entry.users += 1
        return ComponentLease(kernel, entry, entry.spec.value, false)
    end
end

function release!(lease::ComponentLease)
    old = lock(lease.kernel.lock) do
        lease.released && return nothing
        lease.released = true
        entry = lease.entry
        entry.users -= 1
        return entry.retired ? retire!(entry) : nothing
    end
    cleanup(old)
    return nothing
end
