"""Advertise only implemented host bindings, preserving absent suspend and clipboard capabilities."""
function startup_host_bindings(app::App)
    Dict("app.interrupt"=>"escape","app.clear"=>"ctrl+c","app.exit"=>"ctrl+d",
        "app.editor.external"=>"ctrl+g","tui.editor.deleteToLineEnd"=>"ctrl+k",
        "app.thinking.cycle"=>"shift+tab","app.model.cycleForward"=>"ctrl+p",
        "app.model.cycleBackward"=>"shift+ctrl+p","app.model.select"=>"ctrl+l",
        "app.tools.expand"=>"ctrl+o","app.thinking.toggle"=>"ctrl+t",
        "app.message.followUp"=>(Sys.iswindows() ? "alt+enter/ctrl+q" : "alt+enter"),
        "app.message.dequeue"=>(Sys.iswindows() ? "alt+up/alt+q" : "alt+up"))
end

"""Resolve factual repository location outside rendering, never from a guessed directory suffix."""
function startup_host_branch(directory::AbstractString)
    executable=Sys.which("git")
    branch=isnothing(executable) ? "" : readchomp(pipeline(ignorestatus(`$executable -C $directory symbolic-ref --quiet --short HEAD`);stderr=devnull))
    isempty(branch) ? nothing : branch
end

"""Initialize actual startup resources and non-secret footer caches after preferences and theme loading."""
function initialize_startup_host!(app::App)
    controls=startup_controls(app;bindings=startup_host_bindings(app),supported=["bash","bash.noContext"])
    app.menus.startup=controls
    startup_discover_resources!(controls,app)
    refresh_footer_controls!(app;models=menu_model_snapshot(app),branch=startup_host_branch(app.settings.workspace),home=homedir())
    nothing
end

"""Reconstruct styled rows from real native widget cells, retaining wide-cell suffixes and resets."""
function startup_buffer_rows(buffer::Tachikoma.Buffer,width::Int,height::Int)
    rows=Vector{Tachikoma.Span}[]
    for y in 1:height
        spans=Tachikoma.Span[]
        for x in 1:width
            cell=buffer.content[Tachikoma.buf_index(buffer,x,y)]
            if cell.char!='\0'
                text=string(cell.char)*cell.suffix
                if !isempty(spans) && last(spans).style==cell.style
                    previous=pop!(spans)
                    push!(spans,Tachikoma.Span(previous.content*text,cell.style))
                else
                    push!(spans,Tachikoma.Span(text,cell.style))
                end
            end
        end
        push!(rows,spans)
    end
    rows
end

"""Preserve the actual existing working indicator without claiming source parity for its separate animation."""
function startup_busy_border(app::App,width::Int,hidden_rows::Int)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,1))
    draw_input_border!(buffer,1,1,width,app)
    only(startup_buffer_rows(buffer,width,1))
end

startup_thinking_border_token(level)=:thinkingOff
startup_thinking_border_token(level::AbstractString)=get((;off=:thinkingOff,minimal=:thinkingMinimal,low=:thinkingLow,
    medium=:thinkingMedium,high=:thinkingHigh,xhigh=:thinkingXhigh,max=:thinkingMax),Symbol(level),:thinkingOff)
startup_thinking_border_style(::Nothing,level)=pi_style(:text_dim)
startup_thinking_border_style(runtime::ThemeRuntime,level)=theme_style(runtime,startup_thinking_border_token(level))

"""Use actual configured thinking state for the App border without changing the generic Editor default."""
function startup_idle_editor_border(app::App,state::ChatEditorState)
    if startswith(lstrip(chat_text(state)),"!")
        user_shell_border(app.menus.theme_runtime)
    else
        level=with_component(app.session.kernel,:provider;fallback=nothing) do provider
            JuliaForever2.current_thinking_level(provider)
        end
        startup_thinking_border_style(app.menus.theme_runtime,level)
    end
end

"""Render the native multiline editor and existing command completions in the shared dock."""
function startup_chat_editor(app::App,width::Int,height::Int)
    state=chat_editor_state!(app)
    busy=app.busy && !isnothing(app.operations.active) && !app.operations.closing[]
    border=busy ? (w,hidden)->startup_busy_border(app,w,hidden) : nothing
    completion=chat_completion_state!(app)
    chat_completion_lines(completion,width,height;runtime=app.menus.theme_runtime,
        padding=terminal_integer(app,"editor-padding",0,0,3),
        hardware_cursor=menu_preference(app,"show-hardware-cursor","false")=="true",top_border=border,
        border_style=startup_idle_editor_border(app,state))

end

"""Preserve real streaming preview layout after archived rows without inventing committed messages."""
function startup_preview_rows(app::App,width::Int)
    progress=app.transcript.preview
    if !isnothing(progress) && !active_operation(app,app.transcript.preview_operation_id)
        clear_preview!(app)
        progress=nothing
    end
    padding=terminal_integer(app,"output-padding",1,0,1)
    if !isnothing(progress) && progress.kind==:answer
        state=app.transcript.display
        state.output_padding=padding
        session_display_assistant(Dict{String,Any}("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>progress.text)]),width,state)
    else
        preview=preview_lines!(app,width+2-2padding)
        buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(preview)))
        for (row,(content,style)) in enumerate(preview)
            draw_conversation_line!(buffer,1,row,width,content,style;padding)
        end
        startup_buffer_rows(buffer,width,length(preview))
    end
end

startup_menu_cursor(lines) = findfirst(line->any(span->span.style.fg isa MenuSearchInverseColor,line),lines)
startup_menu_focusable(app::App) = auth_menu_active(app,app.menus.auth_menu_control) || app.menus.path in (["model"],["scoped-models"],["thinking"],["resume"],["tree"])
startup_menu_cursor(app::App,lines) = startup_menu_focusable(app) ? startup_menu_cursor(lines) : nothing

"""Find only a typed native cursor style; arbitrary content never supplies cursor control markers."""
function startup_cursor_column(line,style)
    column=1;found=nothing
    for span in line
        if isnothing(found) && style(span.style) && !isempty(span.content)
            found=column
        end
        column+=menu_search_width(startup_safe_text(span.content))
    end
    found
end

"""Map the visible focused cursor through actual dock clipping into absolute terminal coordinates."""
function startup_host_cursor(app::App,scene)
    rectangle=only(filter(part->part.name==:editor,scene.rectangles))
    row=scene.editor_cursor_row
    column=scene.editor_cursor_col
    cursor=nothing
    if !isnothing(row) && !isnothing(column) && rectangle.first_row<=row<rectangle.first_row+rectangle.height
        x=app.area.x+column-1
        y=app.area.y+rectangle.top-1+row-rectangle.first_row
        if app.area.x<=x<app.area.x+app.area.width && app.area.y<=y<app.area.y+app.area.height
            cursor=(x,y)
        end
    end
    cursor
end

"""Preserve additional native menu pages in the common document, editor and footer scene."""
function startup_generic_menu(app::App,width::Int,height::Int)
    rows=Vector{Tachikoma.Span}[[Tachikoma.Span(repeat("─",width),pi_style(:menu_border))],
        [Tachikoma.Span(join(app.menus.path," / "),pi_style(:accent))]]
    items=menu_page_items(app)
    count=min(length(items),max(0,height-7))
    first_item=max(1,min(app.menus.cursor-count+1,length(items)-count+1))
    for offset in 0:count-1
        index=first_item+offset;item=items[index];selected=index==app.menus.cursor
        suffix=haskey(item,"choices")||haskey(item,"children") ? "  ›" : ""
        label=get(item,"label",item["id"])::String
        text=(selected ? "→ " : "  ")*label*suffix
        push!(rows,[Tachikoma.Span(Tachikoma.truncate_to_width(text,width),pi_style(selected ? :accent : :text))])
    end
    push!(rows,[Tachikoma.Span("↑↓ select · Enter open · Esc back",pi_style(:text_dim))],
        [Tachikoma.Span(repeat("─",width),pi_style(:menu_border))])
    rows
end

"""Render each real selector through existing state and callbacks before common dock allocation."""
function startup_menu_rows(app::App,width::Int,height::Int)
    control=app.menus.auth_menu_control
    lines=if control isa AuthMenuControl && auth_menu_active(app,control)
        auth_menu_lines(app,control,width)
    elseif selector_active(app)
        menu=app.menus.path==["resume"] ? app.menus.resume_menu : app.menus.fork_menu
        if isnothing(menu)
            Vector{Tachikoma.Span}[]
        else
            menu.maximum_rows=10
            selector_lines(menu,width)
        end
    elseif app.menus.path==["tree"]
        menu=app.menus.tree_menu
        if isnothing(menu)
            Vector{Tachikoma.Span}[]
        else
            menu.maximum_rows=max(5,fld(height,2))
            tree_lines(menu,width)
        end
    elseif thinking_defaults_active(app)
        thinking_defaults_controls_lines(app,width)
    elseif theme_controls_active(app)
        theme_controls_lines(app,width)
    elseif app.menus.path in (["model"],["scoped-models"],["thinking"])
        model_controls_lines(app,width)
    elseif app.menus.path in (["settings"],["settings","warnings"])
        settings_lines(app,width)
    else
        startup_generic_menu(app,width,height)
    end
    cursor_row=startup_menu_cursor(app,lines)
    cursor_col=isnothing(cursor_row) ? nothing : startup_cursor_column(lines[cursor_row],style->style.fg isa MenuSearchInverseColor)
    (;lines,cursor_row,cursor_col)
end

startup_selected_editor(app::App,::Val,width::Int,height::Int) = startup_chat_editor(app,width,height)
startup_selected_editor(app::App,::Val{:pi_menu},width::Int,height::Int) = startup_menu_rows(app,width,height)
function startup_selected_editor(app::App,::Val{:auth},width::Int,height::Int)
    rendered=auth_dialog_layout(app,app.menus.auth_menu_control,width)
    cursor=rendered.cursor
    (;lines=rendered.lines,cursor_row=isnothing(cursor) ? nothing : cursor.y+1,
        cursor_col=isnothing(cursor) ? nothing : cursor.x+1)
end

"""Compose factual startup, archive, live preview, pending queues and footer in one native scene."""
function startup_fullscreen_scene(app::App,width::Int,height::Int;editor=nothing)
    viewport=terminal_viewport!(app)
    document_width=terminal_scroll_control_width(viewport.scroll.control,width)
    controls=app.menus.startup
    prefix=isnothing(controls) ? Vector{Tachikoma.Span}[] : startup_document_lines(controls.document,app.menus.theme_runtime,document_width)
    live_preview=startup_preview_rows(app,document_width)
    preview=[live_preview;frontend_preview_notice_rows(app,document_width)]
    archived=archive_transcript_lines!(app,document_width)
    selected=isnothing(editor) ? startup_selected_editor(app,Val(app.page),width,height) : editor
    parts=[StartupDockPart(;name=:pending,lines=[pending_input_lines(app,width);user_shell_lines(app,width;pending=true)]),
        StartupDockPart(;name=:status,lines=Vector{Tachikoma.Span}[]),
        StartupDockPart(;name=:above,lines=[[Tachikoma.Span("",Tachikoma.Style())]]),
        StartupDockPart(;name=:editor,lines=selected.lines,minimum=3,cursor_row=selected.cursor_row),
        StartupDockPart(;name=:below,lines=Vector{Tachikoma.Span}[]),
        StartupDockPart(;name=:footer,lines=footer_control_lines(app,width))]
    document=[prefix;archived;preview;user_shell_lines(app,document_width)]
    scene=terminal_scroll_host_scene!(viewport.scroll,app,document,parts,width,height)
    terminal_prompt_document!(app,length(prefix),length(archived),length(live_preview))
    first_document_row=scene.viewport.first_row
    last_document_row=min(length(document),first_document_row+scene.document_height-1)
    archive_first=max(first_document_row,length(prefix)+1)
    archive_last=min(last_document_row,length(prefix)+length(archived))
    archive_height=max(0,archive_last-archive_first+1)
    (;scene...,document_width,first_document_row,archive_top=archive_first-first_document_row+1,
        archive_height,first_archive_row=max(1,archive_first-length(prefix)),startup_rows=length(prefix),
        archived_rows=length(archived),preview_rows=length(preview),editor_cursor_row=selected.cursor_row,
        editor_cursor_col=get(selected,:cursor_col,nothing))
end

"""Share the actual rendered editor rectangle with mouse routing, including clipped hidden rows."""
function startup_editor_geometry(app::App,lines=nothing)
    width,height=app.area.width,app.area.height
    editor=isnothing(lines) ? nothing : (lines,cursor_row=startup_menu_cursor(app,lines))
    scene=terminal_visible_scene(app,startup_host_scene(app,width,height;editor),height)
    rectangle=only(filter(part->part.name==:editor,scene.rectangles))
    visible_top=app.area.y+rectangle.top-1
    visible_height=max(0,min(rectangle.height,app.area.height-rectangle.top+1))
    (top=visible_top-rectangle.first_row+1,visible_top,height=visible_height,first_row=rectangle.first_row)
end
startup_inside_editor(app::App,event::MouseEvent,geometry) = app.area.x<=event.x<app.area.x+app.area.width && geometry.visible_top<=event.y<geometry.visible_top+geometry.height
startup_editor_row(app::App,event::MouseEvent,geometry) = startup_inside_editor(app,event,geometry) ? event.y-geometry.top : -1

"""Draw the composed cells once and preserve actual images inside the clipped archive rectangle."""
function startup_host_view!(app::App,frame::Frame;editor=nothing)
    area=frame.area
    natural=startup_host_scene(app,area.width,area.height;editor)
    plan=app.transcript.display_plan
    terminal_presentation_publish!(app,area.width,area.height;scene=natural)
    scene=terminal_visible_scene(app,natural,area.height)
    search_focused=terminal_search_host_focused(app)
    cursor=search_focused ? terminal_search_host_cursor(app) : startup_host_cursor(app,scene)
    terminal_output_cursor!(app,terminal_presentation_mode(app)==:regular ? nothing : cursor)
    rows=scene.lines
    if !search_focused && menu_preference(app,"show-hardware-cursor","false")=="true" && !isnothing(cursor)
        rows=copy(rows)
        index=cursor[2]-area.y+1
        rows[index]=[Tachikoma.Span(span.content,span.style.fg isa MenuSearchInverseColor ? Tachikoma.Style() : span.style) for span in rows[index]]
    end
    startup_document_draw!(frame.buffer,area.x,area.y,area.width,rows)
    terminal_viewport_draw!(app,frame,scene)
    if !isnothing(plan) && scene.archive_height>0
        viewport=Rect(area.x,area.y+scene.archive_top-1,get(scene,:document_width,area.width),scene.archive_height)
        draw_session_images!(plan,frame,viewport;first_row=scene.first_archive_row)
    end
    scene
end
