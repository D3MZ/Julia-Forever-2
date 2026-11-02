# Styled session-tree presentation over native graph state; no external renderer at runtime.

"""Supply native dark defaults while allowing the host to bind its live theme palette."""
function tree_default_style(token::Symbol)
    colors = Dict(:accent=>(167,152,215),:muted=>(157,165,169),:dim=>(126,136,142),
        :success=>(104,183,141),:error=>(234,127,129),:warning=>(205,154,34),
        :borderAccent=>(160,142,213),:customMessageLabel=>(167,152,215),:border=>(95,168,204))
    if token == :selectedBg
        Tachikoma.Style(;bg=Tachikoma.ColorRGB(33,59,73))
    elseif haskey(colors,token)
        Tachikoma.Style(;fg=Tachikoma.ColorRGB(colors[token]...))
    else
        Tachikoma.Style()
    end
end

"""Compose selection background and optional font attributes without replacing foregrounds."""
function tree_style(menu::TreeMenu,token::Symbol=:default; selected::Bool=false,bold::Bool=false,italic::Bool=false)
    base = menu.style(token)
    Tachikoma.Style(;fg=base.fg,bg=selected ? menu.style(:selectedBg).bg : base.bg,
        bold=base.bold || (menu.bold && bold),dim=base.dim,italic=base.italic || (menu.bold && italic),
        underline=base.underline,strikethrough=base.strikethrough,hyperlink=base.hyperlink)
end
tree_span(menu::TreeMenu,value::AbstractString,token::Symbol=:default;kwargs...) = Tachikoma.Span(String(value),tree_style(menu,token;kwargs...))
tree_line(menu::TreeMenu,value::AbstractString="",token::Symbol=:default;kwargs...) = [tree_span(menu,value,token;kwargs...)]
tree_width(spans::AbstractVector{Tachikoma.Span}) = sum(span->menu_search_width(span.content),spans;init=0)

"""Clip styled graphemes by columns, keeping terminal-default truncation markers separate."""
function tree_slice(spans::AbstractVector{Tachikoma.Span},start::Int,width::Int)
    result = Tachikoma.Span[]
    position = 0
    stop = start+max(0,width)
    for span in spans
        text = IOBuffer()
        for grapheme in menu_search_graphemes(span.content)
            size = menu_search_width(grapheme)
            if position >= start && position < stop && position+size <= stop
                print(text,grapheme)
            end
            position += size
        end
        push!(result,Tachikoma.Span(String(take!(text)),span.style))
    end
    result
end
function tree_truncate(spans::AbstractVector{Tachikoma.Span},width::Int;ellipsis::Bool=true)
    if tree_width(spans)<=max(0,width)
        spans
    else
        suffix = ellipsis ? first("...",clamp(width,0,3)) : ""
        [tree_slice(spans,0,max(0,width-length(suffix)));Tachikoma.Span(suffix,Tachikoma.Style())]
    end
end
tree_normalize(value::AbstractString) = String(strip(replace(value,'\n'=>' ','\t'=>' ')))

tree_line_number(value) = nothing
tree_line_number(value::Bool) = nothing
tree_line_number(value::Real) = isfinite(value) ? value : nothing
tree_line_number(value::AbstractString) = tree_line_number(tryparse(Float64,strip(value)))
tree_number_text(value::Real) = isinteger(value) && abs(value)<typemax(Int) ? string(Int(value)) : string(value)
function tree_read_range(args)::String
    offset,limit = get(args,"offset",nothing),get(args,"limit",nothing)
    start = isnothing(offset) ? 1 : tree_line_number(offset)
    count = tree_line_number(limit)
    if (isnothing(offset) && isnothing(limit)) || isnothing(start) || (!isnothing(limit) && isnothing(count))
        ""
    elseif isnothing(limit)
        string(":",tree_number_text(start))
    else
        finish = start+count-1
        string(":",tree_number_text(start),finish==0 ? "" : string("-",tree_number_text(finish)))
    end
end
tree_truth(value::Nothing) = false
tree_truth(value::Bool) = value
tree_truth(value::Real) = value != 0 && !isnan(value)
tree_truth(value::AbstractString) = !isempty(value)
tree_truth(value) = true
tree_string(value::AbstractString) = String(value)
tree_string(value::Nothing) = "null"
tree_string(value::Bool) = value ? "true" : "false"
tree_string(value::Real) = tree_number_text(value)
tree_string(value) = string(value)
tree_field(record,key,fallback::AbstractString="")::String = tree_string(something(get(record,key,nothing),fallback))
tree_argument(args,key,default::AbstractString="") = tree_truth(get(args,key,nothing)) ? tree_string(args[key]) : String(default)

"""Render built-in tool summaries from recorded calls, retaining a generic custom-tool path."""
function tree_tool_summary(name::AbstractString,args;home::AbstractString=homedir())::String
    name = String(name)::String
    args = args isa AbstractDict ? args : Dict{String,Any}()
    path = tree_argument(args,"path",tree_argument(args,"file_path"))::String
    if !isempty(home) && (path==home || startswith(path,home*"/"))
        path = "~"*chop(path;head=length(home),tail=0)
    end
    if name in ("read","write","edit")
        string("[",name,": ",path,name=="read" ? tree_read_range(args) : "","]")
    elseif name=="bash"
        raw = tree_argument(args,"command")::String
        string("[bash: ", tree_utf16_prefix(tree_normalize(raw),50), length(transcode(UInt16,raw))>50 ? "..." : "", "]")
    elseif name in ("grep","find","ls")
        path = isempty(path) ? "." : path
        pattern = tree_argument(args,"pattern")
        name=="grep" ? "[grep: /$pattern/ in $path]" : name=="find" ? "[find: $pattern in $path]" : "[ls: $path]"
    else
        encoded = String(JSON.json(args))
        "[$name: "*tree_utf16_prefix(encoded,40)*(length(transcode(UInt16,encoded))>40 ? "..." : "")*"]"
    end
end

"""Resolve recorded tool calls independently of which assistant rows are visible."""
function tree_tools(menu::TreeMenu)
    calls = Dict{String,Tuple{String,Any}}()
    for index in menu.order
        message = tree_message(menu.entries[index])
        content = get(message,"content",nothing)
        if get(message,"role","")=="assistant" && content isa AbstractVector
            for block in content
                if block isa AbstractDict && get(block,"type","")=="toolCall"
                    calls[block["id"]] = (block["name"],block["arguments"])
                end
            end
        end
    end
    calls
end

"""Produce role-specific presentation spans without flattening rich session entry kinds."""
function tree_entry_spans(menu::TreeMenu,entry::TreeMenuEntry,selected::Bool,calls)
    row = Tachikoma.Span[]
    add(text,token=:default;italic=false) = push!(row,tree_span(menu,text,token;selected,bold=selected,italic))
    record = entry.record
    kind = get(record,"type","")
    if kind=="message"
        message = tree_message(entry)
        role = get(message,"role","")
        text = tree_normalize(tree_content(get(message,"content",nothing)))
        if role=="user"
            add("user: ",:accent);add(text)
        elseif role=="assistant"
            add("assistant: ",:success)
            if !isempty(text)
                add(text)
            elseif get(message,"stopReason",nothing)=="aborted"
                add("(aborted)",:muted)
            elseif tree_truth(get(message,"errorMessage",nothing))
                add(tree_utf16_prefix(tree_normalize(message["errorMessage"]),80),:error)
            else
                add("(no content)",:muted)
            end
        elseif role=="toolResult"
            call = get(calls,get(message,"toolCallId",nothing),nothing)
            name = tree_string(something(get(message,"toolName",nothing),"tool"))
            text = isnothing(call) ? "[$name]" : tree_tool_summary(call...;home=menu.home)
            add(text,:muted)
        elseif role=="bashExecution"
            add("[bash]: "*tree_normalize(get(message,"command","")),:dim)
        else
            add("[$role]",:dim)
        end
    elseif kind=="custom_message"
        add("["*tree_field(record,"customType")*"]: ",:customMessageLabel)
        add(tree_normalize(tree_full_content(get(record,"content",nothing))))
    elseif kind=="compaction"
        tokens = floor(Int,get(record,"tokensBefore",0)/1000+0.5)
        add("[compaction: $(tokens)k tokens]",:borderAccent)
    elseif kind=="branch_summary"
        add("[branch summary]: ",:warning);add(tree_normalize(get(record,"summary","")))
    elseif kind=="model_change"
        add("[model: "*tree_field(record,"modelId")*"]",:dim)
    elseif kind=="thinking_level_change"
        add("[thinking: "*tree_field(record,"thinkingLevel")*"]",:dim)
    elseif kind=="custom"
        add("[custom: "*tree_field(record,"customType")*"]",:dim)
    elseif kind=="context_edit"
        add("[context "*(isnothing(get(record,"replacement",nothing)) ? "omit" : "replace")*": "*tree_field(record,"targetId")*"]",:dim)
    elseif kind=="label"
        add("[label: "*tree_field(record,"label","(cleared)")*"]",:dim)
    elseif kind=="session_info"
        add("[title: ",:dim)
        name = get(record,"name",nothing)
        empty_name = isnothing(name) || isempty(name)
        add(empty_name ? "empty" : tree_string(name),:dim;italic=empty_name)
        add("]",:dim)
    end
    row
end

"""Convert a valid UTC archive timestamp into local civil fields without changing TZ."""
function tree_local_stamp(timestamp::AbstractString)
    matched = match(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})",timestamp)
    if isnothing(matched)
        (year=0,month=0,day=0,hour=0,minute=0)
    else
        year,month,day,hour,minute,second = parse.(Int,matched.captures)
        adjusted = year-Int(month<=2)
        era = fld(adjusted,400)
        within = adjusted-era*400
        doy = fld(153*(month+(month>2 ? -3 : 9))+2,5)+day-1
        days = era*146097+within*365+fld(within,4)-fld(within,100)+doy-719468
        local_text = Base.Libc.strftime("%Y-%m-%dT%H:%M",days*86400+hour*3600+minute*60+second)
        (year=parse(Int,local_text[1:4]),month=parse(Int,local_text[6:7]),day=parse(Int,local_text[9:10]),
            hour=parse(Int,local_text[12:13]),minute=parse(Int,local_text[15:16]))
    end
end
function tree_label_time(menu::TreeMenu,timestamp::AbstractString)
    date,now = tree_local_stamp(timestamp),tree_local_stamp(menu.now())
    time = lpad(date.hour,2,'0')*":"*lpad(date.minute,2,'0')
    if (date.year,date.month,date.day)==(now.year,now.month,now.day)
        time
    elseif date.year==now.year
        "$(date.month)/$(date.day) $time"
    else
        lpad(mod(date.year,100),2,'0')*"/$(date.month)/$(date.day) $time"
    end
end

"""Retain branch gutters and active-path markers when panning deeply nested selections."""
function tree_prefix(menu::TreeMenu,index::Int)
    geometry = menu.geometry[index]
    depth = menu.multiple_roots ? max(0,geometry.depth-1) : geometry.depth
    connector = geometry.connector && !geometry.virtual_root
    folded = index in menu.folded
    chars = IOBuffer()
    for position in 0:depth*3-1
        level,part = divrem(position,3)
        gutter = findfirst(pair->first(pair)==level,geometry.gutters)
        if !isnothing(gutter)
            print(chars,part==0 && last(geometry.gutters[gutter]) ? '│' : ' ')
        elseif connector && level==depth-1
            print(chars,part==0 ? (geometry.last ? '└' : '├') : part==1 ? (folded ? '⊞' : tree_foldable(menu,index) ? '⊟' : '─') : ' ')
        else
            print(chars,' ')
        end
    end
    selected = index==tree_selected_entry(menu)
    spans = tree_line(menu,String(take!(chars)),:dim;selected)
    folded && !connector && push!(spans,tree_span(menu,"⊞ ",:accent;selected))
    index in menu.active && push!(spans,tree_span(menu,"• ",:accent;selected))
    spans
end

function tree_status(menu::TreeMenu)
    label = menu.filter=="default" ? "" : menu.filter=="user-only" ? " [user]" :
        menu.filter=="labeled-only" ? " [labeled]" : " [$(menu.filter)]"
    label*(menu.label_times ? " [+label time]" : "")
end

"""Render the scroll window with a fixed selection gutter and a shared horizontal offset."""
function tree_list_lines(menu::TreeMenu,width::Int)
    lines = Vector{Tachikoma.Span}[]
    if isempty(menu.visible)
        push!(lines,tree_truncate(tree_line(menu,"  No entries found",:muted),width))
        push!(lines,tree_truncate(tree_line(menu,"  (0/0)"*tree_status(menu),:muted),width))
    else
        start = max(1,min(menu.cursor-fld(menu.maximum_rows,2),length(menu.visible)-menu.maximum_rows+1))
        stop = min(start+menu.maximum_rows-1,length(menu.visible))
        calls = tree_tools(menu)
        bodies = Vector{Tachikoma.Span}[]
        anchors = Int[]
        gutters = Vector{Tachikoma.Span}[]
        for position in start:stop
            index = menu.visible[position]
            entry = menu.entries[index]
            selected = position==menu.cursor
            push!(gutters,tree_line(menu,selected ? "› " : "  ",selected ? :accent : :default;selected))
            body = tree_prefix(menu,index)
            push!(anchors,tree_width(body))
            if !isnothing(entry.label) && !isempty(entry.label)
                push!(body,tree_span(menu,"[$(entry.label)] ",:warning;selected))
                timestamp = entry.label_time
                if menu.label_times && !isnothing(timestamp)
                    push!(body,tree_span(menu,tree_label_time(menu,timestamp)*" ",:muted;selected))
                end
            end
            append!(body,tree_entry_spans(menu,entry,selected,calls))
            push!(bodies,body)
        end
        room = max(0,width-2)
        scroll_max = max(0,maximum(tree_width,bodies)-room)
        offset = 0
        selected = menu.cursor-start+1
        if 1<=selected<=length(anchors) && scroll_max>0
            min_content = min(20,max(4,fld(room,3)))
            if anchors[selected]>room-min_content
                context = min(12,max(2,fld(room,4)))
                offset = min(scroll_max,anchors[selected]-context)
            end
        end
        for index in eachindex(bodies)
            body = offset>0 ? tree_slice(bodies[index],offset,room) : bodies[index]
            push!(lines,tree_truncate([gutters[index];body],width;ellipsis=false))
        end
        push!(lines,tree_truncate(tree_line(menu,"  ($(menu.cursor)/$(length(menu.visible)))"*tree_status(menu),:muted),width))
    end
    lines
end

const TREE_MENU_HELP = ["↑/↓ move","←/→ page","ctrl+←/→ branch","ctrl+x copy","shift+l label","shift+t label time", "filters ctrl+d/t/u/l/a","cycle ctrl+o/shift+ctrl+o"]

"""Keep semantic help chunks together before wrapping individual overlong chunks."""
function tree_help_lines(menu::TreeMenu,width::Int;selectors::NativeSelectorBindings=NativeSelectorBindings())
    available = max(1,width)
    current = ""
    lines = String[]
    for item in [native_selector_move_hint(selectors,"↑/↓")*" move";TREE_MENU_HELP[2:end]]
        candidate = isempty(current) ? (menu_search_width("  "*item)<=available ? "  "*item : item) : current*" · "*item
        if isempty(current) || menu_search_width(candidate)<=available
            current = candidate
        else
            append!(lines,thinking_wrap(rstrip(current),available))
            current = menu_search_width("  "*item)<=available ? "  "*item : item
        end
    end
    isempty(current) || append!(lines,thinking_wrap(rstrip(current),available))
    [tree_line(menu,line,:muted) for line in lines]
end

"""Render the actual component including inline label editing and parent viewport capture."""
function tree_lines(menu::TreeMenu,width::Integer;selectors::NativeSelectorBindings=NativeSelectorBindings())
    columns = Int(width)
    menu.width = columns
    lines = Vector{Tachikoma.Span}[]
    push!(lines,tree_line(menu))
    border = tree_line(menu,repeat("─",max(1,columns)),:border)
    push!(lines,border)
    pad = min(1,max(0,fld(columns-1,2)))
    title = thinking_wrap("  Session Tree",max(1,columns-2pad))
    for (index,line) in enumerate(title)
        push!(lines,[tree_span(menu,repeat(" ",pad);bold=index>1),tree_span(menu,line;bold=true),
            tree_span(menu,repeat(" ",max(pad,columns-pad-menu_search_width(line)));bold=index<length(title))])
    end
    append!(lines,tree_help_lines(menu,columns;selectors))
    search = [tree_span(menu,"  "),tree_span(menu,"Type to search:",:muted)]
    isempty(menu.query) || append!(search,[tree_span(menu," "),tree_span(menu,menu.query,:accent)])
    push!(lines,tree_truncate(search,columns))
    push!(lines,border,tree_line(menu))
    if menu.editing == 0
        append!(lines,tree_list_lines(menu,columns))
    else
        push!(lines,tree_truncate([tree_span(menu,"  "),tree_span(menu,"Label (empty to remove):",:muted)],columns))
        menu.label_row = length(lines)
        push!(lines,tree_truncate([tree_span(menu,"  ");menu_search_spans(menu.input,columns-2)],columns))
        push!(lines,tree_truncate([tree_span(menu,"  "),tree_span(menu,native_selector_text(selectors,:confirm),:dim),tree_span(menu," save",:muted),
            tree_span(menu,"  "),tree_span(menu,native_selector_text(selectors,:cancel),:dim),tree_span(menu," cancel",:muted)],columns))
    end
    push!(lines,tree_line(menu),border)
    lines
end

"""Report the input's IME cursor location without deciding hardware cursor visibility."""
function tree_hardware_cursor(menu::TreeMenu)
    if menu.editing != 0 && menu.focused && menu.width>4
        runs = menu_search_render!(menu.input,menu.width-2)
        (row=menu.label_row,col=2+menu_search_width(first(runs).text))
    else
        nothing
    end
end

"""Write native styled graphemes into real cells using the menu's measured terminal widths."""
function tree_draw!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,menu::TreeMenu)
    lines = tree_lines(menu,width)
    limit = x+max(0,width)-1
    for (row,spans) in enumerate(lines)
        column,previous = x,x-1
        for span in spans
            clean = replace(span.content,MENU_SEARCH_ANSI=>"")
            clean = join(iscntrl(character) ? ' ' : character for character in clean)
            for grapheme in Base.Unicode.graphemes(clean)
                glyph = String(grapheme)
                columns = menu_search_grapheme_width(glyph)
                if columns == 0 && previous>=x && Tachikoma.in_bounds(buffer,previous,y+row-1)
                    offset = Tachikoma.buf_index(buffer,previous,y+row-1)
                    cell = buffer.content[offset]
                    Tachikoma.set!(buffer,previous,y+row-1,Tachikoma.Cell(cell.char,cell.style,cell.suffix*glyph))
                elseif columns>0 && column+columns-1<=limit
                    characters = collect(glyph)
                    Tachikoma.set!(buffer,column,y+row-1,Tachikoma.Cell(first(characters),span.style,join(characters[2:end])))
                    for offset in 1:columns-1
                        Tachikoma.set!(buffer,column+offset,y+row-1,Tachikoma.Cell('\0',span.style))
                    end
                    previous = column
                    column += columns
                end
            end
        end
    end
    nothing
end
