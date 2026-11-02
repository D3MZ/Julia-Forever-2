"""Build disposable native UI state without configuration, authentication, subprocess or filesystem writes."""
function terminal_compile_fixture()
    kernel=JuliaForever2.Kernel()
    executor=JuliaForever2.JuliaExecutor(@__MODULE__,IOBuffer())
    runtime=JuliaForever2.SessionRuntime(executor;working_directory=@__DIR__,id=JuliaForever2.UUID("00000000-0000-0000-0000-000000000001"))
    session=JuliaForever2.Session(kernel,JuliaForever2.Conversation(),runtime,nothing)
    registry=JuliaForever2.ProviderRegistry()
    app=App(session,TextInput(;label=""),:chat,false,1,false,false,TaskQueue(;capacity=1),"Ready",0,Rect(),
        "precompile",CommandSpec[],Dict{Symbol,Vector{EventHandler}}(),SettingsState(@__DIR__,registry),
        TranscriptState(),OperationState(),MenusState(),TerminalArchive(@__DIR__))
    register_default_commands!(app)
    timeline=JuliaForever2.SessionTimeline(@__DIR__;id="compile-session",timestamp="2026-01-01T00:00:00.000Z")
    JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"Review the native implementation."))
    JuliaForever2.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>[
        Dict("type"=>"text","text"=>"**Summary**\n\nA native Julia response with `code`."),
        Dict("type"=>"thinking","thinking"=>"Consider the supplied context.")]))
    app.archive.timeline=timeline
    app
end

"""Exercise real native first-use rendering and navigation paths using only detached in-memory state."""
function terminal_compile_workload()
    app=terminal_compile_fixture()
    models=[SelectorModel("precompile","native-small";name="Native Small"),SelectorModel("precompile","native-large";name="Native Large")]
    selector=ModelMenu(models)
    scoped=ScopedModelMenu(models)
    thinking=thinking_menu("medium",["off","minimal","low","medium","high"];on_select=Returns(nothing),on_cancel=Returns(nothing))
    timeline=app.archive.timeline::JuliaForever2.SessionTimeline
    tree=tree_menu(JuliaForever2.timeline_tree(timeline),JuliaForever2.timeline_leaf(timeline);
        on_select=Returns(nothing),on_cancel=Returns(nothing),schedule=Returns(nothing),home="/precompile")
    theme=NativeTheme(name="precompile",colors=Dict{String,Tachikoma.AbstractColor}())
    catalog=ThemeCatalog(registered=Dict("precompile"=>theme),directory="")
    theme_state=ThemeRuntime(catalog=catalog,active=theme,committed="precompile",requested="precompile",owner_name="precompile")
    themes=theme_menu(theme_state;available=["precompile"],on_event=Returns(nothing),persist=Returns(nothing))
    rendered=0
    for width in (80,40)
        buffer=Tachikoma.Buffer(Rect(1,1,width,30))
        frame=Frame(buffer,buffer.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
        app.page=:chat
        default_view!(app,frame)
        Tachikoma.set_text!(app.input,"/")
        app.menu=true
        default_view!(app,frame)
        app.menu=false
        app.page=:pi_menu
        app.menus.path=["settings"]
        default_view!(app,frame)
        append!(app.menus.path,["warnings"])
        default_view!(app,frame)
        app.menus.path=["settings"]
        rendered+=length(model_menu_lines(selector,width))
        model_menu_input!(selector,"\e[B")
        rendered+=length(scoped_models_lines(scoped,width))
        rendered+=length(thinking_lines(thinking,width))
        thinking_input!(thinking,"\e[B")
        rendered+=length(tree_lines(tree,width))
        rendered+=length(theme_menu_lines(themes,width))
        rendered+=length(settings_lines(app,width))
        app.page=:components
        default_view!(app,frame)
    end
    close(app.queue.channel)
    close(app.session.kernel)
    rendered
end
