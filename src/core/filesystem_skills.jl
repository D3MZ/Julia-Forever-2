"""A Julia-native, workspace-aware skill source; in-memory registrations take precedence."""
struct FilesystemSkillRegistry{R}
    registered::R
    roots::Vector{String}
    workspace_skills::Bool
    user_root::Union{Nothing,String}
end

function FilesystemSkillRegistry(; registered=SkillRegistry(), roots=String[],
        workspace_skills::Bool=true, user_root=joinpath(homedir(), ".juliaforever", "skills"))
    directories = String[abspath(String(root)) for root in roots]
    home = isnothing(user_root) ? nothing : abspath(String(user_root))
    FilesystemSkillRegistry(registered, directories, workspace_skills, home)
end

register_skill!(registry::FilesystemSkillRegistry, skill::Skill; kwargs...) =
    register_skill!(registry.registered, skill; kwargs...)
unregister_skill!(registry::FilesystemSkillRegistry, registration::SkillRegistration) =
    unregister_skill!(registry.registered, registration)

struct FilesystemSkillEntry
    name::Symbol
    description::String
    path::String
    model_visible::Bool
    user_visible::Bool
end

skill_visible(entry::FilesystemSkillEntry, ::Val{:model}) = entry.model_visible
skill_visible(entry::FilesystemSkillEntry, ::Val{:user}) = entry.user_visible
skill_visible(::FilesystemSkillEntry, ::Val{:all}) = true
skill_visible(::FilesystemSkillEntry, ::Val) = error("Unknown skill audience")

"""Anchor workspace skills at the nearest Git project, or the supplied directory."""
function skill_project_root(workspace::AbstractString)
    current = abspath(workspace)
    while !ispath(joinpath(current, ".git"))
        parent = dirname(current)
        parent == current && return abspath(workspace)
        current = parent
    end
    current
end

function filesystem_skill_roots(registry::FilesystemSkillRegistry, workspace)
    roots = String[]
    registry.workspace_skills && push!(roots, joinpath(skill_project_root(workspace), ".agents", "skills"))
    append!(roots, registry.roots)
    !isnothing(registry.user_root) && push!(roots, registry.user_root)
    unique(roots)
end

"""Treat an unreadable or malformed entry as absent without losing other skill sources."""
function observe_skill_file(callback::Function, path::AbstractString)
    worker = Task(callback)
    schedule(worker)
    wait(worker; throw=false)
    if istaskfailed(worker)
        exceptions = Base.current_exceptions(worker)
        reason = isempty(exceptions) ? "Unknown read failure" : sprint(showerror, last(exceptions).exception)
        @warn "Skipping filesystem skill" path reason
        nothing
    else
        fetch(worker)
    end
end

"""Read only a bounded frontmatter prefix when producing the discovery catalog."""
function filesystem_skill_header(path::AbstractString)
    prefix = open(path, "r") do input
        read(input, 8193)
    end
    while !isempty(prefix) && !isvalid(String, prefix)
        pop!(prefix)
    end
    isempty(prefix) && return nothing
    parts = prompt_frontmatter_parts(String(prefix))
    isnothing(parts.yaml) ? nothing : (yaml=parts.yaml, metadata=prompt_yaml_metadata(parts.yaml))
end

"""Accept simple YAML boolean spellings, rejecting ambiguous invocation policy."""
function filesystem_skill_boolean(yaml::AbstractString, field::AbstractString, default::Bool)
    found = match(Regex("(?m)^" * field * ":[ \\t]*([^\\r\\n#]*)"), yaml)
    if isnothing(found)
        return occursin(field, yaml) ? nothing : default
    end
    value = strip(String(found.captures[1]))
    if length(value) >= 2 && first(value) == last(value) && first(value) in ('"', '\'')
        value = value[2:end-1]
    end
    normalized = lowercase(value)
    normalized in ("true", "yes", "on", "1") ? true :
        normalized in ("false", "no", "off", "0") ? false : nothing
end

function filesystem_skill_entry(path::AbstractString, name::AbstractString, header)
    isnothing(header) && return nothing
    occursin(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", name) || return nothing
    get(header.metadata, "name", "") == name || return nothing
    description = strip(replace(get(header.metadata, "description", ""), r"\s+" => " "))
    isempty(description) && return nothing
    disabled = filesystem_skill_boolean(header.yaml, "disable-model-invocation", false)
    user = filesystem_skill_boolean(header.yaml, "user-invocable", true)
    if isnothing(disabled) || isnothing(user)
        nothing
    else
        FilesystemSkillEntry(Symbol(name), description, String(path), !disabled, user)
    end
end

"""Recognize only direct flat Markdown skills and named SKILL.md directories."""
function filesystem_skill_candidate(root::AbstractString, entry::AbstractString)
    path = joinpath(root, entry)
    if islink(path)
        nothing
    elseif isdir(path)
        body = joinpath(path, "SKILL.md")
        isfile(body) && !islink(body) ? (name=String(entry), path=body) : nothing
    elseif endswith(entry, ".md") && isfile(path)
        (name=first(String(entry), length(entry) - 3), path=path)
    else
        nothing
    end
end

function filesystem_skill_entries(registry::FilesystemSkillRegistry, workspace::AbstractString)
    entries = FilesystemSkillEntry[]
    names = Set{Symbol}()
    for root in filesystem_skill_roots(registry, workspace)
        (isdir(root) && !islink(root)) || continue
        files = observe_skill_file(() -> sort!(readdir(root)), root)
        isnothing(files) && continue
        for filename in files
            candidate = filesystem_skill_candidate(root, filename)
            isnothing(candidate) && continue
            header = observe_skill_file(() -> filesystem_skill_header(candidate.path), candidate.path)
            entry = filesystem_skill_entry(candidate.path, candidate.name, header)
            if !isnothing(entry) && !(entry.name in names)
                push!(entries, entry)
                push!(names, entry.name)
            end
        end
    end
    entries
end

"""Merge the native filesystem catalog with registered skills without exposing instructions."""
function skill_catalog(registry::FilesystemSkillRegistry, workspace::AbstractString=pwd(); audience::Symbol=:model)
    rows = skill_catalog(registry.registered, workspace; audience)
    seen = Set(entry.name for entry in skill_catalog(registry.registered, workspace; audience=:all))
    for entry in filesystem_skill_entries(registry, workspace)
        if !(entry.name in seen)
            push!(seen, entry.name)
            skill_visible(entry, Val(audience)) && push!(rows, (name=entry.name, description=entry.description))
        end
    end
    sort!(rows; by=entry -> entry.name)
end

"""Read the selected body afresh, revalidating visibility after edits to SKILL.md."""
function filesystem_skill_load(entry::FilesystemSkillEntry, audience::Symbol)
    observed = observe_skill_file(entry.path) do
        raw = prompt_read_file(entry.path)
        parts = prompt_frontmatter_parts(raw)
        header = isnothing(parts.yaml) ? nothing :
            (yaml=parts.yaml, metadata=prompt_yaml_metadata(parts.yaml))
        current = filesystem_skill_entry(entry.path, String(entry.name), header)
        isnothing(current) ? nothing : (entry=current, body=parts.body)
    end
    if isnothing(observed)
        skill_load_failure("Skill $(entry.name) is no longer readable or valid")
    elseif !skill_visible(observed.entry, Val(audience))
        skill_load_failure("Skill $(entry.name) is not available for $audience")
    elseif isempty(observed.body)
        skill_load_failure("Skill $(entry.name) has no instructions")
    else
        (ok=true, reason="", instructions=observed.body)
    end
end

"""Load in-memory skills first; discover files relative to the current Julia workspace."""
function load_skill(registry::FilesystemSkillRegistry, name::Union{Symbol,AbstractString},
        workspace::AbstractString=pwd(); audience::Symbol=:model)
    identity = Symbol(name)
    if any(entry -> entry.name == identity,
            skill_catalog(registry.registered, workspace; audience=:all))
        return load_skill(registry.registered, identity, workspace; audience)
    end
    entries = filesystem_skill_entries(registry, workspace)
    index = findfirst(entry -> entry.name == identity, entries)
    if isnothing(index)
        skill_load_failure("Unknown skill: $name")
    elseif !skill_visible(entries[index], Val(audience))
        skill_load_failure("Skill $name is not available for $audience")
    else
        filesystem_skill_load(entries[index], audience)
    end
end

"""Offer filesystem skills as a replaceable Julia service, with no external runtime."""
function filesystem_skill_plugin(; name=:filesystem_skills, service_name=:skills,
        factory=FilesystemSkillRegistry)
    contract = Symbol(service_name)
    setup = context -> provide!(context, contract, Base.invokelatest(factory))
    PluginSpec(name, setup; provides=[contract])
end
