using Test,JSON,JuliaForever2,Tachikoma,CommonMark
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
const NoticeOwner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
@testset "Source-pinned chronological status notices" begin
    T=NoticeOwner
    original=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-frontend-notice.json"))
    cells=JSON.parsefile(joinpath(@__DIR__,"fixtures","pi-frontend-notice-cells.json"))
    reference=get(ENV,"PI_REFERENCE","")
    @test original["reference"]["commit"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    if isdir(reference)
        mktempdir() do dir
            output=joinpath(dir,"original.json")
            run(`node $(joinpath(@__DIR__,"differential","pi_frontend_notice_oracle.mjs")) $reference $(joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")) $output`)
            @test JSON.parsefile(output)==original
        end
    end
    snapshots=[]
    for width in (5,10,30,60,100)
        state=T.FrontendNoticeState();owner="one";anchor=nothing;documents=0
        markers=NamedTuple[]
        runtime=T.ThemeRuntime(T.theme_catalog("";preserve_extras=false);setting="dark");T.activate_theme_runtime!(runtime)
        for (index,event) in enumerate(original["events"])
            action,value=event
            if action=="notice"
                T.frontend_notice!(state,owner,anchor,value;documents)
            elseif action=="theme"
                runtime=T.ThemeRuntime(T.theme_catalog("";preserve_extras=false);setting=value);T.activate_theme_runtime!(runtime)
            elseif action=="reset"
                owner="two";anchor=nothing;documents=0;empty!(markers);T.frontend_notice_owner!(state,owner)
            else
                action=="record" && (anchor="record-$index")
                action=="document" && (documents+=1)
                push!(markers,(;anchor,documents,text=value))
            end
            rows=T.SessionDisplayRows()
            append_notices=(a,d)->foreach(n->(isequal(n.anchor,a)&&n.preceding_documents==d&&append!(rows,T.frontend_notice_rows(n,width))),state.notices)
            append_notices(nothing,0)
            for marker in markers
                append!(rows,T.startup_text_lines(T.startup_rich(marker.text),width;padding=1))
                append_notices(marker.anchor,marker.documents)
            end
            expected=only(filter(x->x["id"]=="notice.$(index-1)"&&x["width"]==width,cells["snapshots"]))
            buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,max(length(rows),length(expected["rows"]))))
            T.startup_document_draw!(buffer,1,1,width,rows)
            id="notice.$(index-1)"
            if action=="theme"
                # Original rewrites ALL old notice texts through a shared mutable closure.
                @test_broken isempty(TerminalCellFixture.differences(buffer,cells,id,width))
                @test first(state.notices).message=="TUI mode: regular"
            else
                @test isempty(TerminalCellFixture.differences(buffer,cells,id,width))
            end
            ansi=[sprint(io->(foreach(span->(Tachikoma.write_style(io,span.style);print(io,span.content)),line);print(io,"\e[0m"))) for line in T.startup_buffer_rows(buffer,width,length(rows))]
            push!(snapshots,(;id,width,terminalAnsiLines=ansi))
        end
    end
    path=get(ENV,"NOTICE_NATIVE_OUTPUT","")
    isempty(path)||write(path,JSON.json((;snapshots)))
end

@testset "Actual App notices are transactional and history-independent" begin
    T=NoticeOwner
    mktempdir() do directory
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=directory);settings_dir=directory)
        timeline=app.archive.timeline
        before=JuliaForever2.timeline_entries(timeline);context=JuliaForever2.timeline_context(timeline)
        app.status="unrelated status"
        T.frontend_notice!(app,"first");T.frontend_notice!(app,"second")
        @test length(app.transcript.notices.notices)==1
        @test app.status=="unrelated status"
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"actual record"))
        T.frontend_notice!(app,"after user")
        @test length(app.transcript.notices.notices)==2
        text=join(join(span.content for span in row) for row in T.archive_transcript_lines!(app,40))
        @test findfirst("second",text).start<findfirst("actual record",text).start<findfirst("after user",text).start
        @test !any(entry->occursin("after user",JSON.json(entry)),JuliaForever2.timeline_entries(timeline))
        terminal=Tachikoma.Terminal(;io=IOBuffer(),size=(rows=12,cols=40));app.settings.terminal=terminal;T.initialize_terminal_presentation!(app,terminal)
        T.set_setting_value!(app,"tui-mode","regular")
        @test last(app.transcript.notices.notices).message=="TUI mode: regular"
        @test app.status=="unrelated status"
        notices=copy(app.transcript.notices.notices)
        T.terminal_presentation_pause!(app);T.set_setting_value!(app,"tui-mode","fullscreen")
        @test app.transcript.notices.notices==notices
        @test app.settings.presentation.mode==:regular
        T.terminal_presentation_resume!(app)
        # A live response notice moves only after its actual archived response is present.
        app.transcript.preview=JuliaForever2.ResponseProgress(:answer,"streaming")
        app.transcript.preview_operation_id=UInt64(71)
        T.frontend_notice!(app,"after live response")
        @test last(app.transcript.notices.notices).operation==71
        @test !isempty(T.frontend_preview_notice_rows(app,40))
        JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>"committed answer"))
        T.clear_preview!(app)
        @test last(app.transcript.notices.notices).operation==0
        rows=T.archive_transcript_lines!(app,40);text=join(join(span.content for span in row) for row in rows)
        @test findfirst("committed answer",text).start<findfirst("after live response",text).start
        @test !occursin("after live response",JSON.json(JuliaForever2.timeline_context(timeline)))
        T.clear_frontend_notices!(app);@test isempty(app.transcript.notices.notices)
        T.cleanup!(app);close(app.session)
    end
end

@testset "Notices preserve actual image offsets and provider history" begin
    T=NoticeOwner
    timeline=JuliaForever2.SessionTimeline(pwd())
    user=JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"Inspect image"))
    JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>[Dict("type"=>"toolCall","id"=>"image","name"=>"read","arguments"=>Dict("path"=>"not-opened.png"))]))
    image=first(JSON.parsefile(joinpath(@__DIR__,"fixtures","session_images","png-cases.json")))
    JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"toolResult","toolCallId"=>"image","toolName"=>"read","content"=>[Dict("type"=>"image","mimeType"=>"image/png","data"=>image["data"])],"isError"=>false))
    before=JuliaForever2.timeline_entries(timeline);context=JuliaForever2.timeline_context(timeline)
    projection=JuliaForever2.timeline_display_projection(timeline)
    anchor=first(projection.items).source_entry_id
    registry=T.SessionBuiltinToolRenderers();options=T.SessionImageOptions(;max_width_cells=12)
    plan=T.session_display_plan(projection,40;options,tool_renderers=registry,protocol=:kitty,cell_pixels=(w=9,h=18))
    notice=T.FrontendNotice(;message="actual transient notice")
    shifted=T.session_display_plan(projection,40;options,tool_renderers=registry,protocol=:kitty,cell_pixels=(w=9,h=18),
        after_record=(id,w)->isequal(id,anchor) ? T.frontend_notice_rows(notice,w) : T.SessionDisplayRows())
    @test length(plan.placements)==length(shifted.placements)==1
    @test only(shifted.placements).row==only(plan.placements).row+2
    @test only(shifted.placements).column==only(plan.placements).column
    @test JuliaForever2.timeline_entries(timeline)==before
    @test JuliaForever2.timeline_context(timeline)==context
end
