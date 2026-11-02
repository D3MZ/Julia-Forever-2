"""Select a genuine main-screen or alternate-screen composition from the active backend."""
function startup_host_scene(app::App,width::Int,height::Int;editor=nothing)
    terminal_presentation_mode(app)==:regular ? terminal_regular_scene(app,width,height;editor) : startup_fullscreen_scene(app,width,height;editor)
end

"""Compose regular mode in natural document order, preserving all rows for the actual terminal scrollback."""
function terminal_regular_scene(app::App,width::Int,height::Int;editor=nothing)
    controls=app.menus.startup
    prefix=isnothing(controls) ? Vector{Tachikoma.Span}[] : startup_document_lines(controls.document,app.menus.theme_runtime,width)
    archived=archive_transcript_lines!(app,width)
    preview=[startup_preview_rows(app,width);frontend_preview_notice_rows(app,width)]
    selected=isnothing(editor) ? startup_selected_editor(app,Val(app.page),width,height) : editor
    document=[prefix;archived;preview;user_shell_lines(app,width)]
    parts=[StartupDockPart(;name=:pending,lines=[pending_input_lines(app,width);user_shell_lines(app,width;pending=true)]),
        StartupDockPart(;name=:status,lines=Vector{Tachikoma.Span}[]),
        StartupDockPart(;name=:above,lines=[[Tachikoma.Span("",Tachikoma.Style())]]),
        StartupDockPart(;name=:editor,lines=selected.lines,cursor_row=selected.cursor_row),
        StartupDockPart(;name=:below,lines=Vector{Tachikoma.Span}[]),
        StartupDockPart(;name=:footer,lines=footer_control_lines(app,width))]
    lines=copy(document)
    rectangles=NamedTuple{(:name,:top,:height,:first_row),Tuple{Symbol,Int,Int,Int}}[]
    top=length(lines)+1
    for part in parts
        push!(rectangles,(name=part.name,top,height=length(part.lines),first_row=1))
        append!(lines,part.lines);top+=length(part.lines)
    end
    (;lines,document_height=length(document),rectangles,first_document_row=1,archive_top=length(prefix)+1,
        archive_height=length(archived),first_archive_row=1,startup_rows=length(prefix),archived_rows=length(archived),
        preview_rows=length(preview),editor_cursor_row=selected.cursor_row,editor_cursor_col=get(selected,:cursor_col,nothing))
end

"""Resolve a logical focused cursor without deriving terminal commands from raw message text."""
function terminal_regular_cursor(scene)
    rectangle=only(filter(part->part.name==:editor,scene.rectangles))
    row=scene.editor_cursor_row;column=scene.editor_cursor_col
    isnothing(row)||isnothing(column) ? nothing : (column,rectangle.top+row-1)
end

"""Publish native rows before the framework flush; the owned sink decides their real screen backend."""
function terminal_presentation_publish!(app::App,width::Int,height::Int;scene=nothing)
    state=app.settings.presentation
    natural=isnothing(scene) ? terminal_regular_scene(app,width,height) : scene
    state.lines=natural.lines;state.cursor=terminal_regular_cursor(natural)
    cursor=state.cursor
    if !isnothing(cursor) && menu_preference(app,"show-hardware-cursor","false")=="true"
        row=cursor[2]
        state.lines=copy(state.lines)
        state.lines[row]=[Tachikoma.Span(span.content,span.style.fg isa MenuSearchInverseColor ? Tachikoma.Style() : span.style) for span in state.lines[row]]
    end
    state.width=width;state.height=height
    state.hardware_cursor=menu_preference(app,"show-hardware-cursor","false")=="true"
    nothing
end

"""Prepare actual chat content for shutdown rather than printing a stale selector or fictitious transcript."""
function terminal_presentation_exit_rows!(app::App)
    state=app.settings.presentation
    editor=chat_editor_lines(chat_editor_state!(app),state.width,state.height;runtime=app.menus.theme_runtime,
        padding=terminal_integer(app,"editor-padding",0,0,3),hardware_cursor=state.hardware_cursor)
    natural=terminal_regular_scene(app,state.width,state.height;editor)
    terminal_presentation_publish!(app,state.width,state.height;scene=natural)
    nothing
end

"""Project natural regular-mode rows onto the physical viewport without truncating the scrollback document."""
function terminal_visible_scene(scene,height::Int)
    skipped=max(0,length(scene.lines)-max(0,height))
    last_row=skipped+max(0,height)
    rectangles=map(scene.rectangles) do part
        first_visible=max(skipped+1,part.top)
        last_visible=min(last_row,part.top+part.height-1)
        count=max(0,last_visible-first_visible+1)
        (;part...,top=first_visible-skipped,height=count,first_row=part.first_row+max(0,first_visible-part.top))
    end
    archive_first=max(skipped+1,scene.archive_top)
    archive_last=min(last_row,scene.archive_top+scene.archive_height-1)
    archive_height=max(0,archive_last-archive_first+1)
    (;scene...,lines=scene.lines[skipped+1:end],rectangles,
        archive_top=archive_first-skipped,archive_height,
        first_archive_row=scene.first_archive_row+max(0,archive_first-scene.archive_top),
        first_document_row=scene.first_document_row+skipped)
end

terminal_visible_scene(app::App,scene,height::Int)=terminal_presentation_mode(app)==:regular ? terminal_visible_scene(scene,height) : scene
