# Native theme selectors and real palette transactions. Original labels/data: Pi MIT, see theme_assets/LICENSE.
public ThemeMenu, theme_menu, theme_menu_lines, theme_menu_input!, theme_menu_mouse!, theme_menu_items

Base.@kwdef mutable struct ThemeMenu{E,P}
    runtime::ThemeRuntime
    available::Vector{String}
    original::String
    on_event::E
    persist::P
    standalone::Bool = false
    open::Bool = true
    mode::Symbol = :single
    child::Symbol = :none
    single::String = "system"
    light::String = "system"
    dark::String = "system"
    cursor::Int = 1
    parent_cursor::Int = 1
    pressed::Union{Nothing,Int} = nothing
    header_theme::NativeTheme
    original_parent_theme::NativeTheme
    automatic_theme::NativeTheme
    list_row::Int = 0
    list_count::Int = 0
    list_start::Int = 1
    height::Int = 0
end

"""Prefer a valid configured theme, then system, then the first actual available choice."""
function theme_preferred(available,preferred,fallback="system")
    !isnothing(preferred) && preferred in available ? String(preferred) : fallback in available ? String(fallback) : isempty(available) ? String(fallback) : first(available)
end

"""Create an independently owned selector whose preview and save mutate the real native runtime."""
function theme_menu(runtime::ThemeRuntime;standalone::Bool=false,available=theme_available(runtime.catalog),
        on_event=(kind,setting,result)->nothing,persist=theme_store!)
    names = String[String(name) for name in available]
    original = runtime.committed
    automatic = theme_auto_setting(original)
    fixed = isnothing(automatic) && !occursin('/',original) ? original : nothing
    fallback = theme_preferred(names,fixed)
    light,dark = isnothing(automatic) ? (fallback,fallback) : (automatic.light,automatic.dark)
    selected = isnothing(automatic) ? fixed : runtime.catalog.appearance==:light ? light : dark
    single = theme_preferred(names,selected)
    menu = ThemeMenu(;runtime,available=names,original,on_event,persist,standalone,
        mode=standalone ? :standalone : isnothing(automatic) ? :single : :automatic,
        single,light,dark,header_theme=runtime.active,original_parent_theme=runtime.active,automatic_theme=runtime.active)
    target = standalone ? original : single
    items = theme_menu_items(menu)
    index = findfirst(item -> item.value==target,items)
    menu.cursor = isnothing(index) ? 1 : index
    menu
end

theme_menu_pair(menu::ThemeMenu) = menu.light*"/"*menu.dark
theme_menu_setting(menu::ThemeMenu) = menu.mode==:automatic ? theme_menu_pair(menu) : menu.single
theme_menu_active_pair(menu::ThemeMenu) = menu.runtime.catalog.appearance==:light ? menu.light : menu.dark

"""Read concrete choices, current ticks and descriptions without mutating preview state."""
function theme_menu_items(menu::ThemeMenu)
    if menu.mode==:automatic && menu.child==:none
        [(value="light-theme",label="Light theme",description="Theme to use in automatic mode when the terminal is light",currentValue=menu.light),
         (value="dark-theme",label="Dark theme",description="Theme to use in automatic mode when the terminal is dark",currentValue=menu.dark),
         (value="apply",label="Apply",description="Save and go back",currentValue="save and go back"),
         (value="single-mode",label="Change mode",description="Switch to one theme for light and dark",currentValue="switch to single theme")]
    elseif menu.standalone
        [(value=name,label=name,description=name==menu.original ? "(current)" : "") for name in menu.available]
    else
        current = menu.child==:light ? menu.light : menu.child==:dark ? menu.dark : menu.single
        items = [(value=name,label=(name==current ? "✓ " : "  ")*name,
            description=name=="system" ? "Theme created from your terminal's colors" : "") for name in menu.available]
        if menu.mode==:single
            system = filter(item -> item.value=="system",items)
            rest = filter(item -> item.value!="system",items)
            items = [system;[(value="/",label="  automatic",description="Use separate themes for light and dark terminal appearance")];rest]
        end
        items
    end
end

"""Emit an observable request only after executing the real preview operation."""
function theme_menu_preview!(menu::ThemeMenu,setting::AbstractString)
    result = theme_preview!(menu.runtime,setting)
    menu.on_event(:preview,String(setting),result)
    result
end

"""Preview the newly highlighted choice, including the inactive side of an automatic pair."""
function theme_menu_selection!(menu::ThemeMenu)
    items = theme_menu_items(menu)
    if 1<=menu.cursor<=length(items) && !(menu.mode==:automatic && menu.child==:none)
        selected = items[menu.cursor].value
        theme_menu_preview!(menu,selected=="/" ? theme_menu_pair(menu) : selected)
    else
        nothing
    end
end

"""Persist before closing; denied writes leave the menu open and committed palette unchanged."""
function theme_menu_apply!(menu::ThemeMenu,setting::AbstractString)
    result = theme_apply!(menu.runtime,setting;persist=menu.persist)
    if result.ok
        menu.on_event(menu.standalone ? :select : :change,String(setting),result)
        if !menu.standalone
            menu.open = false
        end
    else
        menu.on_event(:error,String(setting),result)
    end
    result
end

"""Enter nested automatic choices, select a real palette, or commit the selected mode."""
function theme_menu_activate!(menu::ThemeMenu)
    items = theme_menu_items(menu)
    result = nothing
    if 1<=menu.cursor<=length(items)
        value = items[menu.cursor].value
        if menu.standalone
            result = theme_menu_apply!(menu,value)
        elseif menu.mode==:single
            if value=="/"
                menu.mode = :automatic
                result = theme_menu_preview!(menu,theme_menu_pair(menu))
                menu.cursor = 1
                menu.header_theme = menu.runtime.active
                menu.automatic_theme = menu.runtime.active
            else
                menu.single = value
                result = theme_menu_apply!(menu,value)
            end
        elseif menu.child!=:none
            if menu.child==:light
                menu.light = value
            else
                menu.dark = value
            end
            result = theme_menu_preview!(menu,theme_menu_pair(menu))
            menu.child = :none
            menu.cursor = menu.parent_cursor
        elseif value in ("light-theme","dark-theme")
            menu.parent_cursor = menu.cursor
            menu.child = value=="light-theme" ? :light : :dark
            menu.header_theme = menu.runtime.active
            current = menu.child==:light ? menu.light : menu.dark
            index = findfirst(==(current),menu.available)
            menu.cursor = isnothing(index) ? 1 : index
        elseif value=="single-mode"
            menu.mode = :single
            menu.single = theme_menu_active_pair(menu)
            result = theme_menu_preview!(menu,menu.single)
            menu.header_theme = menu.runtime.active
            index = findfirst(item -> item.value==menu.single,theme_menu_items(menu))
            menu.cursor = isnothing(index) ? 1 : index
        elseif value=="apply"
            result = theme_menu_apply!(menu,theme_menu_pair(menu))
        end
    end
    menu.pressed = nothing
    result
end

"""Cancel a child back to its tentative pair; cancel settings restores the original preview."""
function theme_menu_cancel!(menu::ThemeMenu)
    result = nothing
    if menu.standalone
        result = menu.on_event(:cancel,nothing,nothing)
    elseif menu.child!=:none
        result = theme_menu_preview!(menu,theme_menu_setting(menu))
        menu.child = :none
        menu.cursor = menu.parent_cursor
    else
        result = theme_menu_preview!(menu,menu.original)
        menu.open = false
        menu.on_event(:back,nothing,result)
    end
    menu.pressed = nothing
    result
end

"""Navigate with wrap/page semantics; theme selectors intentionally do not interpret typing as search."""
function theme_menu_input!(menu::ThemeMenu,data::AbstractString)
    items = theme_menu_items(menu)
    count = length(items)
    previous = menu.cursor
    result = nothing
    if menu.open
        if data in ("\e[A","\eOA")
            menu.cursor = menu.cursor==1 ? count : menu.cursor-1
            result = theme_menu_selection!(menu)
        elseif data in ("\e[B","\eOB")
            menu.cursor = menu.cursor==count ? 1 : menu.cursor+1
            result = theme_menu_selection!(menu)
        elseif data in ("\e[5~","\e[6~") && count>0
            menu.cursor = clamp(menu.cursor+(data=="\e[5~" ? -1 : 1)*min(count,10),1,count)
            if previous!=menu.cursor
                result = theme_menu_selection!(menu)
            end
        elseif data=="\r" || data==" " && menu.mode==:automatic && menu.child==:none
            result = theme_menu_activate!(menu)
        elseif data in ("\e","\x03")
            result = theme_menu_cancel!(menu)
        end
    end
    result
end

theme_span(text,theme::NativeTheme,token::Symbol=:terminal_default) = Tachikoma.Span(String(text),theme_style(theme,token))
theme_line(text,theme::NativeTheme,token::Symbol=:terminal_default) = [theme_span(text,theme,token)]

"""Preserve the construction-time color of static text while wrapping and padding actual rows."""
function theme_text_lines(text,width,theme,token;bold::Bool=false)
    wrapped = theme_wrapped_text(text,width)
    [[Tachikoma.Span(line,theme_style(theme,token;bold)),Tachikoma.Span(repeat(" ",max(0,width-menu_search_width(line))),
        theme_style(theme,index==length(wrapped) ? :terminal_default : token;bold=index==length(wrapped) ? false : bold))] for (index,line) in enumerate(wrapped)]
end

"""Render live selection colors separately from the stable current marker."""
function theme_select_row(item,selected,width,primary,theme)
    prefix = selected ? "→ " : "  "
    style = selected ? :accent : :terminal_default
    if !isempty(item.description) && width>40
        primary = max(1,min(primary,width-6))
        label = menu_search_slice(item.label,0,max(1,primary-2))
        spacing = repeat(" ",max(1,primary-menu_search_width(label)))
        remaining = width-2-menu_search_width(label)-length(spacing)-2
        if remaining>10
            description = menu_search_slice(item.description,0,remaining)
            selected ? theme_line(prefix*label*spacing*description,theme,:accent) :
                [theme_span(prefix*label,theme),theme_span(spacing*description,theme,:muted)]
        else
            theme_line(prefix*menu_search_slice(item.label,0,max(0,width-4)),theme,style)
        end
    else
        theme_line(prefix*menu_search_slice(item.label,0,max(0,width-4)),theme,style)
    end
end

"""Render a ten-row selection viewport using the native runtime's current palette."""
function theme_select_lines!(menu,width,lines)
    items = theme_menu_items(menu)
    count = length(items)
    maximum_visible = min(count,10)
    start = max(1,min(menu.cursor-fld(maximum_visible,2),count-maximum_visible+1))
    stop = min(start+maximum_visible-1,count)
    menu.list_start,menu.list_row,menu.list_count = start,length(lines),maximum_visible
    theme = menu.runtime.active
    if isempty(items)
        push!(lines,theme_line("  No matching commands",theme,:muted))
    else
        primary = clamp(maximum(menu_search_width(item.label)+2 for item in items),12,32)
        for index in start:stop
            push!(lines,theme_select_row(items[index],index==menu.cursor,width,primary,theme))
        end
        if start>1 || stop<count
            push!(lines,theme_line(menu_search_slice("  ($(menu.cursor)/$count)",0,max(0,width-2)),theme,:muted))
        end
    end
    nothing
end

"""Draw the automatic-mode settings with exact value alignment and selected descriptions."""
function theme_automatic_lines!(menu,width,lines)
    items = theme_menu_items(menu)
    theme = menu.runtime.active
    menu.list_start,menu.list_row,menu.list_count = 1,length(lines),length(items)
    for (index,item) in enumerate(items)
        selected = index==menu.cursor
        prefix = selected ? "→ " : "  "
        label = rpad(item.label,11)
        value = menu_search_slice(get(item,:currentValue,""),0,max(0,width-17))
        chunks = [(prefix,selected ? menu.automatic_theme : theme,selected ? :accent : :terminal_default),
            (label,theme,selected ? :accent : :terminal_default),("  ",theme,:terminal_default),(value,theme,selected ? :accent : :muted)]
        total = sum(menu_search_width(first(chunk)) for chunk in chunks)
        limit = total>width ? max(0,width-3) : width
        row = Tachikoma.Span[]
        column = 0
        for (text,palette,token) in chunks
            content = menu_search_slice(text,0,max(0,limit-column))
            push!(row,theme_span(content,palette,token))
            column += menu_search_width(content)
        end
        if total>width
            push!(row,theme_span(first("...",min(max(0,width),3)),theme))
        end
        push!(lines,row)
    end
    if 1<=menu.cursor<=length(items)
        push!(lines,theme_line("",theme))
        for line in thinking_wrap(items[menu.cursor].description,width-4)
            push!(lines,theme_line("  "*line,theme,:text_dim))
        end
    end
    push!(lines,theme_line("",theme))
    hint = "  Enter/Space to change · Esc to cancel"
    clipped = menu_search_width(hint)>width
    push!(lines,[theme_span(menu_search_slice(hint,0,max(0,width-(clipped ? 3 : 0))),theme,:text_dim),
        theme_span(clipped ? first("...",min(max(0,width),3)) : "",theme)])
    nothing
end

"""Render the actual open selector, including mixed construction-time/live preview colors."""
function theme_menu_lines(menu::ThemeMenu,width::Integer;outer_border::Bool=true)
    columns = Int(width)
    lines = Vector{Tachikoma.Span}[]
    theme = menu.runtime.active
    if outer_border
        push!(lines,theme_line(repeat("─",max(1,columns)),theme,:menu_border))
    end
    if menu.standalone
        theme_select_lines!(menu,columns,lines)
    else
        if menu.mode==:automatic
            append!(lines,theme_text_lines("Automatic Theme",columns,menu.automatic_theme,:accent;bold=menu.automatic_theme.bold))
            push!(lines,theme_line("",theme))
            append!(lines,theme_text_lines("Choose themes for terminal light and dark appearance.",columns,menu.automatic_theme,:muted))
            append!(lines,theme_text_lines("Light/dark detection requires terminal support.",columns,menu.automatic_theme,:muted))
            push!(lines,theme_line("",theme))
        end
        if menu.mode==:automatic && menu.child==:none
            theme_automatic_lines!(menu,columns,lines)
        else
            title = menu.child==:light ? "Light Theme" : menu.child==:dark ? "Dark Theme" : "Theme"
            description = menu.child==:light ? "Select the theme to use for light terminal appearance" : menu.child==:dark ?
                "Select the theme to use for dark terminal appearance" : "Select a theme, or choose automatic to follow terminal appearance."
            append!(lines,theme_text_lines(title,columns,menu.header_theme,:accent;bold=menu.header_theme.bold))
            push!(lines,theme_line("",theme))
            append!(lines,theme_text_lines(description,columns,menu.header_theme,:muted))
            push!(lines,theme_line("",theme))
            theme_select_lines!(menu,columns,lines)
            push!(lines,theme_line("",theme))
            append!(lines,theme_text_lines("  Enter to select · Esc to go back",columns,menu.header_theme,:text_dim))
        end
    end
    if outer_border
        push!(lines,theme_line(repeat("─",max(1,columns)),theme,:menu_border))
    end
    menu.height = length(lines)
    lines
end

"""Route mouse press/click/wheel through the last actual rendered list viewport."""
function theme_menu_mouse!(menu::ThemeMenu,x::Int,y::Int;action::Symbol=:press,button::Symbol=:left,wheel_delta::Int=0)
    result = nothing
    items = theme_menu_items(menu)
    in_list = menu.list_row<=y<menu.list_row+menu.list_count
    if menu.open && in_list && !isempty(items)
        if action==:wheel && wheel_delta!=0
            previous = menu.cursor
            menu.cursor = clamp(menu.cursor+(wheel_delta<0 ? -1 : 1),1,length(items))
            if menu.cursor!=previous
                theme_menu_selection!(menu)
            end
            result = (handled=true,focus=false,render=menu.cursor!=previous)
        elseif button==:left && action in (:press,:click)
            index = menu.list_start+y-menu.list_row
            previous = menu.cursor
            menu.cursor = action==:click ? something(menu.pressed,index) : index
            if previous!=menu.cursor
                theme_menu_selection!(menu)
            end
            if action==:press
                menu.pressed = menu.cursor
                result = (handled=true,focus=true,render=nothing)
            else
                menu.pressed = nothing
                result = (handled=true,focus=false,render=nothing,request=theme_menu_activate!(menu))
            end
        end
    end
    result
end

"""Wrap styled prose, retaining the upstream ANSI-only blank boundary before overlong words."""
function theme_wrapped_text(text::AbstractString,width::Int)
    room = max(1,width)
    lines = String[]
    current = ""
    used = 0
    alive = false
    for matched in eachmatch(r" +|[^ ]+",text)
        token = String(matched.match)
        columns = menu_search_width(token)
        spaces = all(==(' '),token)
        if columns>room && !spaces
            if alive
                push!(lines,rstrip(current))
            end
            current = ""
            used = 0
            for grapheme in menu_search_graphemes(token)
                size = menu_search_width(grapheme)
                if used+size>room
                    push!(lines,rstrip(current))
                    current = ""
                    used = 0
                end
                current *= grapheme
                used += size
            end
            alive = true
        elseif used+columns>room && used>0
            push!(lines,rstrip(current))
            current = spaces ? "" : token
            used = spaces ? 0 : columns
            alive = true
        else
            current *= token
            used += columns
            alive = true
        end
    end
    if alive
        push!(lines,rstrip(current))
    end
    isempty(lines) ? [""] : lines
end
