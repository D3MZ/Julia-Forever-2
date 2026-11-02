"""Clip native label spans by grapheme columns without emitting raw terminal escapes into cells."""
function thinking_defaults_label_spans(menu::ThinkingDefaultsMenu,item::ThinkingDefaultsItem,width::Int,selected::Bool)
    theme=menu.runtime.active
    style=selected ? :accent : :terminal_default
    prefix=menu_search_slice(item.label,0,max(0,width))
    row=[theme_span(prefix,theme,style)]
    used=menu_search_width(prefix)
    if !isnothing(item.provider) && used<width
        provider=menu_search_slice("["*item.provider*"]",0,width-used)
        push!(row,theme_span(provider,menu.baked_theme,:muted))
    end
    row
end
thinking_defaults_plain(item::ThinkingDefaultsItem) = item.label*(isnothing(item.provider) ? "" : "["*item.provider*"]")

"""Render a source-compatible select row with baked provider text and dynamic selection colors."""
function thinking_defaults_row(menu,item,selected,width,primary)
    theme=menu.runtime.active
    key=selected ? :accent : :terminal_default
    label=thinking_defaults_plain(item)
    limit=max(0,width-4)
    suffix=""
    suffix_key=key
    description=strip(replace(item.description,r"[\r\n]+"=>" "))
    if !isempty(description) && width>40
        effective=max(1,min(primary,width-6))
        clipped=menu_search_slice(label,0,max(1,effective-2))
        spacing=repeat(" ",max(1,effective-menu_search_width(clipped)))
        remaining=width-2-menu_search_width(clipped)-length(spacing)-2
        if remaining>10
            limit=max(1,effective-2)
            suffix=spacing*menu_search_slice(description,0,remaining)
            suffix_key=selected ? (!isnothing(item.provider) || menu_search_width(label)>limit ? :terminal_default : :accent) : :muted
        end
    end
    spans=[theme_span(selected ? "→ " : "  ",theme,key)]
    append!(spans,thinking_defaults_label_spans(menu,item,limit,selected))
    if !isempty(suffix)
        push!(spans,theme_span(suffix,theme,suffix_key))
    end
    spans
end

"""Render the actual per-model submenu, preserving its fixed step text and live list palette."""
function thinking_defaults_lines(menu::ThinkingDefaultsMenu,width::Integer;outer_border=true,selectors::NativeSelectorBindings=NativeSelectorBindings())
    columns=Int(width)
    theme=menu.runtime.active
    lines=Vector{Tachikoma.Span}[]
    if outer_border
        push!(lines,theme_line(repeat("─",max(1,columns)),theme,:menu_border))
    end
    key=get(menu.context,"model","")
    index=findfirst(model->thinking_defaults_key(model)==key,menu.models)
    model=isnothing(index) ? nothing : menu.models[index]
    title=menu.step==:model ? "Per-Model Thinking Level" : "Thinking Level for "*(isnothing(model) ? key : model.id*" ["*model.provider*"]")
    description=menu.step==:model ? "Step 1/2 · Select a model to configure" : "Step 2/2 · Select default thinking level for this model"
    append!(lines,theme_text_lines(title,columns,menu.baked_theme,:accent;bold=menu.baked_theme.bold))
    push!(lines,theme_line("",theme))
    append!(lines,theme_text_lines(description,columns,menu.baked_theme,:muted))
    if menu.step==:model
        push!(lines,theme_line("",theme))
        push!(lines,menu_search_spans(menu.search,columns))
    end
    push!(lines,theme_line("",theme))
    count=length(menu.filtered)
    if count==0
        push!(lines,theme_line("  No matching commands",theme,:muted))
    else
        visible=min(count,10)
        start=max(1,min(menu.cursor-fld(visible,2),count-visible+1))
        stop=min(start+visible-1,count)
        maximum_width=menu.step==:model ? 46 : 32
        primary=clamp(maximum(menu_search_width(thinking_defaults_plain(menu.items[index]))+2 for index in menu.filtered),12,maximum_width)
        for position in start:stop
            push!(lines,thinking_defaults_row(menu,menu.items[menu.filtered[position]],position==menu.cursor,columns,primary))
        end
        if start>1 || stop<count
            push!(lines,theme_line(menu_search_slice("  ($(menu.cursor)/$count)",0,max(0,columns-2)),theme,:muted))
        end
    end
    push!(lines,theme_line("",theme))
    hint=(menu.step==:model ? "  Type to filter · " : "  ")*native_selector_hint(selectors,:confirm,"Enter";capitalize=true)*" to select · "*native_selector_hint(selectors,:cancel,"Esc";capitalize=true)*" to go back"
    append!(lines,theme_text_lines(hint,columns,menu.baked_theme,:text_dim))
    if outer_border
        push!(lines,theme_line(repeat("─",max(1,columns)),theme,:menu_border))
    end
    lines
end
