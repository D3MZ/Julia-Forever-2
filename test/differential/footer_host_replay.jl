function footer_host_model(value)
    JuliaForever2.ModelSpec(Symbol(value["provider"]),value["id"];api=value["api"],metadata=Dict("reasoning"=>value["reasoning"],"contextWindow"=>value["contextWindow"]))
end
function footer_host_buffer_rows(buffer,first_row,last_row)
    [sprint() do io
        for column in 1:buffer.area.width
            cell=buffer.content[Tachikoma.buf_index(buffer,column,row)]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style)
                print(io,Tachikoma.cell_glyph(cell),"\e[0m")
            end
        end
    end for row in first_row:last_row]
end
function footer_host_render_adapter()
    source=joinpath(dirname(pathof(JuliaForever2)),"..","ext","terminal","startup_host.jl")
    @test isdefined(FooterHost,:startup_host_scene)
    (;path=source,sha256=bytes2hex(sha256(read(source))))
end
function footer_host_replay(original,fixtures,evidence;cell_fixture,fresh_reference=false)
    source=footer_host_render_adapter()
    root=dirname(dirname(pathof(JuliaForever2)))
    paths=[joinpath(directory,file) for parent in (joinpath(root,"src"),joinpath(root,"ext")) for (directory,_,files) in walkdir(parent) for file in files if endswith(file,".jl")]
    hashes=Dict(relpath(path,root)=>bytes2hex(sha256(read(path))) for path in paths)
    write(joinpath(evidence,"native-source-provenance.json"),JSON.json((root=root,sourceHashes=hashes,helperSha256=bytes2hex(sha256(read(footer_host_file))))))
    frames=Any[]
    contexts=Any[]
    failures=Any[]
    for fixture in fixtures["cases"]
        mktempdir() do directory
            mkpath(fixture["cwd"])
            models=footer_host_model.(fixture["availableModels"])
            current=footer_host_model(get(fixture,"replacementModel",fixture["model"]))
            backend=JuliaForever2.ModelProvider(current,Returns(nothing))
            provider=JuliaForever2.ConfiguredModelProvider(backend,current,fixture["thinking"])
            kernel=get(fixture,"noModel",false) ? JuliaForever2.Kernel() : JuliaForever2.default_kernel(provider)
            registry=JuliaForever2.ProviderRegistry()
            session=JuliaForever2.Session(kernel;working_directory=fixture["cwd"])
            app=FooterHost.App(session;settings_dir=directory,registry,theme_fallback="dark")
            timeline=JuliaForever2.SessionTimeline(fixture["cwd"];id=fixture["id"],timestamp="2026-11-01T00:00:00.000Z")
            for entry in fixture["entries"]
                payload=Dict(key=>value for (key,value) in entry if !(key in ("id","parentId","timestamp")))
                JuliaForever2.timeline_append!(timeline,payload;id=entry["id"],timestamp=entry["timestamp"])
            end
            JuliaForever2.timeline_branch!(timeline,get(fixture,"selectedLeaf",fixture["leaf"]))
            app.archive.timeline=timeline
            state=FooterHost.FooterHostState()
            subscriptions=Dict(Symbol(name)=>true for name in get(fixture,"verifiedSubscriptions",[]))
            FooterHost.refresh_footer_controls!(app,state;models=get(fixture,"noModel",false) ? JuliaForever2.ModelSpec[] : models,subscriptions,branch=fixture["branch"],home=fixture["home"])
            state.statuses=Pair{String,String}[pair[1]=>pair[2] for pair in get(fixture,"extraStatuses",fixture["statuses"])]
            for theme in fixtures["themes"],width in fixtures["widths"]
                FooterHost.theme_preview!(app.menus.theme_runtime,theme)
                snapshot=FooterHost.footer_control_snapshot(app,state)
                id=fixture["id"]*"."*theme
                expected=only(filter(frame->frame["id"]==id && frame["width"]==width,original["snapshots"]))
                percent=isnothing(snapshot.context) ? nothing : snapshot.context.percent
                expected_percent=isnothing(expected["context"]) ? nothing : expected["context"]["percent"]
                if percent!=expected_percent
                    push!(failures,(id=id,width=width,percent=percent,expected=expected_percent))
                end
                height=24
                buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,height))
                frame=Tachikoma.Frame(buffer,buffer.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
                app.transcript.footer=state
                Tachikoma.view(app,frame)
                rows=length(FooterHost.footer_control_lines(app,width,state))
                @test isempty(TerminalCellFixture.differences(buffer,cell_fixture,id,width;first_row=height-rows+1))
                push!(frames,(id=id,width=width,ansiLines=footer_host_buffer_rows(buffer,height-rows+1,height)))
                push!(contexts,(id=id,width=width,percent=percent,tokens=state.context_tokens,scans=state.scans,source="actual App and proposed exact-source host hook"))
                @test state.scans==1
                @test snapshot.cwd==JuliaForever2.working_directory(session)
                @test snapshot.subscription==haskey(subscriptions,:fixture)
            end
            before=state.scans
            JuliaForever2.timeline_name!(timeline,"Updated actual name")
            renamed=FooterHost.footer_control_snapshot(app,state)
            @test renamed.name=="Updated actual name" && state.scans==before+1
            gate,release,done=Channel{Nothing}(1),Channel{Nothing}(1),Channel{Any}(1)
            holder=Threads.@spawn lock(session.runtime.execution_lock) do
                put!(gate,nothing);take!(release)
            end
            take!(gate)
            render=Threads.@spawn put!(done,FooterHost.footer_control_snapshot(app,state))
            ready=timedwait(()->isready(done),5.0)
            put!(release,nothing);wait(holder);wait(render)
            @test ready==:ok
            close(session);close(kernel)
        end
    end
    @test isempty(failures)
    write(joinpath(evidence,"context-differences.json"),JSON.json((failures=failures,contexts=contexts)))
    write(joinpath(evidence,"native.json"),JSON.json((snapshots=frames,)))
    write(joinpath(evidence,"reference.json"),JSON.json((snapshots=original["snapshots"],)))
    write(joinpath(evidence,"host-source.json"),JSON.json(source))
    @test bytes2hex(sha256(read(source.path)))==source.sha256
    @test all(pair->bytes2hex(sha256(read(joinpath(root,first(pair)))))==last(pair),hashes)
    comparator=joinpath(@__DIR__,"..","..","parity","compare_terminal_cells.mjs")
    reference,native,result=joinpath.(evidence,("reference.json","native.json","cells.json"))
    if fresh_reference
        run(`node $comparator $reference $native $result`)
        cells=JSON.parsefile(result)
        @test cells["checked"]==130 && cells["matching"]==130
        @test isempty(cells["failures"]) && isempty(cells["missingFrames"])
    end
end
