using Test,JSON,SHA,Tachikoma,JuliaForever2,CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
module StartupDocumentNativeTests
using JSON,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const MenuSearchInput=Owner.MenuSearchInput
const MENU_SEARCH_ANSI=Owner.MENU_SEARCH_ANSI
const menu_search_graphemes=Owner.menu_search_graphemes
const menu_search_width=Owner.menu_search_width
const theme_token_style=Owner.theme_token_style
const menu_preference=Owner.menu_preference
const resource_metadata=Owner.resource_metadata
const prompt_load_result=Owner.prompt_load_result
const register_skill! = Owner.register_skill!
const register_prompt! = Owner.register_prompt!
const archive_transcript_lines! = Owner.archive_transcript_lines!
const working_directory=JuliaForever2.working_directory
include(joinpath(@__DIR__,"..","ext","terminal","startup_text.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","startup_document.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","startup_resources.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","startup_viewport.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","resource_registration.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","startup_controls.jl"))
end
const StartupNative=StartupDocumentNativeTests

"""Map source-only fixture records into native factual domain types."""
function startup_test_document(config)
    N=StartupNative;resources=N.StartupResource[];diagnostics=N.StartupDiagnostic[]
    for (field,kind) in (("context",:context),("skills",:skill),("prompts",:prompt),("extensions",:extension))
        for item in config[field]
            source=get(item,"sourceInfo",Dict())
            push!(resources,N.StartupResource(;kind,name=get(item,"name",""),path=get(item,"filePath",get(item,"path","")),
                source=get(source,"source",""),scope=Symbol(get(source,"scope","project")),base=get(source,"baseDir",""),hidden=get(item,"hidden",false)))
        end
    end
    for (field,section) in (("skillDiagnostics",:skill),("promptDiagnostics",:prompt),("themeDiagnostics",:theme),("extensionDiagnostics",:extension))
        for item in config[field]
            collision=get(item,"collision",Dict())
            push!(diagnostics,N.StartupDiagnostic(;section,severity=Symbol(get(item,"type",haskey(item,"error") ? "error" : "warning")),
                path=get(item,"path",""),message=get(item,"message",get(item,"error","")),name=get(collision,"name",""),
                winner=get(collision,"winnerPath",""),loser=get(collision,"loserPath","")))
        end
    end
    N.StartupDocument(;version=config["version"],brand="Pi",logo=config["logo"],quiet=config["quiet"] isa Bool ? config["quiet"] : Symbol(config["quiet"]),
        verbose=config["verbose"],expanded=config["expanded"],bindings=Dict{String,String}(config["bindings"]),cwd=config["cwd"],home=config["home"],
        scoped_models=Pair{String,String}[item["model"]["id"]=>get(item,"thinkingLevel","") for item in config["scopedModels"]],resources,diagnostics,
        statuses=N.StartupStatus[N.StartupStatus(;kind=Symbol(item["type"]),message=item["message"]) for item in config["statuses"]],
        force_resources=config["force"],diagnostics_when_quiet=config["diagnosticsWhenQuiet"])
end

"""Serialize genuine native styles for independent terminal-cell normalization."""
startup_test_ansi(lines) = [sprint() do io
    for span in line
        Tachikoma.write_style(io,span.style);print(io,span.content,"\e[0m")
    end
end for line in lines]

"""Render actual native cells for offline source-derived visual comparisons."""
function startup_test_native_buffer(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(1,length(lines))))
    StartupNative.startup_document_draw!(buffer,1,1,width,lines)
    buffer
end

"""Serialize the actual native buffer, retaining wide and combining glyph cells."""
function startup_test_buffer(lines,width)
    buffer=startup_test_native_buffer(lines,width)
    [sprint() do io
        for x in 1:width
            cell=buffer.content[(y-1)*width+x]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
            end
        end
        print(io,"\e[0m")
    end for y in eachindex(lines)]
end

@testset "Source-original startup documents and docked menu scenes" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    mktempdir() do directory
            output=joinpath(@__DIR__,"fixtures","pi-startup-document-original.json")
            @test bytes2hex(sha256(read(output)))=="9fbcee311abe5d1b745a24c1cc3890f000e31589839bfca11343367631c82f6c"
            original=JSON.parsefile(output)
            cells_fixture=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-startup-document-cells.json"))
            @test cells_fixture["sourceSha256"]==bytes2hex(sha256(read(output)))
            @test original["provenance"]["checkedSourceFiles"]==513
            @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
            if isdir(reference)
                oracle=joinpath(@__DIR__,"differential","pi_startup_document_oracle.mjs")
                provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
                fresh=joinpath(directory,"original.json")
                run(`node $oracle $reference $provenance $fresh`)
                @test JSON.parsefile(fresh)==original
            end
            for probe in original["toolProbes"]
                mktempdir() do toolsdir
                    withenv("PATH"=>toolsdir) do
                        if !isnothing(probe["present"])
                            path=joinpath(toolsdir,probe["present"]);write(path,"#!/bin/sh\nexit 0\n");chmod(path,0o700)
                        end
                        result=StartupNative.startup_tool_status(probe["tool"];required=true,offline=true)
                        @test isnothing(result)==probe["found"]
                        @test isnothing(result) ? isempty(probe["statuses"]) :
                            [(type=String(result.kind),message=result.message)]==[(type=status["type"],message=status["message"]) for status in probe["statuses"]]
                    end
                end
            end
            evidence=get(ENV,"STARTUP_EVIDENCE_DIR",directory);mkpath(evidence)
            expected=[];native=[];buffer_native=[];sequence_docs=Dict{Int,StartupNative.StartupDocument}()
            for case in original["cases"]
                width=case["width"];id=case["id"];config=case["config"]
                doc=if haskey(case,"action")
                    current=get!(sequence_docs,width) do
                        startup_test_document(case["sequenceInitial"])
                    end
                    action=case["action"]
                    if action["kind"]=="expand"
                        StartupNative.startup_set_expanded!(current,action["value"])
                    elseif action["kind"]=="resources"
                        StartupNative.startup_resources!(current,startup_test_document(config).resources)
                    end
                    current
                else
                    startup_test_document(config)
                end
                runtime=StartupNative.Owner.ThemeRuntime(StartupNative.Owner.theme_catalog("";preserve_extras=false);setting=config["theme"])
                lines=StartupNative.startup_document_lines(doc,runtime,width)
                @test length(lines)==case["documentRows"]
                @test isempty(TerminalCellFixture.differences(startup_test_native_buffer(lines,width),cells_fixture,id,width))
                push!(expected,only(filter(frame->frame["id"]==id&&frame["width"]==width,original["snapshots"])))
                push!(native,(id,width,ansiLines=startup_test_ansi(lines)))
                push!(buffer_native,(id,width,ansiLines=startup_test_buffer(lines,width)))
                if !get(case,"documentOnly",false)
                T=StartupNative.Owner
                app=T.App(;settings_dir=mktempdir());T.open_menu!(app,"settings")
                app.menus.theme_runtime=runtime;app.menus.preferences["theme"]="dark"
                app.menus.settings_cursor_style=T.theme_style(runtime,:accent)
                T.activate_theme_runtime!(runtime)
                menu=T.settings_lines(app,width)
                empty=Vector{Tachikoma.Span}[]
                spacer=[[Tachikoma.Span("",Tachikoma.Style())]]
                footer=StartupNative.startup_text_lines(StartupNative.startup_rich("fixture cwd\n0.0%/0 (auto)"),width)
                parts=[StartupNative.StartupDockPart(;name=:pending,lines=empty),StartupNative.StartupDockPart(;name=:status,lines=empty),
                    StartupNative.StartupDockPart(;name=:above,lines=spacer),StartupNative.StartupDockPart(;name=:editor,lines=menu,minimum=3,cursor_row=2),
                    StartupNative.StartupDockPart(;name=:below,lines=empty),StartupNative.StartupDockPart(;name=:footer,lines=footer)]
                scene=StartupNative.startup_control_scene(StartupNative.StartupControls(;document=doc),app,width,32;editor=menu,footer,cursor_row=2)
                @test scene.document_height==case["documentHeight"]
                @test [(r.top,r.height,r.first_row) for r in scene.rectangles]==[(r["top"],r["height"],r["first_row"]) for r in case["dockRects"]]
                sceneid=id*".scene"
                @test isempty(TerminalCellFixture.differences(startup_test_native_buffer(scene.lines,width),cells_fixture,sceneid,width))
                push!(expected,only(filter(frame->frame["id"]==sceneid&&frame["width"]==width,original["snapshots"])))
                push!(native,(id=sceneid,width,ansiLines=startup_test_ansi(scene.lines)))
                push!(buffer_native,(id=sceneid,width,ansiLines=startup_test_buffer(scene.lines,width)))
                close(app.session)
                end
            end
            for (name,frames) in (("reference",expected),("native",native),("native-buffer",buffer_native))
                write(joinpath(evidence,name*".json"),JSON.json((snapshots=frames,)))
            end
            cp(output,joinpath(evidence,"original-fresh.json");force=true)
            comparator=joinpath(dirname(dirname(pathof(JuliaForever2))),"parity","compare_terminal_cells.mjs")
            if isdir(reference)
            for name in ("native","native-buffer")
                ref=joinpath(evidence,"reference.json");candidate=joinpath(evidence,name*".json");report=joinpath(evidence,name*"-cells.json")
                run(`node $comparator $ref $candidate $report`)
                cells=JSON.parsefile(report)
                @test cells["checked"]==length(native) && cells["matching"]==length(native)
            end
        end
    end
end

@testset "Startup owns no fabricated resources or warnings" begin
    N=StartupNative
    doc=N.StartupDocument()
    @test doc.brand=="Julia Forever 2" && !doc.logo && isempty(doc.resources) && isempty(doc.statuses)
    @test N.startup_header_visible(doc) && N.startup_details_visible(doc)
    doc.quiet=:header
    @test N.startup_header_visible(doc) && !N.startup_details_visible(doc)
    doc.quiet=true
    @test !N.startup_header_visible(doc) && !N.startup_details_visible(doc)
    doc.verbose=true
    @test N.startup_header_visible(doc) && N.startup_details_visible(doc)
    N.startup_set_expanded!(doc,true);N.startup_set_expanded!(doc,true)
    @test length(doc.statuses)==1 && last(doc.statuses).message=="Tool output: expanded"
    N.startup_set_expanded!(doc,false)
    @test length(doc.statuses)==1 && last(doc.statuses).message=="Tool output: collapsed"
    notices=String[]
    N.startup_set_expanded!(doc,true;on_notice=message->push!(notices,message))
    @test notices==["Tool output: expanded"] && length(doc.statuses)==1
    N.startup_set_expanded!(doc,false;on_notice=message->push!(notices,message))
    @test !N.startup_expanded(doc) && !N.startup_resources_expanded(doc)
    N.startup_resources!(doc,N.StartupResource[])
    @test !N.startup_expanded(doc) && N.startup_resources_expanded(doc)
    N.startup_status!(doc,"fd missing";kind=:warning)
    N.startup_status!(doc,"Ready")
    @test length(doc.statuses)==3 && doc.statuses[2].kind==:warning
    mktempdir() do directory
        withenv("PATH"=>directory) do
            @test isnothing(N.startup_tool_status("fd";required=false,offline=true))
            missing=N.startup_tool_status("fd";required=true,offline=true)
            @test missing.kind==:warning && missing.message=="fd not found. Offline mode enabled, skipping download."
            @test occursin("Install it",N.startup_tool_status("fd";required=true,offline=false).message)
            path=joinpath(directory,"fd");write(path,"#!/bin/sh\nexit 0\n");chmod(path,0o700)
            @test isnothing(N.startup_tool_status("fd";required=true,offline=true))
        end
    end
    @test N.startup_display_path(N.StartupDocument(;home="/home/user"),"/home/user-other/path")=="/home/user-other/path"
    @test N.startup_display_path(N.StartupDocument(;home="/home/user"),"/home/user/path")=="~/path"
    @test N.startup_context_path(N.StartupDocument(;cwd="/project",home="/home/user"),"nested/AGENTS.md")=="nested/AGENTS.md"
end

@testset "Actual App startup records and archive composition" begin
    N=StartupNative;T=N.Owner
    mktempdir() do root
        project=joinpath(root,"project");user=joinpath(root,"user");settings=joinpath(root,"settings")
        global_skill=joinpath(user,"skills","review","SKILL.md")
        project_skill=joinpath(project,".pi","skills","review","SKILL.md")
        prompt=joinpath(project,".pi","prompts","ship.md")
        nested=joinpath(dirname(project_skill),"ignored","SKILL.md")
        for path in (global_skill,project_skill,prompt,nested)
            mkpath(dirname(path));write(path,"---\nname: review\ndescription: Actual disk fixture\n---\nbody")
        end
        session=JuliaForever2.Session(JuliaForever2.default_kernel();working_directory=project)
        app=T.App(session;settings_dir=settings)
        app.menus.preferences["quiet-startup"]="header"
        controls=N.startup_controls(app;bindings=Dict("app.tools.expand"=>"ctrl+o"))
        @test controls.document.quiet==:header && controls.document.cwd==project
        @test isempty(controls.document.resources) && isempty(controls.document.statuses)
        N.startup_discover_resources!(controls,app;directory=project,agent_dir=user)
        @test length(controls.document.resources)==2
        skill=only(filter(item->item.kind==:skill,controls.document.resources))
        @test skill.path==project_skill && skill.scope==:project && skill.name=="review"
        @test any(item->item.name=="review"&&item.path==project_skill,app.menus.skills)
        @test any(item->item.name=="ship",app.menus.prompts)
        @test length(controls.document.diagnostics)==1
        @test only(controls.document.diagnostics).winner==project_skill && only(controls.document.diagnostics).loser==global_skill
        @test !any(item->item.path==nested,controls.document.resources)
        N.startup_discover_resources!(controls,app;directory=project,agent_dir=user)
        @test length(controls.document.resources)==2 && length(controls.document.diagnostics)==1
        rm(dirname(project_skill);recursive=true);rm(prompt)
        N.startup_discover_resources!(controls,app;directory=project,agent_dir=user)
        @test only(app.menus.skills).path==global_skill
        @test isempty(app.menus.prompts)
        @test length(controls.document.resources)==1
        explicit=T.register_skill!(app,"review",global_skill;description="Actual disk fixture")
        rm(global_skill)
        N.startup_discover_resources!(controls,app;directory=project,agent_dir=user)
        @test only(app.menus.skills)===explicit
        @test isempty(controls.document.resources)
        controls.document.quiet=false
        document=N.startup_document_lines(controls.document,app.menus.theme_runtime,60)
        JuliaForever2.append_message!(app.session,JuliaForever2.Message(:user,"Actual durable conversation message"))
        rows=N.startup_control_rows(controls,app,60)
        @test rows[1:length(document)]==document
        @test any(line->occursin("Actual durable conversation message",join(span.content for span in line)),rows[length(document)+1:end])
        @test isempty(controls.document.statuses)
        scene=N.startup_control_scene(controls,app,60,32;editor=[[Tachikoma.Span("editor",Tachikoma.Style())]],footer=Vector{Tachikoma.Span}[])
        @test scene.first_archive_row>=1 && scene.archive_top>=1 && scene.archive_top+scene.archive_height-1<=scene.document_height
        @test scene.startup_rows==length(document)
        @test N.startup_style(nothing,:dim)==Tachikoma.Style()
        close(app.session)
    end
end
