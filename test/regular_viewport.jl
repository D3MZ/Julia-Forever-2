using Test,JSON,JuliaForever2,Tachikoma,CommonMark
module RegularViewportTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const JF=JuliaForever2
mouse(x,y,action=Tachikoma.mouse_press)=Tachikoma.MouseEvent(x,y,Tachikoma.mouse_left,action,false,false,false)
function frame(app,width,height;x=1,y=1)
    area=Tachikoma.Rect(x,y,width,height);app.area=area
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,x+width-1,y+height-1))
    Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
end
@testset "Actual regular archive draw and visible editor hitboxes" begin
    captures=[]
    mktempdir() do directory
        kernel=JF.Kernel();app=T.App(JF.Session(kernel;working_directory=directory);settings_dir=joinpath(directory,"config"),theme_fallback="dark")
        app.menus.startup.document.quiet=true
        T.set_setting_value!(app,"tui-mode","regular")
        JF.timeline_append_message!(app.archive.timeline,Dict("role"=>"user","content"=>"A real long archived transcript"))
        JF.timeline_append_message!(app.archive.timeline,Dict("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>join(["archive row $index" for index in 1:100],"\n"))]))
        archived=deepcopy(JF.timeline_entries(app.archive.timeline))
        for (width,height) in ((100,32),(60,12),(30,5)), offset in (false,true)
            area_x,area_y=offset ? (3,4) : (1,1)
            app.page=:chat;Tachikoma.set_text!(app.input,"draft alpha beta")
            render=frame(app,width,height;x=area_x,y=area_y)
            outcome=T.preference_attempt(()->T.default_view!(app,render))
            @test outcome.ok
            !outcome.ok && println("REGULAR_DRAW_ERROR=",outcome.reason)
            natural=T.startup_host_scene(app,width,height)
            @test length(natural.lines)>height
            @test length(app.settings.presentation.lines)==length(natural.lines)
            geometry=T.startup_editor_geometry(app)
            @test geometry.height>0 && area_y<=geometry.visible_top<area_y+height
            clickrow=geometry.top+1
            if geometry.visible_top<=clickrow<geometry.visible_top+geometry.height
                T.page_mouse!(app,Val(:chat),mouse(area_x,clickrow))
                T.page_mouse!(app,Val(:chat),mouse(area_x,clickrow,Tachikoma.mouse_release))
                @test app.input.cursor==0
            end
            @test JF.timeline_entries(app.archive.timeline)==archived
            rows=T.startup_buffer_rows(render.buffer,area_x+width-1,area_y+height-1)
            ansi=[sprint(io->(foreach(span->(Tachikoma.write_style(io,span.style);print(io,span.content)),line);print(io,"\e[0m"))) for line in rows]
            push!(captures,(;id="regular-long-chat.$width.$height.$offset",width=area_x+width-1,terminalAnsiLines=ansi,ok=outcome.ok,reason=outcome.reason))
        end
        T.open_menu!(app,"settings");render=frame(app,60,32;x=3,y=4)
        outcome=T.preference_attempt(()->T.default_view!(app,render));@test outcome.ok
        geometry=T.startup_editor_geometry(app,T.settings_lines(app,60))
        @test geometry.height>0 && 4<=geometry.visible_top<36
        T.page_mouse!(app,Val(:pi_menu),mouse(4,geometry.top+4))
        @test app.menus.cursor==2
        T.page_mouse!(app,Val(:pi_menu),mouse(4,geometry.top+4,Tachikoma.mouse_release))
        @test T.menu_preference(app,"auto-resize-images","true")=="false"
        @test JF.timeline_entries(app.archive.timeline)==archived
        T.bug_report_command!(app,"A real draft remains unchanged")
        report=app.menus.bug_report
        for mode in ("regular","fullscreen"), (width,height) in ((60,32),(30,12))
            T.set_setting_value!(app,"tui-mode",mode)
            render=frame(app,width,height)
            outcome=T.preference_attempt(()->T.default_view!(app,render))
            @test outcome.ok
            @test app.menus.bug_report===report && T.chat_text(report.editor)=="A real draft remains unchanged"
            @test JF.timeline_entries(app.archive.timeline)==archived
        end
        T.bug_report_close!(app,"Ready")
        T.set_setting_value!(app,"tui-mode","regular")
        sink=IOBuffer();terminal=Tachikoma.Terminal(;io=sink,size=(rows=12,cols=60),external_size=true);app.settings.terminal=terminal
        T.initialize_terminal_presentation!(app,terminal)
        outcome=T.preference_attempt() do
            Tachikoma.draw!(terminal) do current
                T.default_view!(app,current)
            end
        end
        @test outcome.ok
        raw=String(take!(sink))
        path=get(ENV,"REGULAR_VIEWPORT_EVIDENCE","");isempty(path)||write(path*".ansi",raw)
        output=replace(T.session_display_safe(raw),r"\s+"=>" ")
        @test occursin("archive row 1",output) && occursin("archive row 100",output)
        @test length(app.settings.presentation.regular.rows)>12
        @test app.settings.presentation.regular.viewport==length(app.settings.presentation.regular.rows)-12
        @test JF.timeline_entries(app.archive.timeline)==archived
        T.finish_shutdown!(app);close(kernel)
    end
    path=get(ENV,"REGULAR_VIEWPORT_EVIDENCE","");isempty(path)||write(path,JSON.json((;snapshots=captures)))
end
end

@testset "Regular physical projection preserves exact archive row offsets" begin
    T=RegularViewportTests.T
    parts=[(name=:editor,top=18,height=8,first_row=1),(name=:footer,top=26,height=2,first_row=1)]
    source=(lines=[[Tachikoma.Span(string(i))] for i in 1:27],rectangles=parts,archive_top=4,archive_height=14,first_archive_row=1,first_document_row=1)
    for height in (0,1,3,5,12,27,32)
        visible=T.terminal_visible_scene(source,height)
        skipped=max(0,27-height)
        @test [only(line).content for line in visible.lines]==string.(skipped+1:27)
        @test visible.first_document_row==skipped+1
        @test visible.archive_height==max(0,17-max(4,skipped+1)+1)
        @test visible.first_archive_row==max(1,skipped-2)
        @test visible.archive_height==0 || 1<=visible.archive_top<=height && visible.archive_top+visible.archive_height-1<=height
        for rectangle in visible.rectangles
            @test rectangle.height>=0
            @test rectangle.height==0 || 1<=rectangle.top<=height && rectangle.top+rectangle.height-1<=height
        end
    end
    @test length(source.lines)==27 && source.rectangles==parts
end
