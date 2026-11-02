using Test,JSON,SHA,JuliaForever2,Tachikoma,CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
const HostSceneTerminal=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const STARTUP_HOST_BASELINE=get(ENV,"STARTUP_HOST_BASELINE","false")=="true"
if STARTUP_HOST_BASELINE
    source=read(`git -C $(joinpath(@__DIR__,"..")) show 3161aac:ext/terminal/menus.jl`,String)
    firstpos=findfirst("function page_view!(app::App, ::Val{:pi_menu}",source).start
    lastpos=findnext("\nfunction page_mouse!",source,firstpos).start-1
    Base.include_string(HostSceneTerminal,source[firstpos:lastpos],"snapshot3161aac-menu-scene.jl")
end
function startup_host_test_document(config)
    N=HostSceneTerminal;resources=N.StartupResource[];diagnostics=N.StartupDiagnostic[]
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

"""Serialize actual App buffer cells for independent terminal normalization."""
function startup_host_buffer_ansi(buffer,width,height)
    T=HostSceneTerminal
    [sprint() do io
        for span in row
            Tachikoma.write_style(io,span.style);print(io,span.content)
        end
        print(io,"\e[0m")
    end for row in T.startup_buffer_rows(buffer,width,height)]
end

@testset "Original complete startup and actual App settings scene" begin
    T=HostSceneTerminal
    reference=get(ENV,"PI_REFERENCE","")
    @test isempty(reference) || isdir(reference)
    begin
        mktempdir() do temporary
            evidence=get(ENV,"STARTUP_HOST_EVIDENCE_DIR",temporary);mkpath(evidence)
            oracle=joinpath(@__DIR__,"differential","pi_startup_host_oracle.mjs")
            provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
            original_path=joinpath(evidence,"original-fullscene.json")
            fixture=joinpath(@__DIR__,"fixtures","pi-startup-host-original.json")
            cells_path=joinpath(@__DIR__,"fixtures","pi-startup-host-cells.json")
            cells_fixture=JSON.parsefile(cells_path)
            @test bytes2hex(sha256(read(cells_path)))=="d44048d5fd006031c46eb1c71dd4c04727702296c6e6fb3507a2c56a228ed369"
            @test bytes2hex(sha256(read(fixture)))=="2049c11d9aa9b91b71e5e53805159dbfdead010da507167e69d7a8d28c1ab1e8"
            @test cells_fixture["sourceSha256"]==bytes2hex(sha256(read(fixture)))
            original=JSON.parsefile(fixture)
            @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
            @test length(original["reference"]["sourceHashes"])==513
            if isdir(reference)
                run(`node $oracle $reference $provenance $original_path`)
                fresh=JSON.parsefile(original_path)
                @test fresh["reference"]==original["reference"]
                @test fresh["provenance"]==original["provenance"]
                @test fresh["snapshots"]==original["snapshots"]
                original=fresh
            end
            expected=[];actual=[];geometry=[]
            for (index,case) in enumerate(original["cases"])
                width=case["width"];id=case["id"]*".scene";config=case["config"]
                session=JuliaForever2.Session(JuliaForever2.Kernel();working_directory=temporary)
                app=T.App(session;settings_dir=joinpath(temporary,"settings-$index"),theme_fallback=config["theme"])
                app.settings.workspace=config["cwd"];app.directory=config["cwd"]
                app.menus.startup=T.StartupControls(;document=startup_host_test_document(config))
                T.refresh_footer_controls!(app;models=JuliaForever2.ModelSpec[],branch=nothing,home=config["home"])
                T.open_menu!(app,"settings")
                app.menus.preferences["theme"]="dark"
                T.activate_theme_runtime!(app.menus.theme_runtime)
                if haskey(case,"sequenceInitial")
                    prior_theme=T.ThemeRuntime(T.theme_catalog("";preserve_extras=false);setting=case["sequenceInitial"]["theme"])
                    app.menus.settings_cursor_style=T.theme_style(prior_theme,:accent)
                end
                area=Tachikoma.Rect(1,1,width,32);app.area=area
                buffer=Tachikoma.Buffer(area);frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
                T.page_view!(app,Val(:pi_menu),frame)
                scene=T.startup_host_scene(app,width,32)
                push!(geometry,(;id,width,rectangles=scene.rectangles,archive_top=scene.archive_top,archive_height=scene.archive_height))
                push!(actual,(id,width,terminalAnsiLines=startup_host_buffer_ansi(buffer,width,32)))
                push!(expected,only(filter(item->item["id"]==id&&item["width"]==width,original["snapshots"])))
                mismatches=TerminalCellFixture.differences(buffer,cells_fixture,id,width)
                @test STARTUP_HOST_BASELINE || isempty(mismatches)
                @test length(scene.lines)==32
                @test scene.archive_height==0
                close(app.session)
            end
            expected_path=joinpath(evidence,"reference.json");candidate_path=joinpath(evidence,"native.json");report=joinpath(evidence,"cells.json")
            write(expected_path,JSON.json((snapshots=expected,)));write(candidate_path,JSON.json((snapshots=actual,)))
            write(joinpath(evidence,"geometry.json"),JSON.json(geometry))
            comparator=joinpath(@__DIR__,"..","parity","compare_terminal_cells.mjs")
            if isdir(reference)
                run(pipeline(`node $comparator $expected_path $candidate_path $report`;stdout=devnull))
                result=JSON.parsefile(report)
                @test result["checked"]==length(actual)
                @test STARTUP_HOST_BASELINE ? result["differing"]>0 : result["differing"]==0
                @test STARTUP_HOST_BASELINE ? result["matching"]<length(actual) : result["matching"]==length(actual)
            end
        end
    end
end

@testset "Offline source cells retain glyph width and every style boundary" begin
    default=Any[0,-1,0,-1,false,false,false,false,false,false,false]
    pieces=[Any["👩‍",1,default...],Any["💻",1,default...]]
    joined=[Any["👩‍💻",2,default...],Any[" ",0,default...]]
    @test TerminalCellFixture.grapheme_cells(pieces)==TerminalCellFixture.grapheme_cells(joined)
    for index in 3:13
        changed=deepcopy(pieces)
        changed[2][index]=changed[2][index] isa Bool ? !changed[2][index] : changed[2][index]+1
        @test TerminalCellFixture.grapheme_cells(changed)!=TerminalCellFixture.grapheme_cells(joined)
    end
    changed=deepcopy(pieces);changed[2][2]=2
    @test TerminalCellFixture.grapheme_cells(changed)!=TerminalCellFixture.grapheme_cells(joined)
    changed=deepcopy(pieces);changed[2][1]="X"
    @test TerminalCellFixture.grapheme_cells(changed)!=TerminalCellFixture.grapheme_cells(joined)
end
