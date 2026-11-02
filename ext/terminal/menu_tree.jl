# Native session-graph navigation; external Pi source is used only by differential tests.
public TreeMenu, tree_menu, tree_selected, tree_input!, tree_lines, tree_update_label!
public tree_captures_viewport, tree_mouse!, tree_hardware_cursor, tree_dispose!, tree_draw!

Base.@kwdef mutable struct TreeMenuEntry
    id::String
    parent::Int = 0
    children::Vector{Int} = Int[]
    record::Dict{String,Any}
    label::Union{Nothing,String} = nothing
    label_time::Union{Nothing,String} = nothing
end

Base.@kwdef struct TreeMenuGeometry
    depth::Int = 0
    connector::Bool = false
    last::Bool = false
    gutters::Vector{Tuple{Int,Bool}} = Tuple{Int,Bool}[]
    virtual_root::Bool = false
end

Base.@kwdef mutable struct TreeMenu{S,C,L,P,N,Q,F}
    entries::Vector{TreeMenuEntry}
    indices::Dict{String,Int}
    order::Vector{Int}
    active::Vector{Int}
    leaf::Union{Nothing,String}
    on_select::S
    on_cancel::C
    on_label::L
    on_copy::P
    now::N
    schedule::Q
    style::F
    home::String = homedir()
    bold::Bool = false
    maximum_rows::Int = 12
    filter::String = "default"
    query::String = ""
    visible::Vector{Int} = Int[]
    cursor::Int = 1
    remembered::Union{Nothing,String} = nothing
    folded::Vector{Int} = Int[]
    parents::Dict{Int,Int} = Dict{Int,Int}()
    children::Dict{Int,Vector{Int}} = Dict{Int,Vector{Int}}()
    geometry::Dict{Int,TreeMenuGeometry} = Dict{Int,TreeMenuGeometry}()
    multiple_roots::Bool = false
    label_times::Bool = false
    editing::Int = 0
    input::MenuSearchInput = MenuSearchInput()
    focused::Bool = false
    label_row::Int = 0
    width::Int = 0
    timer::Any = nothing
    disposed::Bool = false
end

"""Construct independent menu entries from a session service's defensive tree projection."""
function tree_menu_entries(nodes::AbstractVector)
    entries = TreeMenuEntry[]
    stack = [(node, 0) for node in reverse(nodes)]
    while !isempty(stack)
        node, parent = pop!(stack)
        record = Dict{String,Any}(String(key) => deepcopy(value) for (key,value) in node["entry"])
        push!(entries, TreeMenuEntry(; id=String(record["id"]), parent, record,
            label=get(node,"label",nothing),label_time=get(node,"labelTimestamp",nothing)))
        index = length(entries)
        parent == 0 || push!(entries[parent].children,index)
        append!(stack, [(child,index) for child in reverse(node["children"])])
    end
    entries
end

"""Generate UTC labels without a dependency on an external process or date package."""
function tree_timestamp(seconds::Real=time())
    milliseconds = floor(Int,seconds*1000)
    days,within = fldmod(milliseconds,86_400_000)
    era,day = fldmod(days+719468,146097)
    year = div(day-div(day,1460)+div(day,36524)-div(day,146096),365)
    doy = day-(365year+div(year,4)-div(year,100))
    month = div(5doy+2,153)
    date = doy-div(153month+2,5)+1
    month += month<10 ? 3 : -9
    year += 400era+Int(month<=2)
    hour,within = divrem(within,3_600_000)
    minute,within = divrem(within,60_000)
    second,millis = divrem(within,1000)
    string(lpad(year,4,'0'),'-',lpad(month,2,'0'),'-',lpad(date,2,'0'),'T',
        lpad(hour,2,'0'),':',lpad(minute,2,'0'),':',lpad(second,2,'0'),'.',lpad(millis,3,'0'),'Z')
end
tree_schedule(callback, seconds) = Timer(_ -> callback(), seconds)

"""Build active-first navigation independently from session ownership and durable mutation."""
function tree_menu(nodes::AbstractVector, current_leaf; on_select, on_cancel, on_label=nothing,
        on_copy=Returns(nothing), height::Integer=24, initial_selected=nothing, filter::AbstractString="default",
        focused::Bool=false, now=tree_timestamp, schedule=tree_schedule, style=tree_default_style, bold::Bool=false,
        home::AbstractString=homedir())
    entries = tree_menu_entries(nodes)
    indices = Dict(entry.id=>index for (index,entry) in enumerate(entries))
    active = Int[]
    current = get(indices,current_leaf,0)
    while current != 0
        push!(active,current)
        current = entries[current].parent
    end
    active_set = Set(active)
    roots = [i for (i,entry) in enumerate(entries) if entry.parent == 0]
    prioritize(nodes) = sort(nodes; by=index->!(index in active_set),alg=Base.Sort.MergeSort)
    order = Int[]
    stack = reverse(prioritize(roots))
    while !isempty(stack)
        current = pop!(stack)
        push!(order,current)
        append!(stack,reverse(prioritize(entries[current].children)))
    end
    menu = TreeMenu(; entries,indices,order,active,leaf=current_leaf,on_select,on_cancel,on_label,on_copy,
        now,schedule,style,bold,home=String(home),maximum_rows=max(5,fld(height,2)),filter=String(filter),focused)
    tree_filter!(menu)
    menu.cursor = tree_nearest(menu,isnothing(initial_selected) ? current_leaf : initial_selected)
    menu.remembered = tree_selected(menu)
    if isempty(nodes)
        menu.timer = schedule(() -> menu.disposed ? nothing : menu.on_cancel(), 0.1)
    end
    menu
end

"""Return the selected original entry ID, never a reconstructed runtime-message index."""
tree_selected(menu::TreeMenu) = 1 <= menu.cursor <= length(menu.visible) ? menu.entries[menu.visible[menu.cursor]].id : nothing
tree_selected_entry(menu::TreeMenu) = 1 <= menu.cursor <= length(menu.visible) ? menu.visible[menu.cursor] : 0
tree_captures_viewport(menu::TreeMenu) = menu.editing == 0
tree_mouse!(::TreeMenu, args...; kwargs...) = nothing

"""Resolve a hidden selection through original ancestry, preserving last-visible fallback."""
function tree_nearest(menu::TreeMenu, id)
    result = isempty(menu.visible) ? 1 : length(menu.visible)
    current = get(menu.indices,id,0)
    found = false
    while current != 0 && !found
        index = findfirst(==(current),menu.visible)
        if isnothing(index)
            current = menu.entries[current].parent
        else
            result = index
            found = true
        end
    end
    result
end

tree_full_content(value) = ""
tree_full_content(value::AbstractString) = String(value)
tree_full_content(value::AbstractVector) = join(String(get(block,"text","")) for block in value if block isa AbstractDict && get(block,"type",nothing) == "text")

"""Bound interoperable text by UTF-16 units, as used in the reference display contract."""
function tree_utf16_prefix(value::AbstractString, count::Int)
    units = transcode(UInt16,String(value))
    transcode(String,units[1:min(length(units),max(0,count))])
end
tree_content(value) = tree_utf16_prefix(tree_full_content(value),200)
tree_message(entry::TreeMenuEntry) = get(entry.record,"message",Dict{String,Any}())

"""Build literal all-token search text without fuzzy ranking or display-only tool arguments."""
function tree_searchable(entry::TreeMenuEntry)
    record = entry.record
    kind = get(record,"type","")
    parts = String[]
    isnothing(entry.label) || isempty(entry.label) || push!(parts,entry.label)
    if kind == "message"
        message = tree_message(entry)
        push!(parts,get(message,"role",""),tree_content(get(message,"content",nothing)))
        get(message,"role","") == "bashExecution" && push!(parts,get(message,"command",""))
    elseif kind == "custom_message"
        content = get(record,"content","")
        push!(parts,get(record,"customType",""),content isa AbstractString ? content : tree_content(content))
    elseif kind == "compaction"
        push!(parts,"compaction")
    elseif kind == "branch_summary"
        push!(parts,"branch summary",get(record,"summary",""))
    elseif kind == "session_info"
        push!(parts,"title",something(get(record,"name",nothing),""))
    elseif kind == "model_change"
        push!(parts,"model",get(record,"modelId",""))
    elseif kind == "thinking_level_change"
        push!(parts,"thinking",get(record,"thinkingLevel",""))
    elseif kind == "custom"
        push!(parts,"custom",get(record,"customType",""))
    elseif kind == "context_edit"
        push!(parts,"context edit",isnothing(get(record,"replacement",nothing)) ? "omit" : "replace",get(record,"targetId",""))
    elseif kind == "label"
        push!(parts,"label",something(get(record,"label",nothing),""))
    end
    join(parts," ")
end

"""Exclude usage and empty successful assistants independently of the selected filter."""
function tree_included(menu::TreeMenu, index::Int, tokens)
    entry = menu.entries[index]
    record = entry.record
    kind = get(record,"type","")
    message = tree_message(entry)
    role = get(message,"role","")
    stop = get(message,"stopReason",nothing)
    text = strip(tree_full_content(get(message,"content",nothing)))
    empty_assistant = kind == "message" && role == "assistant" && entry.id != menu.leaf && isempty(text) &&
        (isnothing(stop) || isempty(stop) || stop in ("stop","toolUse"))
    settings = kind in ("label","context_edit","custom","model_change","thinking_level_change","session_info")
    mode = menu.filter
    passes = mode == "all" || (mode == "user-only" ? kind == "message" && role == "user" :
        mode == "labeled-only" ? !isnothing(entry.label) : !settings && !(mode == "no-tools" && role == "toolResult"))
    kind != "usage" && !empty_assistant && passes && all(token->occursin(token,lowercase(tree_searchable(entry))),tokens)
end

"""Rebuild the visible ancestry graph when search, filters or folds change."""
function tree_filter!(menu::TreeMenu)
    if !isempty(menu.visible)
        menu.remembered = something(tree_selected(menu),menu.remembered)
    end
    tokens = split(lowercase(menu.query))
    hidden = Set{Int}()
    folded = Set(menu.folded)
    for index in menu.order
        parent = menu.entries[index].parent
        (parent in folded || parent in hidden) && push!(hidden,index)
    end
    menu.visible = [index for index in menu.order if !(index in hidden) && tree_included(menu,index,tokens)]
    if !isempty(menu.visible)
        tree_geometry!(menu)
    end
    if !isnothing(menu.remembered)
        menu.cursor = tree_nearest(menu,menu.remembered)
    elseif menu.cursor > length(menu.visible)
        menu.cursor = max(1,length(menu.visible))
    end
    if !isempty(menu.visible)
        menu.remembered = something(tree_selected(menu),menu.remembered)
    end
    nothing
end

"""Lay out the filtered graph using branch depth, not chronological message depth."""
function tree_geometry!(menu::TreeMenu)
    visible = Set(menu.visible)
    empty!(menu.parents)
    empty!(menu.children)
    menu.children[0] = Int[]
    for index in menu.visible
        parent = menu.entries[index].parent
        while parent != 0 && !(parent in visible)
            parent = menu.entries[parent].parent
        end
        menu.parents[index] = parent
        push!(get!(menu.children,parent,Int[]),index)
    end
    roots = menu.children[0]
    menu.multiple_roots = length(roots)>1
    empty!(menu.geometry)
    for index in menu.visible
        parent = menu.parents[index]
        siblings = menu.children[parent]
        root = parent == 0
        connector = length(siblings)>1
        prior = get(menu.geometry,parent,TreeMenuGeometry())
        depth = root ? Int(menu.multiple_roots) : prior.depth + Int(connector || (prior.connector && prior.depth>0))
        gutters = copy(prior.gutters)
        if !root && prior.connector && !prior.virtual_root
            display = menu.multiple_roots ? max(0,prior.depth-1) : prior.depth
            push!(gutters,(max(0,display-1),!prior.last))
        end
        menu.geometry[index] = TreeMenuGeometry(;depth,connector,last=index==last(siblings),gutters,
            virtual_root=root && menu.multiple_roots)
    end
    nothing
end

"""Only visible roots and branch-segment starts can collapse descendants."""
function tree_foldable(menu::TreeMenu,index::Int)
    parent = get(menu.parents,index,0)
    !isempty(get(menu.children,index,Int[])) && (parent == 0 || length(get(menu.children,parent,Int[]))>1)
end

"""Navigate to the next visible segment boundary without changing durable session state."""
function tree_segment(menu::TreeMenu,direction::Symbol)
    current = tree_selected_entry(menu)
    target = menu.cursor
    done = current == 0
    while !done
        parent = get(menu.parents,current,0)
        children = get(menu.children,current,Int[])
        if direction == :down
            if isempty(children) || length(children)>1
                current = isempty(children) ? current : first(children)
                target = something(findfirst(==(current),menu.visible),menu.cursor)
                done = true
            else
                current = first(children)
            end
        else
            position = something(findfirst(==(current),menu.visible),menu.cursor)
            if parent == 0 || (length(get(menu.children,parent,Int[]))>1 && position<menu.cursor)
                target = position
                done = true
            else
                current = parent
            end
        end
    end
    target
end

tree_request() = (invoked=false,kind=:none,entry_id=nothing,value=nothing,outcome=nothing)
tree_request(kind,id,value,outcome) = (invoked=true,kind=kind,entry_id=id,value=value,outcome=outcome)
tree_label_callback(::Nothing,id,label) = nothing
tree_label_callback(callback,id,label) = callback(id,label)

"""Update only the menu's label view; the owner callback separately owns persistence."""
function tree_update_label!(menu::TreeMenu,id::AbstractString,label; timestamp=nothing)
    index = get(menu.indices,id,0)
    if index != 0
        entry = menu.entries[index]
        entry.label = label
        entry.label_time = isnothing(label) || isempty(label) ? nothing : something(timestamp,menu.now())
    end
    nothing
end

"""Copy original full text, not the display-truncated row or reconstructed runtime context."""
function tree_copy_text(entry::TreeMenuEntry)
    kind = get(entry.record,"type","")
    value = nothing
    if kind == "message"
        message = tree_message(entry)
        role = get(message,"role","")
        if role == "bashExecution"
            value = get(message,"command",nothing)
        elseif haskey(message,"content")
            value = tree_full_content(message["content"])
            isempty(value) && role == "assistant" && (value=get(message,"errorMessage",nothing))
        end
    elseif kind == "custom_message"
        value = tree_full_content(get(entry.record,"content",nothing))
    elseif kind in ("compaction","branch_summary")
        value = get(entry.record,"summary",nothing)
    end
    isnothing(value) || isempty(strip(value)) ? nothing : value
end

const TREE_MENU_FILTERS = ["default","no-tools","user-only","labeled-only","all"]

"""Route label editing through the native input while exposing actual owner outcomes."""
function tree_label_input!(menu::TreeMenu,data::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    result = tree_request()
    if native_selector_matches(selectors,:confirm,data)
        id = menu.entries[menu.editing].id
        text = strip(menu_search_text(menu.input))
        value = isempty(text) ? nothing : String(text)
        tree_update_label!(menu,id,value)
        outcome = tree_label_callback(menu.on_label,id,value)
        result = tree_request(:label,id,value,outcome)
        menu.editing = 0
    elseif native_selector_matches(selectors,:cancel,data)
        menu.editing = 0
    else
        menu_search_input!(menu.input,data)
    end
    result
end

"""Handle tree navigation and substring search without passing viewport keys to an editor."""
function tree_input!(menu::TreeMenu,data::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    result = tree_request()
    if menu.editing != 0
        result = tree_label_input!(menu,data;selectors)
    else
        count = length(menu.visible)
        navigation=native_selector_navigation(selectors,data)
        current = tree_selected_entry(menu)
        refilter = false
        clear_folds = false
        if navigation==:up
            count>0 && (menu.cursor = menu.cursor==1 ? count : menu.cursor-1)
        elseif navigation==:down
            count>0 && (menu.cursor = menu.cursor==count ? 1 : menu.cursor+1)
        elseif data in ("\e[1;5D","\e[1;3D")
            if current != 0 && tree_foldable(menu,current) && !(current in menu.folded)
                push!(menu.folded,current)
                refilter = true
            else
                menu.cursor = tree_segment(menu,:up)
            end
        elseif data in ("\e[1;5C","\e[1;3C")
            if current in menu.folded
                filter!(!=(current),menu.folded)
                refilter = true
            else
                menu.cursor = tree_segment(menu,:down)
            end
        elseif data in ("\e[D","\eOD","\x02") || navigation==:page_up
            menu.cursor = max(1,menu.cursor-menu.maximum_rows)
        elseif data in ("\e[C","\eOC","\x06") || navigation==:page_down
            menu.cursor = min(count,menu.cursor+menu.maximum_rows)
        elseif native_selector_matches(selectors,:confirm,data) && current != 0
            id = menu.entries[current].id
            result = tree_request(:select,id,nothing,menu.on_select(id))
        elseif data == "\x18"
            value = current == 0 ? nothing : tree_copy_text(menu.entries[current])
            result = tree_request(:copy,tree_selected(menu),value,menu.on_copy(value))
        elseif native_selector_matches(selectors,:cancel,data)
            if isempty(menu.query)
                result = tree_request(:cancel,nothing,nothing,menu.on_cancel())
            else
                menu.query = ""
                refilter = clear_folds = true
            end
        elseif data in ("\x04","\x14","\x15","\x0c","\x01","\x0f","\e[111;6u")
            if data in ("\x0f","\e[111;6u")
                index = something(findfirst(==(menu.filter),TREE_MENU_FILTERS),1)
                menu.filter = TREE_MENU_FILTERS[mod1(index+(data=="\x0f" ? 1 : -1),5)]
            else
                index = findfirst(==(data),("\x04","\x14","\x15","\x0c","\x01"))
                target = TREE_MENU_FILTERS[index]
                menu.filter = menu.filter == target ? "default" : target
            end
            refilter = clear_folds = true
        elseif data in ("\x7f","\x08")
            if !isempty(menu.query)
                menu.query = tree_utf16_prefix(menu.query,length(transcode(UInt16,menu.query))-1)
                refilter = clear_folds = true
            end
        elseif data == "L" && current != 0
            menu.editing = current
            menu_search_clear!(menu.input)
            menu_search_set!(menu.input,something(menu.entries[current].label,""))
        elseif data == "T"
            menu.label_times = !menu.label_times
        elseif !isempty(data) && !any(c->Int(c)<32 || Int(c)==127 || 128<=Int(c)<=159,data)
            menu.query *= data
            refilter = clear_folds = true
        end
        clear_folds && empty!(menu.folded)
        refilter && tree_filter!(menu)
    end
    result
end

tree_close_timer(::Nothing) = nothing
tree_close_timer(timer::Timer) = close(timer)
tree_close_timer(timer) = nothing
"""Release the empty-menu timer when a host replaces or closes this component."""
function tree_dispose!(menu::TreeMenu)
    menu.disposed = true
    tree_close_timer(menu.timer)
    nothing
end

include("menu_tree_render.jl")
