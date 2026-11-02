"""Identify one activation of a Julia-native skill source."""
struct SkillSourceRegistration
    name::Symbol
    generation::UInt64
end

"""Borrow a source service; priority is independent of registration time."""
struct SkillSourceBinding
    name::Symbol
    priority::Int
    generation::UInt64
    source::Any
end

"""Compose independently authored skill services through their Julia methods."""
Base.@kwdef mutable struct CompositeSkillRegistry
    lock::ReentrantLock = ReentrantLock()
    sources::Dict{Symbol,SkillSourceBinding} = Dict{Symbol,SkillSourceBinding}()
    revision::UInt64 = UInt64(0)
end

"""Register or explicitly replace a source; higher priority wins name collisions."""
function register_skill_source!(registry::CompositeSkillRegistry,
        name::Union{Symbol,AbstractString}, source; priority::Int=0, replace::Bool=false)
    identity = Symbol(name)
    lock(registry.lock) do
        if isempty(String(identity))
            (ok=false, reason="Skill source name must not be empty", registration=nothing)
        elseif source === registry
            (ok=false, reason="A composite cannot contain itself", registration=nothing)
        elseif haskey(registry.sources, identity) && !replace
            (ok=false, reason="Skill source $identity is already registered", registration=nothing)
        else
            registry.revision += UInt64(1)
            generation = registry.revision
            registry.sources[identity] = SkillSourceBinding(identity, priority, generation, source)
            (ok=true, reason="", registration=SkillSourceRegistration(identity, generation))
        end
    end
end

"""A disposed plugin cannot remove a more recent source replacement."""
function unregister_skill_source!(registry::CompositeSkillRegistry,
        registration::SkillSourceRegistration)
    lock(registry.lock) do
        current = get(registry.sources, registration.name, nothing)
        active = !isnothing(current) && current.generation == registration.generation
        if active
            delete!(registry.sources, registration.name)
            registry.revision += UInt64(1)
        end
        (ok=active, reason=active ? "" : "Skill source registration is no longer active")
    end
end

"""Own a source registration for exactly the containing Julia plugin activation."""
function register_skill_source!(context::PluginContext, registry, name, source; kwargs...)
    result = register_skill_source!(registry, name, source; kwargs...)
    if result.ok
        effect!(() -> unregister_skill_source!(registry, result.registration), context)
    end
    result
end

"""Read source membership without holding a lock during provider I/O."""
function composite_skill_sources(registry::CompositeSkillRegistry)
    lock(registry.lock) do
        sources = collect(values(registry.sources))
        sort!(sources; lt=(left, right) -> left.priority == right.priority ?
            isless(left.name, right.name) : left.priority > right.priority)
        (sources=sources, revision=registry.revision)
    end
end

"""Reject unusable skill summaries without losing other providers' valid entries."""
function composite_skill_summary(entry)
    label = String(entry.name)
    description = strip(replace(String(entry.description), r"\s+" => " "))
    valid = occursin(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", label) &&
        !isempty(description)
    (valid=valid, name=Symbol(label), description=description)
end

"""Merge sources by priority, masking duplicate names across both audiences.

Each source implements skill_catalog_snapshot and load_skill, including audience=:all.
Incomplete source catalogs retain usable entries and mark the merged view incomplete.
"""
function skill_catalog_snapshot(registry::CompositeSkillRegistry,
        workspace::AbstractString=pwd(); audience::Symbol=:model)
    snapshot = composite_skill_sources(registry)
    rows = NamedTuple{(:name, :description),Tuple{Symbol,String}}[]
    seen = Set{Symbol}()
    complete = true
    for binding in snapshot.sources
        all_entries = skill_catalog_snapshot(binding.source, workspace; audience=:all)
        shown = audience === :all ? all_entries :
            skill_catalog_snapshot(binding.source, workspace; audience)
        complete &= all_entries.complete && shown.complete
        visible = Set(Symbol(entry.name) for entry in shown.skills)
        known = Set{Symbol}()
        for entry in all_entries.skills
            summary = composite_skill_summary(entry)
            if !summary.valid
                complete = false
            else
                push!(known, summary.name)
                if !(summary.name in seen)
                    push!(seen, summary.name)
                    if summary.name in visible
                        push!(rows, (name=summary.name, description=summary.description))
                    end
                end
            end
        end
        complete &= issubset(visible, known)
    end
    stable = lock(() -> registry.revision == snapshot.revision, registry.lock)
    (skills=sort!(rows; by=entry -> entry.name), complete=complete && stable)
end

"""Expose the existing skill catalog interface on the composite service."""
skill_catalog(registry::CompositeSkillRegistry, workspace::AbstractString=pwd();
        audience::Symbol=:model) =
    skill_catalog_snapshot(registry, workspace; audience).skills

"""Choose the owner by the unfiltered catalog, even if a skill is hidden."""
function composite_skill_owner(sources, label::AbstractString, workspace::AbstractString)
    selected = nothing
    for binding in sources
        entries = skill_catalog_snapshot(binding.source, workspace; audience=:all)
        if any(entry -> String(entry.name) == label, entries.skills)
            selected = binding
            break
        end
    end
    selected
end

"""Load the visible winner, rejecting a registration change during lookup."""
function load_skill(registry::CompositeSkillRegistry,
        name::Union{Symbol,AbstractString}, workspace::AbstractString=pwd();
        audience::Symbol=:model)
    label = String(name)
    if !occursin(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", label)
        skill_load_failure("Invalid skill name: $label")
    else
        snapshot = composite_skill_sources(registry)
        owner = composite_skill_owner(snapshot.sources, label, workspace)
        if isnothing(owner)
            skill_load_failure("Unknown skill: $label")
        else
            shown = skill_catalog_snapshot(owner.source, workspace; audience)
            permitted = any(entry -> String(entry.name) == label, shown.skills)
            if !permitted
                skill_load_failure("Skill $label is not available for $audience")
            else
                loaded = load_skill(owner.source, name, workspace; audience)
                stable = lock(() -> registry.revision == snapshot.revision, registry.lock)
                stable ? loaded : skill_load_failure("Skill sources changed during load: $label")
            end
        end
    end
end

"""Install the optional composite as a replaceable Julia profile service."""
function composite_skill_plugin(; name=:composite_skills, service_name=:skills,
        factory=CompositeSkillRegistry)
    contract = Symbol(service_name)
    setup = context -> provide!(context, contract, Base.invokelatest(factory))
    PluginSpec(name, setup; provides=[contract])
end
