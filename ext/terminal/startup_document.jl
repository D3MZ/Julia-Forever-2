# Startup help/content interoperability: Pi MIT, see licenses/pi-LICENSE.
# All production state is Julia-owned; the original is a test-only oracle.
public StartupDocument, StartupResource, StartupDiagnostic, StartupStatus
public startup_document_lines, startup_header_visible, startup_details_visible, startup_tool_status, startup_status!, startup_set_expanded!, startup_resources!

Base.@kwdef struct StartupResource
    kind::Symbol
    name::String = ""
    path::String = ""
    source::String = ""
    scope::Symbol = :project
    base::String = ""
    hidden::Bool = false
end
Base.@kwdef struct StartupDiagnostic
    section::Symbol
    severity::Symbol = :warning
    message::String = ""
    path::String = ""
    name::String = ""
    winner::String = ""
    loser::String = ""
end
Base.@kwdef struct StartupStatus
    kind::Symbol = :info
    message::String
end
Base.@kwdef mutable struct StartupDocument
    version::String = string(pkgversion(JuliaForever2))
    brand::String = "Julia Forever 2"
    logo::Bool = false
    quiet::Union{Bool,Symbol} = false
    verbose::Bool = false
    expanded::Bool = false
    header_expanded::Union{Nothing,Bool} = nothing
    resources_expanded::Union{Nothing,Bool} = nothing
    bindings::Dict{String,String} = Dict{String,String}()
    capabilities::Union{Nothing,Set{String}} = nothing
    cwd::String = pwd()
    home::String = homedir()
    scoped_models::Vector{Pair{String,String}} = Pair{String,String}[]
    resources::Vector{StartupResource} = StartupResource[]
    diagnostics::Vector{StartupDiagnostic} = StartupDiagnostic[]
    statuses::Vector{StartupStatus} = StartupStatus[]
    force_resources::Bool = false
    diagnostics_when_quiet::Bool = false
end
startup_header_visible(doc::StartupDocument) = doc.verbose || doc.quiet!==true
startup_details_visible(doc::StartupDocument) = doc.verbose || doc.quiet===false
startup_expanded(doc::StartupDocument) = something(doc.header_expanded,doc.verbose || doc.expanded)
startup_resources_expanded(doc::StartupDocument) = something(doc.resources_expanded,doc.verbose || doc.expanded)
startup_style(::Nothing,key::Symbol) = Tachikoma.Style()
startup_style(runtime,key::Symbol) = key==:default ? Tachikoma.Style() : theme_token_style(runtime,String(key))
startup_add!(out,text,runtime,key::Symbol=:default) = startup_rich!(out,text,startup_style(runtime,key))
startup_break!(out) = startup_rich!(out,"\n")
startup_key(doc,id) = get(doc.bindings,id,"")
startup_hint_supported(doc,ids::Tuple) = isnothing(doc.capabilities) || all(id->id in doc.capabilities,ids)
startup_hint_supported(doc,id::String) = startup_hint_supported(doc,(id,))

"""Expose missing-tool facts only for an explicitly enabled native consumer and real offline policy."""
function startup_tool_status(tool::AbstractString;required::Bool,offline::Bool,find_tool=Sys.which)
    names=tool=="fd" ? ["fd","fdfind"] : [String(tool)]
    found=required ? any(name->!isnothing(find_tool(name)),names) : false
    label::String=tool=="rg" ? "ripgrep" : String(tool)
    if !required || found
        nothing
    elseif offline
        StartupStatus(;kind=:warning,message=label*" not found. Offline mode enabled, skipping download.")
    else
        StartupStatus(;kind=:warning,message=label*" not found. Install it to enable the configured external tool.")
    end
end

"""Render an explicitly requested compatibility logo; the default header retains the native identity."""
function startup_logo!(out,top::Bool)
    coral=Tachikoma.ColorRGB(228,138,122);blue=Tachikoma.ColorRGB(79,142,179);yellow=Tachikoma.ColorRGB(234,182,93)
    if top
        startup_rich!(out,"▀",Tachikoma.Style(;fg=coral,bg=blue))
        startup_rich!(out,"▀█",Tachikoma.Style(;fg=coral));startup_rich!(out," ")
    else
        startup_rich!(out,"█▀",Tachikoma.Style(;fg=blue));startup_rich!(out," ")
        startup_rich!(out,"█",Tachikoma.Style(;fg=yellow))
    end
    out
end

"""Build hints from actual bindings supplied by the host, rather than inventing working shortcuts."""
function startup_hint!(out,doc,runtime,key,description;raw::Bool=false)
    startup_add!(out,raw ? key : startup_key(doc,key),runtime,:dim)
    startup_add!(out," "*description,runtime,:muted)
end

"""Build compact or expanded startup help and factual product identity on demand for theme changes."""
function startup_header(doc::StartupDocument,runtime)
    out=StartupRichText()
    if doc.logo
        startup_logo!(out,true);startup_rich!(out," ")
        startup_add!(out,"v"*doc.version,runtime,:dim);startup_break!(out);startup_logo!(out,false);startup_rich!(out," ")
    else
        if doc.brand=="Pi"
            startup_rich!(out,"P",Tachikoma.Style(;fg=Tachikoma.ColorRGB(228,138,122)))
            startup_rich!(out,"i",Tachikoma.Style(;fg=Tachikoma.ColorRGB(234,182,93)))
        else
            startup_add!(out,doc.brand,runtime,:accent)
        end
        startup_rich!(out," ");startup_add!(out,"v"*doc.version,runtime,:dim);startup_break!(out)
    end
    if startup_expanded(doc)
        hints=[("app.interrupt","to interrupt",false),("app.clear","to clear",false),
            (startup_key(doc,"app.clear")*" twice","to exit",true),("app.exit","to exit (empty)",false),
            ("app.suspend","to suspend",false),("tui.editor.deleteToLineEnd","to delete to end",false),
            ("app.thinking.cycle","to cycle thinking level",false),
            (startup_key(doc,"app.model.cycleForward")*"/"*startup_key(doc,"app.model.cycleBackward"),"to cycle models",true),
            ("app.model.select","to select model",false),("app.tools.expand","to expand tools",false),
            ("app.thinking.toggle","to expand thinking",false),("app.editor.external","for external editor",false),
            ("/","for commands",true),("!","to run bash",true),("!!","to run bash (no context)",true),
            ("app.message.followUp","to queue follow-up",false),("app.message.dequeue","to edit all queued messages",false),
            ("app.clipboard.pasteImage","to paste files on macOS, images, or text",false),("drop files","to attach",true)]
        capabilities=[("app.interrupt",),("app.clear",),("app.clear",),("app.exit",),("app.suspend",),
            ("tui.editor.deleteToLineEnd",),("app.thinking.cycle",),("app.model.cycleForward","app.model.cycleBackward"),
            ("app.model.select",),("app.tools.expand",),("app.thinking.toggle",),("app.editor.external",),
            ("commands",),("bash",),("bash.noContext",),("app.message.followUp",),("app.message.dequeue",),
            ("app.clipboard.pasteImage",),("dropFiles",)]
        supported=[hint for (hint,capability) in zip(hints,capabilities) if startup_hint_supported(doc,capability)]
        for (index,(key,description,raw)) in enumerate(supported)
            index>1 && startup_break!(out)
            startup_hint!(out,doc,runtime,key,description;raw)
        end
    else
        hints=[("app.interrupt","interrupt",false),(startup_key(doc,"app.clear")*"/"*startup_key(doc,"app.exit"),"clear/exit",true),
            ("/","commands",true),("!","bash",true),("app.tools.expand","more",false)]
        capabilities=[("app.interrupt",),("app.clear","app.exit"),("commands",),("bash",),("app.tools.expand",)]
        supported=[hint for (hint,capability) in zip(hints,capabilities) if startup_hint_supported(doc,capability)]
        for (index,(key,description,raw)) in enumerate(supported)
            index>1 && startup_add!(out," · ",runtime,:muted)
            startup_hint!(out,doc,runtime,key,description;raw)
        end
        if startup_hint_supported(doc,"app.tools.expand")
            startup_break!(out)
            details=startup_details_visible(doc) ? " and loaded resources" : ""
            startup_add!(out,"Press "*startup_key(doc,"app.tools.expand")*" to show full startup help"*details*".",runtime,:dim)
        end
    end
    startup_break!(out);startup_break!(out)
    startup_add!(out,doc.brand*" can explain its own features and look up its docs. Ask it how to use or extend "*doc.brand*".",runtime,:dim)
    out
end

"""Compose header, real loaded-resource records and real status events in document order."""
function startup_document_lines(doc::StartupDocument,runtime,width::Integer)
    columns=Int(width);lines=Vector{Tachikoma.Span}[]
    blank()=Tachikoma.Span[Tachikoma.Span("",Tachikoma.Style())]
    if startup_header_visible(doc)
        push!(lines,blank());append!(lines,startup_text_lines(startup_header(doc,runtime),columns;padding=1));push!(lines,blank())
    end
    if startup_details_visible(doc) && !isempty(doc.scoped_models)
        value=join([id*(isempty(level) ? "" : ":"*level) for (id,level) in doc.scoped_models],", ")
        rich=startup_rich("Model scope: "*value,startup_style(runtime,:dim))
        key=startup_key(doc,"app.model.cycleForward")
        if !isempty(key)
            display=join([join(uppercasefirst.(split(part,'+')),'+') for part in split(key,'/')],'/')
            startup_add!(rich," ("*display*" to cycle)",runtime,:muted)
        end
        append!(lines,startup_text_lines(rich,columns;padding=1));push!(lines,blank())
    end
    append!(lines,startup_resource_lines(doc,runtime,columns))
    if !isempty(doc.statuses)
        managed=false
        for status in doc.statuses
            notice=status.kind==:notice
            (notice || !managed) && push!(lines,blank())
            !notice && (managed=true)
            warning=status.kind==:warning
            rich=startup_rich((warning ? "Warning: " : "")*status.message,startup_style(runtime,warning ? :warning : :dim))
            append!(lines,startup_text_lines(rich,columns;padding=1))
        end
    end
    lines
end

"""Record an observed status, coalescing only adjacent ordinary notices like the original UI."""
function startup_status!(doc::StartupDocument,message::AbstractString;kind::Symbol=:notice)
    status=StartupStatus(;kind,message=String(message))
    if kind==:notice && !isempty(doc.statuses) && last(doc.statuses).kind==:notice
        doc.statuses[end]=status
    else
        push!(doc.statuses,status)
    end
    nothing
end

"""Synchronize real tool-output expansion and record its corresponding document notice once."""
function startup_set_expanded!(doc::StartupDocument,expanded::Bool;on_notice=message->startup_status!(doc,message))
    if expanded!=doc.expanded
        doc.expanded=expanded
        doc.header_expanded=expanded
        doc.resources_expanded=expanded
        on_notice("Tool output: "*(expanded ? "expanded" : "collapsed"))
    end
    nothing
end

"""Replace real loader records idempotently and initialize only their new expansion state."""
function startup_resources!(doc::StartupDocument,resources::Vector{StartupResource};diagnostics::Vector{StartupDiagnostic}=doc.diagnostics)
    doc.resources=copy(resources)
    doc.diagnostics=copy(diagnostics)
    doc.resources_expanded=nothing
    nothing
end
