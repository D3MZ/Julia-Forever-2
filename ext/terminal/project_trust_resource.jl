"""Open a child descriptor without following a symlink, keeping ancestry bound to the prior descriptor."""
function project_resource_openat(parent::Base.Filesystem.File,name::String,directory::Bool)
    flags=Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_CLOEXEC |
        (directory ? Base.Filesystem.JL_O_DIRECTORY : Base.Filesystem.JL_O_NONBLOCK)
    descriptor=ccall(:openat,Cint,(Cint,Cstring,Cint),fd(parent),name,flags)
    descriptor>=0 || error("Project resource path is unavailable or contains a symlink")
    Base.Filesystem.File(Base.RawFD(descriptor))
end

"""Read one regular bounded UTF-8 resource through descriptor-relative no-follow traversal on supported native hosts."""
function project_resource_read_bound(path::String)
    supported=Sys.isunix() && all(!iszero,(Base.Filesystem.JL_O_NOFOLLOW,Base.Filesystem.JL_O_DIRECTORY,
        Base.Filesystem.JL_O_CLOEXEC,Base.Filesystem.JL_O_NONBLOCK))
    supported || error("Secure project resource reads are unavailable on this host; project resources remain blocked")
    ncodeunits(path)<=PROMPT_PATH_LIMIT || error("Project resource path exceeds the byte limit")
    files=Base.Filesystem.File[]
    result=preference_attempt() do
        flags=Base.Filesystem.JL_O_RDONLY | Base.Filesystem.JL_O_DIRECTORY | Base.Filesystem.JL_O_NOFOLLOW | Base.Filesystem.JL_O_CLOEXEC
        push!(files,Base.Filesystem.open("/",flags))
        parts=filter(!isempty,split(path,'/'))
        for (index,part) in enumerate(parts)
            push!(files,project_resource_openat(last(files),String(part),index<length(parts)))
        end
        file=last(files)
        metadata=stat(file)
        isfile(metadata) || error("Project resource is not a regular file")
        metadata.size<=PROMPT_RESOURCE_LIMIT || error("Project resource exceeds the byte limit")
        data=read(file,PROMPT_RESOURCE_LIMIT+1)
        length(data)<=PROMPT_RESOURCE_LIMIT || error("Project resource exceeds the byte limit")
        isvalid(String,data) || error("Project resource is not valid UTF-8")
        String(data)
    end
    for file in reverse(files)
        close(file)
    end
    result.ok || error(result.reason)
    result.value::String
end

"""Revalidate project admission and bind the read to canonical no-follow descriptor traversal."""
function project_resource_read(app::App,path::AbstractString;directory::AbstractString=app.settings.workspace)
    target=project_resource_path(app,path;directory)
    isnothing(target) && error("Project resource is not admitted")
    project_resource_read_bound(target)
end

"""Recognize only the unchanged disk-owned project registration, not explicit user/global API replacements."""
function project_owned_skill(app::App,path::String)
    controls=app.menus.startup
    if isnothing(controls)
        false
    else
        any(app.menus.skills) do skill
            key=(:skill,skill.name)
            registration=(resource_registration_revision(app,:skill,skill.name),skill)
            skill.path==path && isequal(get(controls.disk_registrations,key,nothing),registration) &&
                any(item->item.kind==:skill && item.scope==:project && item.name==skill.name && item.path==path,controls.document.resources)
        end
    end
end

"""Project skill invocations read current safe content; explicit and global registrations keep their existing reader contract."""
project_skill_read(app::App,path::String)=project_owned_skill(app,path) ? project_resource_read(app,path) : prompt_read_file(path)
