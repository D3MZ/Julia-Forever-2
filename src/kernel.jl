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
    found = false
    while !isempty(pending) && !found
        name = pop!(pending)
        found = name == spec.name
        if !found && !(name in seen)
            push!(seen, name)
            dependency = get(kernel.entries, name, nothing)
            append!(pending, requirements(dependency))
        end
    end
    found
end

requirements(::Nothing) = ()
requirements(entry::ComponentEntry) = entry.spec.requires
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

function conflict(kernel::Kernel, spec::ComponentSpec, expected)
    absent = filter(name -> !haskey(kernel.entries, name), spec.requires)
    previous = get(kernel.entries, spec.name, nothing)
    if kernel.closed
        "Kernel is closed"
    elseif !isempty(absent)
        "Missing dependencies: $(join(absent, ", "))"
    elseif cyclic(kernel, spec)
        "Cyclic dependencies"
    elseif !ismissing(expected) && previous !== expected
        "Component changed during composition"
    else
        ""
    end
end

function ComponentEntry(spec::ComponentSpec, dependencies::Vector{ComponentEntry})
    stored = ComponentSpec(spec.name, spec.value; requires=copy(spec.requires), cleanup=spec.cleanup)
    ComponentEntry(stored, dependencies, 0, false, false, false)
end

function install!(kernel::Kernel, spec::ComponentSpec; expected_entry=missing)
    pending = ComponentEntry[]
    result = lock(kernel.lock) do
        reason = conflict(kernel, spec, expected_entry)
        isempty(reason) ? replace!(kernel, spec, pending) : (ok=false, reason)
    end
    clean_entries!(kernel, pending)
    result
end

function replace!(kernel::Kernel, spec::ComponentSpec, pending)
    dependencies = ComponentEntry[kernel.entries[name] for name in unique(spec.requires)]
    foreach(dependency -> dependency.users += 1, dependencies)
    previous = get(kernel.entries, spec.name, nothing)
    kernel.entries[spec.name] = ComponentEntry(spec, dependencies)
    retire!(pending, previous)
    (ok=true, reason="")
end

retire!(pending, ::Nothing) = pending
function remove!(kernel::Kernel, name::Symbol)
    pending = ComponentEntry[]
    result = lock(kernel.lock) do
        withdraw!(kernel, get(kernel.entries, name, nothing), pending)
    end
    clean_entries!(kernel, pending)
    result
end

withdraw!(kernel::Kernel, ::Nothing, pending) = (ok=false, reason="Component not found")

function withdraw!(kernel::Kernel, entry::ComponentEntry, pending)
    name = entry.spec.name
    dependents = [key for (key, other) in kernel.entries if name in other.spec.requires]
    if isempty(dependents)
        delete!(kernel.entries, name)
        retire!(pending, entry)
        (ok=true, reason="")
    else
        (ok=false, reason="Required by: $(join(dependents, ", "))")
    end
end
function acquire!(kernel::Kernel, name::Symbol)
    lock(kernel.lock) do
        retain!(kernel, get(kernel.entries, name, nothing))
    end
end

retain!(kernel::Kernel, ::Nothing) = nothing

function retain!(kernel::Kernel, entry::ComponentEntry)
    entry.users += 1
    ComponentLease(kernel, entry, entry.spec.value, false)
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
function BoundComponent(lease::ComponentLease, fallback, owner)
    dependencies = (; (entry.spec.name => entry.spec.value for entry in lease.entry.dependencies)...)
    BoundComponent(lease.value, track_component_lease!(owner, lease), true, dependencies)
end

BoundComponent(::Nothing, fallback, owner) = BoundComponent(fallback, nothing, !isnothing(fallback), NamedTuple())
bind_component(kernel::Kernel, name::Symbol; fallback=nothing, owner=get(task_local_storage(), :JuliaForever2_context, nothing)) = BoundComponent(acquire!(kernel, name), fallback, owner)
bound_dependency(binding::BoundComponent, name::Symbol) = get(binding.dependencies, name, nothing)

function release!(binding::BoundComponent)
    isnothing(binding.retention) || release!(binding.retention)
    return nothing
end

"""Call f with a component generation retained for the duration of normal execution."""
function with_component(f, kernel::Kernel, name::Symbol; fallback=nothing)
    binding = bind_component(kernel, name; fallback)
    binding.available ? apply(f, binding) : nothing
end

function apply(f, binding::BoundComponent)
    result = f(binding.value)
    release!(binding)
    result
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
    get!(clones, entry) do
        clone!(clones, source, entry, active)
    end
end

function clone!(clones, source::Kernel, entry::ComponentEntry, active)
    lease = retain!(source, entry)
    spec = ComponentSpec(entry.spec.name, entry.spec.value; requires=entry.spec.requires, cleanup=value -> release!(lease))
    cloned = ComponentEntry(spec, ComponentEntry[], 0, !(entry in active), false, false)
    clones[entry] = cloned
    for dependency in entry.dependencies
        retained = clone_generation!(clones, source, dependency, active)
        retained.users += 1
        push!(cloned.dependencies, retained)
    end
    cloned
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
