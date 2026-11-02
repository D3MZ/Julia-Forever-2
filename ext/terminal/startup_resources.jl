"""Shorten home descendants only, preserving unrelated path prefixes."""
function startup_display_path(doc::StartupDocument,path::AbstractString)
    value=String(path)
    home=normpath(doc.home)
    isabspath(value) && (normpath(value)==home || startswith(normpath(value),home*string(Base.Filesystem.path_separator))) ?
        (normpath(value)==home ? "~" : joinpath("~",relpath(value,home))) : value
end
startup_package(item::StartupResource) = startswith(item.source,"npm:") || startswith(item.source,"git:")

"""Resolve a resource's package-relative display path from supplied loader provenance."""
function startup_short_path(doc::StartupDocument,item::StartupResource)
    value=replace(item.path,'\\'=>'/')
    result=startup_display_path(doc,item.path)
    if startup_package(item) && !isempty(item.base)
        relative=relpath(abspath(item.path),abspath(item.base))
        nodebase=match(r"^(.*\/node_modules)\/(@?[^/]+(?:\/[^/]+)?)$",replace(item.base,'\\'=>'/'))
        same_root=!isnothing(nodebase) && startswith(value,string(nodebase.captures[1])*"/")
        if same_root || (!isempty(relative) && relative!="." && !startswith(relative,"..") && !isabspath(relative))
            result=replace(relative,'\\'=>'/')
        end
    end
    if result==startup_display_path(doc,item.path)
        npm=match(r"node_modules\/(@?[^/]+(?:\/[^/]+)?)\/(.*)",value)
        git=match(r"git\/[^/]+\/[^/]+\/(.*)",value)
        if !isnothing(npm) && startswith(item.source,"npm:")
            result=String(something(npm.captures[2],""))
        elseif !isnothing(git) && startswith(item.source,"git:")
            result=String(something(git.captures[1],""))
        end
    end
    result
end

"""Keep context order and make only current-directory descendants relative."""
function startup_context_path(doc::StartupDocument,path::AbstractString)
    full=normpath(isabspath(path) ? path : joinpath(doc.cwd,path));cwd=abspath(doc.cwd)
    full==cwd ? "." : startswith(full,cwd*string(Base.Filesystem.path_separator)) ? relpath(full,cwd) : startup_display_path(doc,full)
end
startup_extension_path(value::AbstractString) = replace(String(value),r"/index\.(ts|js)$"=>"")
startup_scope(item::StartupResource) = item.source=="cli" || item.scope==:temporary ? :path : item.scope in (:user,:project) ? item.scope : :path

"""Disambiguate compact non-package extension names using the shortest unique suffix."""
function startup_extension_labels(doc::StartupDocument,items::AbstractVector{StartupResource})
    localitems=filter(item->!startup_package(item),items)
    paths=[filter(x->!isempty(x)&&x!="~",split(replace(startup_extension_path(startup_display_path(doc,item.path)),'\\'=>'/'),'/')) for item in localitems]
    labels=String[]
    for item in items
        if startup_package(item)
            source=startswith(item.source,"npm:") ? item.source[5:end] : replace(item.source,r"^git:(?:https?://|ssh://)?[^/]+/"=>"")
            relative=startup_short_path(doc,item)
            relative=startswith(relative,"extensions/") ? relative[12:end] : relative
            stem,extension=splitext(basename(relative));directory=dirname(relative)
            label=stem=="index" ? (directory in (".","") ? source : source*":"*directory) : source*":"*relative
            push!(labels,label)
        else
            index=findfirst(candidate->candidate.path==item.path,localitems)
            segments=isnothing(index) ? split(replace(startup_display_path(doc,item.path),'\\'=>'/'),'/') : paths[index]
            label=join(segments,'/');found=false
            for count in 1:length(segments)
                candidate=join(segments[max(1,end-count+1):end],'/')
                unique=all(j->j==index || join(paths[j][max(1,end-count+1):end],'/')!=candidate,eachindex(paths))
                if !found && unique
                    label=candidate;found=true
                end
            end
            push!(labels,label)
        end
    end
    labels
end

"""Render scope and package groups from actual loader records in stable source order."""
function startup_groups(doc::StartupDocument,runtime,items::AbstractVector{StartupResource},kind::Symbol)
    out=StartupRichText();firstline=Ref(true)
    addline(text,token)=begin
        !firstline[] && startup_break!(out)
        firstline[]=false
        startup_add!(out,text,runtime,token)
    end
    for scope in (:project,:user,:path)
        group=filter(item->startup_scope(item)==scope,items)
        if !isempty(group)
            !firstline[] && startup_break!(out);firstline[]=false
            startup_rich!(out,"  ");startup_add!(out,String(scope),runtime,:accent)
            for item in sort(filter(item->!startup_package(item),group);by=item->item.path)
                path::String=kind==:prompt ? string("/",item.name) : startup_display_path(doc,item.path)
                kind==:extension && (path=startup_extension_path(path))
                addline("    "*path,:dim)
            end
            packages=sort(unique(item.source for item in group if startup_package(item)))
            for source in packages
                startup_break!(out);startup_rich!(out,"    ");startup_add!(out,source,runtime,:mdLink)
                for item in sort(filter(item->item.source==source,group);by=item->item.path)
                    path::String=kind==:prompt ? string("/",item.name) : startup_short_path(doc,item)
                    kind==:extension && (path=startup_extension_path(path))
                    addline("      "*path,:dim)
                end
            end
        end
    end
    out
end

"""Find exact or ancestor source information for a diagnostic without probing unloaded resources."""
function startup_diagnostic_path(doc::StartupDocument,path::AbstractString)
    matches=filter(item->!isempty(item.source) && !isempty(item.path) && (item.path==path || startswith(path,item.path*"/")),doc.resources)
    if isempty(matches)
        startup_display_path(doc,path)
    else
        item=last(sort(matches;by=item->length(item.path)))
        copied=StartupResource(;kind=item.kind,path=String(path),source=item.source,scope=item.scope,base=item.base)
        local_source=item.source=="local"
        label=local_source ? (item.scope==:user ? "user" : item.scope==:project ? "project" : item.scope==:temporary ? "path (temp)" : "path") :
            item.source=="cli" ? (item.scope==:temporary ? "path (temp)" : "path") :
            item.source*(item.scope in (:project,:user,:temporary) ? " ("*(item.scope==:temporary ? "temp" : String(item.scope))*")" : "")
        label*" "*startup_short_path(doc,copied)
    end
end

"""Format actual warnings and collisions, retaining the reference's nested reset behavior."""
function startup_diagnostics(doc::StartupDocument,runtime,items::AbstractVector{StartupDiagnostic})
    out=StartupRichText();firstline=Ref(true)
    line(text,token)=begin
        !firstline[] && startup_break!(out);firstline[]=false
        startup_add!(out,text,runtime,token)
    end
    collisions=filter(item->item.severity==:collision&&!isempty(item.name),items)
    for name in unique(item.name for item in collisions)
        group=filter(item->item.name==name,collisions)
        line("  \""*name*"\" collision:",:warning)
        for (index,path) in enumerate([first(group).winner;[item.loser for item in group]])
            startup_break!(out);startup_add!(out,"    ",runtime,:dim)
            startup_add!(out,index==1 ? "✓" : "✗",runtime,index==1 ? :success : :warning)
            # The original nested foreground reset leaves the remaining path terminal-default.
            startup_rich!(out," "*startup_diagnostic_path(doc,path)*(index==1 ? "" : " (skipped)"))
        end
    end
    for item in filter(item->item.severity!=:collision || isempty(item.name),items)
        token=item.severity==:error ? :error : :warning
        if !isempty(item.path)
            line("  "*startup_diagnostic_path(doc,item.path),token)
            line("    "*item.message,token)
        else
            line("  "*item.message,token)
        end
    end
    out
end

"""Rebuild resource listings idempotently; quiet mode affects visibility, never the recorded facts."""
function startup_resource_lines(doc::StartupDocument,runtime,width::Int)
    lines=Vector{Tachikoma.Span}[]
    listing=doc.force_resources || startup_details_visible(doc)
    if listing
        for (kind,name) in ((:context,"Context"),(:skill,"Skills"),(:prompt,"Prompts"),(:extension,"Extensions"))
            items=filter(item->item.kind==kind&&!item.hidden,doc.resources)
            if !isempty(items)
                kind==:context && push!(lines,[Tachikoma.Span("",Tachikoma.Style())])
                rich=startup_rich("["*name*"]",startup_style(runtime,:mdHeading));startup_break!(rich)
                if startup_resources_expanded(doc)
                    if kind==:context
                        for (index,item) in enumerate(items)
                            index>1 && startup_break!(rich)
                            startup_add!(rich,"  "*startup_display_path(doc,item.path),runtime,:dim)
                        end
                    else
                        append!(rich,startup_groups(doc,runtime,items,kind))
                    end
                else
                    labels=kind==:context ? [startup_context_path(doc,item.path) for item in items] :
                        kind==:extension ? startup_extension_labels(doc,items) : [kind==:prompt ? "/"*item.name : item.name for item in items]
                    labels=filter(!isempty,strip.(labels));kind!=:context && sort!(labels)
                    startup_add!(rich,"  "*join(labels,", "),runtime,:dim)
                end
                append!(lines,startup_text_lines(rich,width));push!(lines,[Tachikoma.Span("",Tachikoma.Style())])
            end
        end
    end
    if listing || doc.diagnostics_when_quiet
        for (section,name) in ((:skill,"Skill warnings"),(:prompt,"Prompt conflicts"),(:extension,"Extension issues"),(:theme,"Theme conflicts"))
            items=filter(item->item.section==section,doc.diagnostics)
            if !isempty(items)
                rich=startup_rich("["*name*"]",startup_style(runtime,:warning));startup_break!(rich)
                append!(rich,startup_diagnostics(doc,runtime,items))
                append!(lines,startup_text_lines(rich,width));push!(lines,[Tachikoma.Span("",Tachikoma.Style())])
            end
        end
    end
    lines
end
