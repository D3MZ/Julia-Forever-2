using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const StartupHostTerminal=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)

function startup_host_test_frame(app,width,height;x=1,y=1)
    area=Tachikoma.Rect(x,y,width,height)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width+x-1,height+y-1))
    app.area=area
    frame=Tachikoma.Frame(buffer,area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
    StartupHostTerminal.default_view!(app,frame)
    frame
end
startup_host_test_mouse(x,y,action=Tachikoma.mouse_press,button=Tachikoma.mouse_left) = Tachikoma.MouseEvent(x,y,button,action,false,false,false)

@testset "Actual shared dock, clipped hitboxes and truthful settings outcomes" begin
    T=StartupHostTerminal
    mktempdir() do directory
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=directory);settings_dir=joinpath(directory,"config"),theme_fallback="dark")
        @test app.menus.startup.document.brand=="Julia Forever 2"
        @test app.menus.startup.document.version==string(pkgversion(JuliaForever2))
        @test !app.menus.startup.document.logo
        T.open_menu!(app,"settings")
        startup_host_test_frame(app,60,32;x=3,y=4)
        scene=T.startup_host_scene(app,60,32)
        footer=only(filter(part->part.name==:footer,scene.rectangles))
        @test footer.height==2
        @test isnothing(app.settings.output.cursor) # Original settings is not Focusable.
        geometry=T.startup_editor_geometry(app)
        before=app.menus.cursor
        T.page_mouse!(app,Val(:pi_menu),startup_host_test_mouse(3,geometry.visible_top-1))
        @test app.menus.cursor==before
        T.page_mouse!(app,Val(:pi_menu),startup_host_test_mouse(4,geometry.top+4))
        @test app.menus.cursor==2
        T.page_mouse!(app,Val(:pi_menu),startup_host_test_mouse(4,geometry.top+4,Tachikoma.mouse_release))
        @test T.setting_value(app,T.TERMINAL_SETTINGS[3])=="60" # Unrelated setting unchanged.
        @test T.menu_preference(app,"auto-resize-images","true")=="false"
        @test app.status=="Ready" && length(T.footer_control_lines(app,60))==2
        T.set_setting_value!(app,"editor-padding","invalid")
        @test !isnothing(app.menus.preference_error) && app.status!="Ready"
        T.set_setting_value!(app,"editor-padding","1")
        @test isnothing(app.menus.preference_error) && app.status=="Ready"
        T.set_setting_value!(app,"editor-padding","invalid")
        app.status="Unrelated native notice"
        T.set_setting_value!(app,"editor-padding","2")
        @test app.status=="Unrelated native notice" && isnothing(app.menus.preference_error)
        app.status="Ready"
        for (width,height) in ((100,32),(60,12),(30,5),(10,5),(5,5))
            startup_host_test_frame(app,width,height)
            scene=T.startup_host_scene(app,width,height)
            @test length(scene.lines)==height
            rectangle=only(filter(part->part.name==:editor,scene.rectangles))
            geometry=T.startup_editor_geometry(app)
            @test geometry.visible_top==rectangle.top
            @test 0<=geometry.height<=height
            before=app.menus.cursor
            T.page_mouse!(app,Val(:pi_menu),startup_host_test_mouse(width+1,geometry.visible_top+1))
            @test app.menus.cursor==before
            T.page_mouse!(app,Val(:pi_menu),startup_host_test_mouse(1,0,Tachikoma.mouse_release))
            @test isnothing(app.menus.pressed)
        end
        app.page=:chat
        context_before=JuliaForever2.timeline_context(app.archive.timeline)
        app.transcript.preview_lines=[("Actual streaming preview",:text)]
        startup_host_test_frame(app,60,32)
        scene=T.startup_host_scene(app,60,32)
        @test scene.preview_rows==1
        @test any(row->occursin("Actual streaming preview",join(span.content for span in row)),scene.lines)
        @test JuliaForever2.timeline_context(app.archive.timeline)==context_before
        close(app.session)
    end
end

@testset "Literal resource and model text cannot issue terminal commands" begin
    T=StartupHostTerminal
    payload="path\e]52;c;ZGFuZ2Vy\a/name\e[2J\e[H\e_pi:cursor\e\\\u009b31m\b\r\nnext\t👩‍💻"
    doc=T.StartupDocument(;brand=payload,version="fixture",capabilities=Set{String}(),
        resources=[T.StartupResource(;kind=:skill,name=payload,path=payload)],
        statuses=[T.StartupStatus(;message=payload)])
    for width in (100,30,5)
        lines=T.startup_document_lines(doc,nothing,width)
        buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
        T.startup_document_draw!(buffer,1,1,width,lines)
        @test all(cell->cell.char=='\0'||!iscntrl(cell.char),buffer.content)
        @test all(cell->!any(iscntrl,cell.suffix),buffer.content)
        text=join(string(cell.char)*cell.suffix for cell in buffer.content if cell.char!='\0')
        @test !occursin('\e',text) && !occursin('\a',text) && !occursin('\u009b',text)
        @test !occursin("ZGFuZ2Vy",text) && !occursin("pi:cursor",text)
    end
    rows=[[Tachikoma.Span(payload,Tachikoma.Style())]]
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,100,1))
    T.startup_document_draw!(buffer,1,1,100,rows)
    @test all(cell->cell.char=='\0'||!iscntrl(cell.char),buffer.content)
    @test isnothing(T.startup_cursor_column(only(rows),style->style.fg isa T.MenuSearchInverseColor))
    @test T.startup_safe_text("a\nb";multiline=true)=="a\nb"
    @test T.startup_safe_text("a\nb")=="a�b"
    @test T.startup_safe_text("a\tb")=="a   b"
end

@testset "Actual editor cursor, click geometry and session-list sizing" begin
    T=StartupHostTerminal
    mktempdir() do directory
        app=T.App(JuliaForever2.Session(JuliaForever2.Kernel();working_directory=directory);settings_dir=joinpath(directory,"config"),theme_fallback="dark")
        app.menus.startup.document.quiet=true
        Tachikoma.set_text!(app.input,"first line\n指示 👩‍💻 café\nlast line")
        editor=T.chat_editor_state!(app)
        T.chat_add_history!(editor,"a prior real submitted input")
        for hardware in (false,true), (width,height) in ((100,32),(30,12),(10,5),(5,3))
            app.menus.preferences["show-hardware-cursor"]=string(hardware)
            frame=startup_host_test_frame(app,width,height;x=3,y=4)
            scene=T.startup_host_scene(app,width,height)
            cursor=T.startup_host_cursor(app,scene)
            @test app.settings.output.cursor==cursor
            @test isnothing(cursor) || (3<=cursor[1]<3+width && 4<=cursor[2]<4+height)
            @test isnothing(cursor) || !hardware || !(frame.buffer.content[Tachikoma.buf_index(frame.buffer,cursor...)].style.fg isa T.MenuSearchInverseColor)
        end
        app.menus.preferences["show-hardware-cursor"]="false"
        startup_host_test_frame(app,60,32;x=3,y=4)
        geometry=T.startup_editor_geometry(app)
        old=app.input.cursor
        T.page_mouse!(app,Val(:chat),startup_host_test_mouse(3,geometry.top+1))
        @test app.input.cursor==old
        T.page_mouse!(app,Val(:chat),startup_host_test_mouse(3,geometry.top+1,Tachikoma.mouse_release))
        @test app.input.cursor==0
        T.open_menu!(app,"settings")
        @test isnothing(app.menus.chat_press)
        @test T.chat_editor_state!(app)===editor
        app.menus.path=["fork"]
        app.menus.fork_menu=T.fork_menu([T.ForkMessage(;id=string(i),text="Message $i") for i in 1:15];on_select=identity,on_cancel=()->nothing)
        for height in (32,12,5)
            T.startup_menu_rows(app,60,height)
            @test app.menus.fork_menu.maximum_rows==10
        end
        app.menus.path=["thinking"]
        app.menus.thinking_menu=T.thinking_menu("medium",["off","low","medium","high"];on_select=identity,on_cancel=()->nothing,focused=true)
        app.menus.preferences["show-hardware-cursor"]="true"
        startup_host_test_frame(app,60,32)
        @test !isnothing(app.settings.output.cursor)
        T.close_session_selectors!(app)
        close(app.session)
    end
end
