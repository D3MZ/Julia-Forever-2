# Host adapter owns factual records separately from persistent model conversation messages.
public StartupControls, startup_controls, startup_discover_resources!, startup_registered_resource!
public startup_control_rows, startup_control_scene

Base.@kwdef mutable struct StartupControls
    document::StartupDocument
    disk_keys::Set{Tuple{Symbol,String}} = Set{Tuple{Symbol,String}}()
    disk_diagnostics::Vector{StartupDiagnostic} = StartupDiagnostic[]
    disk_registrations::Dict{Tuple{Symbol,String},Tuple{UInt,Any}} = Dict{Tuple{Symbol,String},Tuple{UInt,Any}}()
end

"""Create startup state from the actual app preferences; callers supply implemented keybindings."""
function startup_controls(app;bindings::Dict{String,String},verbose::Bool=false,brand::AbstractString="Julia Forever 2",logo::Bool=false,supported::AbstractVector{<:AbstractString}=String[])
    preference=menu_preference(app,"quiet-startup","false")
    quiet=preference=="true" ? true : preference=="header" ? :header : false
    capabilities=Set{String}([collect(keys(bindings));String.(supported);"commands"])
    document=StartupDocument(;brand=String(brand),logo,verbose,quiet,bindings=copy(bindings),capabilities,cwd=app.settings.workspace)
    StartupControls(;document)
end

"""Record a confirmed registration, preserving real replacement ownership and collision facts."""
function startup_registered_resource!(controls::StartupControls,item::StartupResource)
    doc=controls.document
    matches=entry->entry.kind==item.kind && (item.kind in (:skill,:prompt) ? entry.name==item.name : entry.path==item.path)
    index=findfirst(matches,doc.resources)
    if isnothing(index)
        push!(doc.resources,item)
    else
        previous=doc.resources[index]
        if previous.path!=item.path && item.kind in (:skill,:prompt)
            collision=StartupDiagnostic(;section=item.kind,severity=:collision,name=item.name,winner=item.path,loser=previous.path)
            duplicate=any(d->d.section==collision.section && d.name==collision.name && d.winner==collision.winner && d.loser==collision.loser,doc.diagnostics)
            duplicate || push!(doc.diagnostics,collision)
        end
        doc.resources[index]=item
    end
    nothing
end

"""Remove only still-owned disk entries, preserving later API registrations and changed direct values."""
function startup_remove_disk_registrations!(controls::StartupControls,app)
    filter!(app.menus.skills) do item
        key=(:skill,item.name)
        current=(resource_registration_revision(app,:skill,item.name),item)
        !isequal(get(controls.disk_registrations,key,nothing),current)
    end
    filter!(app.menus.prompts) do item
        key=(:prompt,item.name)
        current=(resource_registration_revision(app,:prompt,item.name),item)
        !isequal(get(controls.disk_registrations,key,nothing),current)
    end
    empty!(controls.disk_registrations)
    nothing
end

"""Discover and register real skill/prompt files while retaining their exact loader provenance."""
function startup_discover_resources!(controls::StartupControls,app;directory::AbstractString=app.settings.workspace,
        agent_dir::AbstractString=joinpath(homedir(),".pi","agent"))
    startup_remove_disk_registrations!(controls,app)
    collector=StartupControls(;document=StartupDocument())
    for (scope,rootdir) in ((:user,String(agent_dir)),(:project,joinpath(directory,".pi")))
        skill_dir=joinpath(rootdir,"skills")
        if isdir(skill_dir)
            for (root,children,files) in walkdir(skill_dir;follow_symlinks=false)
                paths="SKILL.md" in files ? [joinpath(root,"SKILL.md")] : root==skill_dir ?
                    [joinpath(root,file) for file in files if endswith(file,".md")] : String[]
                for path in paths
                    fallback=basename(path)=="SKILL.md" ? basename(root) : splitext(basename(path))[1]
                    name=resource_metadata(path,"name",fallback);description=resource_metadata(path,"description")
                    registered=register_skill!(app,name,path;description)
                    controls.disk_registrations[(:skill,registered.name)]=(resource_registration_revision(app,:skill,registered.name),registered)
                    startup_registered_resource!(collector,StartupResource(;kind=:skill,name=registered.name,path=registered.path,source="local",scope))
                end
                "SKILL.md" in files && empty!(children)
            end
        end
    end
    for (scope,prompt_dir) in ((:user,joinpath(agent_dir,"prompts")),(:project,joinpath(directory,".pi","prompts")))
        if isdir(prompt_dir)
            for filename in filter(name->endswith(name,".md"),readdir(prompt_dir))
                path=joinpath(prompt_dir,filename)
                if isfile(path)
                    result=prompt_load_result(path)
                    if result.ok
                        prompt=result.value
                        registered=register_prompt!(app,prompt.name,prompt.description;content=prompt.content,path=prompt.file_path,argument_hint=prompt.argument_hint)
                        controls.disk_registrations[(:prompt,registered.name)]=(resource_registration_revision(app,:prompt,registered.name),registered)
                        startup_registered_resource!(collector,StartupResource(;kind=:prompt,name=registered.name,path=abspath(path),source="local",scope))
                    else
                        push!(collector.document.diagnostics,StartupDiagnostic(;section=:prompt,severity=:error,path,message=result.reason))
                    end
                end
            end
        end
    end
    filter!(item->!((item.kind,item.name) in controls.disk_keys),controls.document.resources)
    filter!(item->!(item in controls.disk_diagnostics),controls.document.diagnostics)
    append!(controls.document.resources,collector.document.resources)
    append!(controls.document.diagnostics,collector.document.diagnostics)
    controls.disk_keys=Set((item.kind,item.name) for item in collector.document.resources)
    controls.disk_diagnostics=copy(collector.document.diagnostics)
    controls.document.resources_expanded=nothing
    controls
end

"""Compose startup facts before real archived conversation rows, preserving their independent styles."""
function startup_control_rows(controls::StartupControls,app,width::Integer)
    runtime=app.menus.theme_runtime
    startup=startup_document_lines(controls.document,runtime,width)
    [startup;archive_transcript_lines!(app,width)]
end

"""Use original dock ordering with actual owner-provided pending, editor, status and footer rows."""
function startup_control_scene(controls::StartupControls,app,width::Integer,height::Integer;
        editor::Vector{Vector{Tachikoma.Span}},footer::Vector{Vector{Tachikoma.Span}},
        pending::Vector{Vector{Tachikoma.Span}}=Vector{Tachikoma.Span}[],
        status::Vector{Vector{Tachikoma.Span}}=Vector{Tachikoma.Span}[],
        above::Vector{Vector{Tachikoma.Span}}=[[Tachikoma.Span("",Tachikoma.Style())]],
        below::Vector{Vector{Tachikoma.Span}}=Vector{Tachikoma.Span}[],cursor_row::Union{Nothing,Int}=nothing)
    parts=[StartupDockPart(;name=:pending,lines=pending),StartupDockPart(;name=:status,lines=status),
        StartupDockPart(;name=:above,lines=above),StartupDockPart(;name=:editor,lines=editor,minimum=3,cursor_row),
        StartupDockPart(;name=:below,lines=below),StartupDockPart(;name=:footer,lines=footer)]
    prefix=startup_document_lines(controls.document,app.menus.theme_runtime,width)
    document=[prefix;archive_transcript_lines!(app,width)]
    scene=startup_scene(document,parts,height;scroll=app.scroll)
    scroll=clamp(app.scroll,0,max(0,length(document)-scene.document_height))
    first_document_row=max(1,length(document)-scroll-scene.document_height+1)
    archive_offset=min(scene.document_height,max(0,length(prefix)-first_document_row+1))
    (;scene...,startup_rows=length(prefix),first_document_row,
        archive_top=archive_offset+1,archive_height=max(0,scene.document_height-archive_offset),
        first_archive_row=max(1,first_document_row-length(prefix)))
end
