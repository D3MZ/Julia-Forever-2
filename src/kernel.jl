struct ComponentSpec{T,F}
    name::Symbol
    value::T
    requires::Vector{Symbol}
    cleanup::F
end

ComponentSpec(name::Symbol, value; requires=Symbol[], cleanup=Returns(nothing)) = ComponentSpec(name, value, unique(collect(Symbol, requires)), cleanup)

mutable struct ComponentEntry{S}
    spec::S
    dependencies::Vector{ComponentEntry}
    users::Int
    retired::Bool
    cleaning::Bool
    cleaned::Bool
end

mutable struct Kernel
    lock::ReentrantLock
    entries::Dict{Symbol,ComponentEntry}
    closed::Bool
end

Kernel() = Kernel(ReentrantLock(), Dict{Symbol,ComponentEntry}(), false)

mutable struct ComponentLease{T,E}
    kernel::Kernel
    entry::E
    value::T
    released::Bool
end

struct BoundComponent{V,R,D}
    value::V
    retention::R
    available::Bool
    dependencies::D
end

track_component_lease!(owner, lease::ComponentLease) = lease
transfer_component_lease!(lease::ComponentLease) = lease

"""Inspect component names, value types and dependencies without exposing live resources."""
function component_snapshot(kernel::Kernel)
    lock(kernel.lock) do
        return [(name=name, value_type=typeof(entry.spec.value), requires=Tuple(entry.spec.requires))
            for (name, entry) in sort!(collect(kernel.entries); by=first)]
    end
end

"""Inspect a component; use with_component when its resources must remain live."""
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

function ready_to_clean!(pending, entry::ComponentEntry)
    if entry.retired && entry.users == 0 && !entry.cleaning && !entry.cleaned
        entry.cleaning = true
        push!(pending, entry)
    end
    return pending
end

function retire!(pending, entry::ComponentEntry)
    entry.retired = true
    return ready_to_clean!(pending, entry)
end

function clean_entries!(kernel::Kernel, pending)
    failures = Task[]
    while !isempty(pending)
        entry = pop!(pending)
        cleanup = spawn_cleanup(() -> Base.invokelatest(entry.spec.cleanup, entry.spec.value))
        wait(cleanup; throw=false)
        istaskfailed(cleanup) && push!(failures, cleanup)
        lock(kernel.lock) do
            entry.cleaned = true
            entry.cleaning = false
            for dependency in entry.dependencies
                dependency.users -= 1
                ready_to_clean!(pending, dependency)
            end
            empty!(entry.dependencies)
        end
    end
    isempty(failures) || fetch(first(failures))
    return nothing
end

function install!(kernel::Kernel, spec::ComponentSpec; expected_entry=missing)
    pending = ComponentEntry[]
    result = lock(kernel.lock) do
        kernel.closed && return (ok=false, reason="Kernel is closed")
        missing = filter(name -> !haskey(kernel.entries, name), spec.requires)
        isempty(missing) || return (ok=false, reason="Missing dependencies: $(join(missing, ", "))")
        cyclic(kernel, spec) && return (ok=false, reason="Cyclic dependencies")
        previous = get(kernel.entries, spec.name, nothing)
        if !ismissing(expected_entry) && previous !== expected_entry
            return (ok=false, reason="Component changed during composition")
        end
        dependencies = ComponentEntry[kernel.entries[name] for name in unique(spec.requires)]
        for dependency in dependencies
            dependency.users += 1
        end
        stored = ComponentSpec(spec.name, spec.value; requires=copy(spec.requires), cleanup=spec.cleanup)
        kernel.entries[spec.name] = ComponentEntry(stored, dependencies, 0, false, false, false)
        isnothing(previous) || retire!(pending, previous)
        return (ok=true, reason="")
    end
    clean_entries!(kernel, pending)
    return result
end

function remove!(kernel::Kernel, name::Symbol)
    pending = ComponentEntry[]
    result = lock(kernel.lock) do
        entry = get(kernel.entries, name, nothing)
        isnothing(entry) && return (ok=false, reason="Component not found")
        dependents = [key for (key, other) in kernel.entries if name in other.spec.requires]
        isempty(dependents) || return (ok=false, reason="Required by: $(join(dependents, ", "))")
        delete!(kernel.entries, name)
        retire!(pending, entry)
        return (ok=true, reason="")
    end
    clean_entries!(kernel, pending)
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
    pending = ComponentEntry[]
    lock(lease.kernel.lock) do
        if !lease.released
            lease.released = true
            lease.entry.users -= 1
            ready_to_clean!(pending, lease.entry)
        end
    end
    clean_entries!(lease.kernel, pending)
    return nothing
end

"""Bind a component and retain the exact generation and dependencies used by this operation."""
function bind_component(kernel::Kernel, name::Symbol; fallback=nothing, owner=get(task_local_storage(), :JuliaForever2_context, nothing))
    lease = acquire!(kernel, name)
    isnothing(lease) && return BoundComponent(fallback, nothing, !isnothing(fallback), NamedTuple())
    dependencies = (; (entry.spec.name => entry.spec.value for entry in lease.entry.dependencies)...)
    return BoundComponent(lease.value, track_component_lease!(owner, lease), true, dependencies)
end

bound_dependency(binding::BoundComponent, name::Symbol) = get(binding.dependencies, name, nothing)

function release!(binding::BoundComponent)
    isnothing(binding.retention) || release!(binding.retention)
    return nothing
end

"""Call f with a component generation retained for the duration of normal execution."""
function with_component(f, kernel::Kernel, name::Symbol; fallback=nothing)
    binding = bind_component(kernel, name; fallback)
    binding.available || return nothing
    result = f(binding.value)
    release!(binding)
    return result
end

"""Wrap the current component while retaining the exact generation being wrapped."""
function wrap_component!(builder, kernel::Kernel, name::Symbol; fallback=nothing, requires=Symbol[], cleanup=Returns(nothing))
    lease = acquire!(kernel, name)
    retention = isnothing(lease) ? nothing : track_component_lease!(get(task_local_storage(), :JuliaForever2_context, nothing), lease)
    inner = isnothing(lease) ? fallback : lease.value
    value = builder(inner)
    dispose = value -> begin
        cleanup_task = spawn_cleanup(() -> Base.invokelatest(cleanup, value))
        wait(cleanup_task; throw=false)
        isnothing(lease) || release!(lease)
        fetch(cleanup_task)
        nothing
    end
    expected_entry = isnothing(lease) ? nothing : lease.entry
    result = install!(kernel, ComponentSpec(name, value; requires, cleanup=dispose); expected_entry)
    isnothing(retention) || transfer_component_lease!(retention)
    result.ok || dispose(value)
    return result
end

function clone_generation!(clones, source::Kernel, entry::ComponentEntry, active)
    existing = get(clones, entry, nothing)
    isnothing(existing) || return existing
    entry.users += 1
    lease = ComponentLease(source, entry, entry.spec.value, false)
    spec = ComponentSpec(entry.spec.name, entry.spec.value; requires=entry.spec.requires, cleanup=value -> release!(lease))
    cloned = ComponentEntry(spec, ComponentEntry[], 0, !(entry in active), false, false)
    clones[entry] = cloned
    for dependency in entry.dependencies
        retained = clone_generation!(clones, source, dependency, active)
        retained.users += 1
        push!(cloned.dependencies, retained)
    end
    return cloned
end

"""Snapshot composition and exact dependency generations while retaining their source resources."""
function fork_kernel(kernel::Kernel)
    forked = Kernel()
    lock(kernel.lock) do
        active = Set(values(kernel.entries))
        clones = IdDict{ComponentEntry,ComponentEntry}()
        for (name, entry) in kernel.entries
            forked.entries[name] = clone_generation!(clones, kernel, entry, active)
        end
        forked.closed = kernel.closed
    end
    return forked
end

"""Retire all components; outstanding leases defer cleanup in dependency order."""
function Base.close(kernel::Kernel)
    pending = ComponentEntry[]
    lock(kernel.lock) do
        kernel.closed = true
        for entry in values(kernel.entries)
            retire!(pending, entry)
        end
        empty!(kernel.entries)
    end
    clean_entries!(kernel, pending)
    return nothing
end

Base.isopen(kernel::Kernel) = lock(() -> !kernel.closed, kernel.lock)
