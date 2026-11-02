# Native model menu state and rendering; Pi is a test-only MIT reference.
public SelectorModel, ModelMenu, ScopedModelMenu, ModelMenuAction
public model_menu_input!, model_menu_lines, model_menu_refresh!, model_menu_dispose!
public scoped_models_input!, scoped_models_lines, scoped_models_update!, scoped_models_saved!, scoped_models_status!
public model_menu_mouse!, scoped_models_mouse!

struct SelectorModel{P}
    provider::String
    id::String
    name::String
    payload::P
end
SelectorModel(provider::AbstractString,id::AbstractString;name=id,payload=nothing) = SelectorModel(String(provider),String(id),String(name),payload)
selector_key(model::SelectorModel) = model.provider * "/" * model.id
selector_model(model::JuliaForever2.ModelSpec) = SelectorModel(string(model.provider),model.id;
    name=model.metadata isa AbstractDict ? string(get(model.metadata,"name",model.id)) : model.id,payload=model)

"""Return requested effects without claiming that provider selection or persistence succeeded."""
Base.@kwdef struct ModelMenuAction
    kind::Symbol = :none
    value::Any = nothing
end

Base.@kwdef mutable struct ModelMenu
    models::Vector{SelectorModel} = SelectorModel[]
    scoped::Vector{SelectorModel} = SelectorModel[]
    current::Union{Nothing,String} = nothing
    default::Union{Nothing,String} = nothing
    scope::Symbol = :all
    search::MenuSearchInput = MenuSearchInput()
    filtered::Vector{SelectorModel} = SelectorModel[]
    cursor::Int = 1
    status::String = "Refreshing model catalogs…"
    status_kind::Symbol = :muted
    error::String = ""
    can_save::Bool = true
    closed::Bool = false
    width::Int = 0
    height::Int = 0
    search_row::Int = -1
end

Base.@kwdef mutable struct ScopedModelMenu
    models::Vector{SelectorModel} = SelectorModel[]
    enabled::Union{Nothing,Vector{String}} = nothing
    search::MenuSearchInput = MenuSearchInput()
    filtered::Vector{String} = String[]
    cursor::Int = 1
    dirty::Bool = false
    status::Union{Nothing,String} = nothing
    status_kind::Symbol = :muted
    width::Int = 0
    height::Int = 0
    search_row::Int = -1
end

"""Initialize a selector from an already available native model snapshot."""
function ModelMenu(models::AbstractVector;scoped=SelectorModel[],current=nothing,default=nothing,query="",can_save=true)
    menu=ModelMenu(;models=SelectorModel[models...],scoped=SelectorModel[scoped...],current,default,
        scope=isempty(scoped) ? :all : :scoped,can_save)
    model_menu_snapshot!(menu)
    menu_search_set!(menu.search,query)
    model_menu_filter!(menu)
    menu
end

function ScopedModelMenu(models::AbstractVector;enabled=nothing,status=nothing)
    menu=ScopedModelMenu(;models=SelectorModel[models...],enabled=isnothing(enabled) ? nothing : String.(enabled),status)
    scoped_models_filter!(menu)
    menu
end

ModelMenu(models::AbstractVector{<:JuliaForever2.ModelSpec};kwargs...) = ModelMenu(selector_model.(models);kwargs...)
ScopedModelMenu(models::AbstractVector{<:JuliaForever2.ModelSpec};kwargs...) = ScopedModelMenu(selector_model.(models);kwargs...)

"""Score fuzzy tokens without importing any runtime reference implementation."""
function selector_alignment(text,positions)
    total=0.0
    previous=0
    consecutive=0
    for position in positions
        if position==previous+1
            consecutive+=1
            total-=5consecutive
        else
            consecutive=0
            if previous>0
                total+=2(position-previous-1)
            end
        end
        if position==1 || isspace(text[position-1]) || text[position-1] in ('-','_','.','/',':')
            total-=10
        end
        total+=(position-1)/10
        previous=position
    end
    total
end

function selector_token_score(text::AbstractString,query::AbstractString;swap=true)
    letters,token=collect(lowercase(text)),collect(lowercase(query))
    positions=Int[]
    next=1
    for (position,character) in enumerate(letters)
        if next<=length(token) && token[next]==character
            push!(positions,position)
            next+=1
        end
    end
    score=Inf
    if length(positions)==length(token)
        score=selector_alignment(letters,positions)
        for first in 1:(length(letters)-length(token)+1)
            indices=collect(first:first+length(token)-1)
            if letters[indices]==token
                score=min(score,selector_alignment(letters,indices))
            end
        end
        if letters==token
            score-=100
        end
    elseif swap
        matched=match(r"^([a-z]+)([0-9]+)$|^([0-9]+)([a-z]+)$",lowercase(query))
        if !isnothing(matched)
            parts=filter(!isnothing,matched.captures)
            score=selector_token_score(text,string(parts[2],parts[1]);swap=false)+5
        end
    end
    score
end

function selector_filter(items,query::AbstractString,label;swap::Bool=true)
    tokens=split(strip(query),r"[\s/]+";keepempty=false)
    scored=[(item,sum(token->selector_token_score(label(item),token;swap),tokens;init=0.0)) for item in items]
    sort!(filter!(item->isfinite(last(item)),scored);by=last,alg=Base.Sort.MergeSort)
    [first(item) for item in scored]
end

function selector_name(model::SelectorModel)
    words(value)=filter(!isempty,split(lowercase(value),r"[^\p{L}\p{N}]+"))
    tokens=words(model.id)
    compact=join(tokens)
    name=strip(model.name)
    covered=all(word->word in tokens || length(word)>1 && occursin(word,compact),words(name))
    covered ? "" : name
end

selector_search(model::SelectorModel;leading=false) =
    string(leading ? model.id * " " : "",model.provider," ",selector_key(model)," ",model.provider," ",model.id," ",model.name)

function model_menu_snapshot!(menu::ModelMenu)
    sort!(menu.models;by=model->(selector_key(model)==menu.current ? 0 : selector_key(model)==menu.default ? 1 : 2,lowercase(model.provider)),alg=Base.Sort.MergeSort)
    byid=Dict(selector_key(model)=>model for model in menu.models)
    menu.scoped=[get(byid,selector_key(model),model) for model in menu.scoped]
    menu.filtered=copy(menu.scope==:scoped ? menu.scoped : menu.models)
    current=findfirst(model->selector_key(model)==menu.current,menu.filtered)
    menu.cursor=isnothing(current) ? clamp(menu.cursor,1,max(1,length(menu.filtered))) : current
    nothing
end

function model_menu_filter!(menu::ModelMenu)
    active=menu.scope==:scoped ? menu.scoped : menu.models
    query=menu.search.value
    filtered=selector_filter(active,query,model->selector_search(model)*(selector_key(model)==menu.default ? " default" : ""))
    if !isempty(strip(query)) && startswith("default",lowercase(strip(query)))
        defaults=filter(model->selector_key(model)==menu.default,active)
        filtered=[defaults;filter(model->selector_key(model)!=menu.default,filtered)]
    end
    menu.filtered=filtered
    menu.cursor=isempty(query) ? clamp(menu.cursor,1,max(1,length(filtered))) : 1
    nothing
end

"""Apply one completed catalog result only while its owning menu remains active."""
function model_menu_refresh!(menu::ModelMenu,models::AbstractVector;errors=String[],timed_out=false,reason="",runtime_error="")
    if !menu.closed
        menu.error=timed_out ? "Model refresh timed out; showing cached models." : !isempty(reason) ? "Could not refresh model catalogs: "*reason :
            length(errors)==1 ? "Could not refresh "*first(errors)*"; showing cached models." :
            length(errors)>1 ? "Could not refresh $(length(errors)) model catalogs ($(join(errors,", "))); showing cached models." : String(runtime_error)
        menu.status=isempty(menu.error) ? "Model catalogs refreshed." : ""
        menu.status_kind=:success
        if isempty(reason) && !timed_out
            menu.models=SelectorModel[models...]
            model_menu_snapshot!(menu)
            model_menu_filter!(menu)
        end
    end
    nothing
end
model_menu_dispose!(menu::ModelMenu) = (menu.closed=true;nothing)

function model_menu_input!(menu::ModelMenu,packet::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    result=ModelMenuAction()
    count=length(menu.filtered)
    navigation=native_selector_navigation(selectors,packet)
    if menu.search.pasting || occursin("\e[200~",packet)
        menu_search_input!(menu.search,packet)
        model_menu_filter!(menu)
    elseif packet=="\t"
        if !isempty(menu.scoped)
            menu.scope=menu.scope==:all ? :scoped : :all
            menu.cursor=1
            active=menu.scope==:scoped ? menu.scoped : menu.models
            current=findfirst(model->selector_key(model)==menu.current,active)
            if !isnothing(current)
                menu.cursor=current
            end
            model_menu_filter!(menu)
        end
    elseif navigation!=:none
        if count>0
            menu.cursor=navigation==:up ? mod1(menu.cursor-1,count) : navigation==:down ? mod1(menu.cursor+1,count) : clamp(menu.cursor+(navigation==:page_up ? -10 : 10),1,count)
        end
    elseif native_selector_matches(selectors,:confirm,packet)
        if count>0
            model_menu_dispose!(menu)
            result=ModelMenuAction(;kind=:select,value=menu.filtered[menu.cursor])
        end
    elseif native_selector_matches(selectors,:cancel,packet)
        model_menu_dispose!(menu)
        result=ModelMenuAction(;kind=:cancel)
    elseif packet=="\x13" && menu.can_save
        if count>0
            model_menu_dispose!(menu)
            result=ModelMenuAction(;kind=:default,value=menu.filtered[menu.cursor])
        end
    else
        submitted=menu_search_input!(menu.search,packet)==:submit
        if submitted && count>0
            model_menu_dispose!(menu)
            result=ModelMenuAction(;kind=:select,value=menu.filtered[menu.cursor])
        end
        model_menu_filter!(menu)
    end
    result
end

function scoped_models_order(menu::ScopedModelMenu)
    ids=selector_key.(menu.models)
    scoped_models_order(menu.enabled,ids)
end
scoped_models_order(::Nothing,ids::Vector{String}) = ids
scoped_models_order(enabled::Vector{String},ids::Vector{String}) = [enabled;filter(id->!(id in enabled),ids)]
scoped_models_enabled(menu::ScopedModelMenu,id::AbstractString) = scoped_models_enabled(menu.enabled,id)
scoped_models_enabled(::Nothing,id::AbstractString) = true
scoped_models_enabled(enabled::Vector{String},id::AbstractString) = id in enabled
scoped_models_model(menu::ScopedModelMenu,id::AbstractString) = begin
    index=findfirst(model->selector_key(model)==id,menu.models)
    isnothing(index) ? nothing : menu.models[index]
end
selector_search(::Nothing,id::AbstractString) = String(id)
selector_search(model::SelectorModel,id::AbstractString) = selector_search(model;leading=true)
function scoped_models_filter!(menu::ScopedModelMenu)
    menu.filtered=selector_filter(scoped_models_order(menu),menu.search.value,id->selector_search(scoped_models_model(menu,id),id))
    menu.cursor=clamp(menu.cursor,1,max(1,length(menu.filtered)))
    nothing
end
function scoped_models_update!(menu::ScopedModelMenu,models::AbstractVector;enabled=missing)
    selected=isempty(menu.filtered) ? nothing : menu.filtered[menu.cursor]
    if !ismissing(enabled)
        menu.enabled=isnothing(enabled) ? nothing : String.(enabled)
    end
    menu.models=SelectorModel[models...]
    scoped_models_filter!(menu)
    current=findfirst(==(selected),menu.filtered)
    if !isnothing(current)
        menu.cursor=current
    end
    nothing
end
scoped_models_status!(menu::ScopedModelMenu,message::AbstractString,kind::Symbol=:muted) = (menu.status=isnothing(menu.status) ? nothing : String(message);menu.status_kind=kind;nothing)
scoped_models_saved!(menu::ScopedModelMenu) = (menu.dirty=false;nothing)
function scoped_models_normalize(menu::ScopedModelMenu,ids::Vector{String})
    allids=selector_key.(menu.models)
    length(ids)==length(allids) && all(id->id in allids,ids) ? nothing : ids
end
function scoped_models_change!(menu::ScopedModelMenu,operation::Symbol,targets::Vector{String})
    enabled=menu.enabled
    allids=selector_key.(menu.models)
    if operation==:clear
        current=isnothing(enabled) ? allids : enabled
        menu.enabled=filter(id->!(id in targets),current)
    elseif operation==:enable && !isnothing(enabled)
        menu.enabled=scoped_models_normalize(menu,[enabled;filter(id->!(id in enabled),targets)])
    end
    menu.dirty=true
    scoped_models_filter!(menu)
    ModelMenuAction(;kind=:change,value=deepcopy(menu.enabled))
end

function scoped_models_input!(menu::ScopedModelMenu,packet::AbstractString;selectors::NativeSelectorBindings=NativeSelectorBindings())
    result=ModelMenuAction()
    enabled=menu.enabled
    count=length(menu.filtered)
    navigation=native_selector_navigation(selectors,packet)
    if menu.search.pasting || occursin("\e[200~",packet)
        menu_search_input!(menu.search,packet)
        scoped_models_filter!(menu)
    elseif navigation!=:none
        if count>0
            menu.cursor=navigation==:up ? mod1(menu.cursor-1,count) : navigation==:down ? mod1(menu.cursor+1,count) : clamp(menu.cursor+(navigation==:page_up ? -8 : 8),1,count)
        end
    elseif packet in ("\e[1;3A","\e[1;3B")
        if count>0 && !isnothing(enabled)
            index=findfirst(==(menu.filtered[menu.cursor]),enabled)
            delta=packet=="\e[1;3A" ? -1 : 1
            if !isnothing(index) && 1<=index+delta<=length(enabled)
                enabled[index],enabled[index+delta]=enabled[index+delta],enabled[index]
                menu.cursor+=delta
                menu.dirty=true
                scoped_models_filter!(menu)
                result=ModelMenuAction(;kind=:change,value=copy(enabled))
            end
        end
    elseif native_selector_matches(selectors,:confirm,packet) && count>0
        id=menu.filtered[menu.cursor]
        result=scoped_models_change!(menu,scoped_models_enabled(menu,id) ? :clear : :enable,[id])
    elseif packet in ("\x01","\x18")
        ids=isempty(menu.search.value) ? selector_key.(menu.models) : copy(menu.filtered)
        if packet=="\x18" && isempty(menu.search.value) && !isnothing(enabled)
            ids=copy(enabled)
        end
        result=scoped_models_change!(menu,packet=="\x01" ? :enable : :clear,ids)
    elseif packet=="\x10" && count>0
        model=scoped_models_model(menu,menu.filtered[menu.cursor])
        if !isnothing(model)
            ids=selector_key.(filter(item->item.provider==model.provider,menu.models))
            result=scoped_models_change!(menu,all(id->scoped_models_enabled(menu,id),ids) ? :clear : :enable,ids)
        end
    elseif packet=="\x13"
        result=ModelMenuAction(;kind=:persist,value=deepcopy(enabled))
    elseif native_binding_matches(packet,"ctrl+c";kitty=selectors.kitty)
        if isempty(menu.search.value)
            result=ModelMenuAction(;kind=:cancel)
        else
            menu_search_set!(menu.search, "")
            scoped_models_filter!(menu)
        end
    elseif native_binding_matches(packet,"escape";kitty=selectors.kitty)
        result=ModelMenuAction(;kind=:cancel)
    else
        menu_search_input!(menu.search,packet)
        scoped_models_filter!(menu)
    end
    result
end

const MODEL_MENU_COLORS=Dict(:accent=>(167,152,215),:border=>(95,168,204),:warning=>(205,154,34),:muted=>(157,165,169),:dim=>(126,136,142),:success=>(104,183,141),:error=>(234,127,129))
function model_menu_style(key::Symbol; bold=false, strike=false)
    runtime = isdefined(@__MODULE__, :ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    if !isnothing(runtime)
        bold=bold && runtime.catalog.bold
        strike=strike && runtime.catalog.bold
        key == :default ? Tachikoma.Style(; bold, strikethrough=strike) : theme_token_style(runtime, String(key); bold, strike)
    else
        Tachikoma.Style(;fg=haskey(MODEL_MENU_COLORS,key) ? Tachikoma.ColorRGB(MODEL_MENU_COLORS[key]...) : Tachikoma.NoColor(),bold,strikethrough=strike)
    end
end
model_menu_span(text::AbstractString,key::Symbol=:default;kwargs...) = Tachikoma.Span(String(text),model_menu_style(key;kwargs...))

struct ModelMenuGlyph
    text::String
    style::Tachikoma.Style
    after::Tachikoma.Style
    before_codes::Bool
end

function model_menu_trim!(glyphs::Vector{ModelMenuGlyph})
    trimming=true
    while trimming && !isempty(glyphs) && last(glyphs).text==" "
        glyph=last(glyphs)
        if glyph.after!=glyph.style
            trimming=false
        else
            pop!(glyphs)
            trimming=!glyph.before_codes
        end
    end
    nothing
end

"""Wrap styled content by words, retaining styles and terminal-default end padding."""
function model_menu_wrap(spans::AbstractVector{Tachikoma.Span},width::Integer)
    columns=max(1,width)
    glyphs=ModelMenuGlyph[]
    previous_style=Tachikoma.RESET
    for span in spans
        parts=collect(Base.Unicode.graphemes(replace(span.content,'\t'=>"   ")))
        for (index,part) in enumerate(parts)
            before=index==1 && (previous_style!=Tachikoma.RESET || span.style!=Tachikoma.RESET)
            push!(glyphs,ModelMenuGlyph(String(part),span.style,span.style,before))
        end
        previous_style=span.style
    end
    if !isempty(glyphs)
        glyph=last(glyphs)
        glyphs[end]=ModelMenuGlyph(glyph.text,glyph.style,Tachikoma.RESET,glyph.before_codes)
    end
    tokens=Vector{ModelMenuGlyph}[]
    for glyph in glyphs
        kind=glyph.text==" "
        cjk=occursin(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]",glyph.text)
        if isempty(tokens) || cjk || (last(last(tokens)).text==" ")!=kind || occursin(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]",last(last(tokens)).text)
            push!(tokens,ModelMenuGlyph[])
        end
        push!(last(tokens),glyph)
    end
    rows=Vector{ModelMenuGlyph}[]
    paddings=Tachikoma.Style[]
    current=ModelMenuGlyph[]
    used=0
    prefix_style=Tachikoma.RESET
    prefix_codes=false
    for token in tokens
        amount=sum(glyph->menu_search_width(glyph.text),token;init=0)
        whitespace=all(glyph->glyph.text==" ",token)
        if amount>columns && !whitespace
            if !isempty(current) || prefix_codes
                push!(paddings,isempty(current) ? prefix_style : last(current).after)
                model_menu_trim!(current)
                push!(rows,current)
                current=ModelMenuGlyph[]
                used=0
            end
            prefix_codes=false
            for glyph in token
                size=menu_search_width(glyph.text)
                if used+size>columns && used>0
                    push!(rows,current)
                    push!(paddings,last(current).after)
                    current=ModelMenuGlyph[]
                    used=0
                end
                push!(current,glyph)
                used+=size
            end
        elseif used+amount>columns && used>0
            pad=whitespace ? last(token).after : last(current).after
            model_menu_trim!(current)
            push!(rows,current)
            push!(paddings,pad)
            current=whitespace ? ModelMenuGlyph[] : copy(token)
            used=whitespace ? 0 : amount
            prefix_style=pad
            prefix_codes=whitespace && pad!=Tachikoma.RESET
        else
            append!(current,token)
            used+=amount
        end
    end
    if !isempty(current)
        push!(rows,current)
        push!(paddings,last(current).after)
    end
    result=Vector{Tachikoma.Span}[]
    for (row,pad) in zip(rows,paddings)
        content=Tachikoma.Span[Tachikoma.Span(glyph.text,glyph.style) for glyph in row]
        room=max(0,width-sum(glyph->menu_search_width(glyph.text),row;init=0))
        push!(content,Tachikoma.Span(repeat(" ",room),pad))
        push!(result,content)
    end
    result
end
model_menu_text!(lines,text,width,key=:default;kwargs...) = append!(lines,model_menu_wrap([model_menu_span(text,key;kwargs...)],width))
model_menu_text!(lines,spans::AbstractVector{Tachikoma.Span},width) = append!(lines,model_menu_wrap(spans,width))
model_menu_blank!(lines) = (push!(lines,Tachikoma.Span[]);nothing)

function model_menu_row(model::SelectorModel,selected,current;default=false,enabled=true,scoped=false)
    spans=[model_menu_span(selected ? "→ " : "  ",selected ? :accent : :default),model_menu_span(current && enabled ? "✓ " : "  ",current && enabled ? :accent : :default),model_menu_span(model.id,selected ? :accent : :default)]
    name=selector_name(model)
    if !isempty(name)
        push!(spans,model_menu_span(" ("*name*")",:muted))
    end
    if scoped
        push!(spans,model_menu_span(" ["*model.provider*"]",:muted))
    else
        append!(spans,[model_menu_span(" "),model_menu_span("["*model.provider*"]",:muted)])
    end
    if default
        push!(spans,model_menu_span(" · default",:muted))
    end
    spans
end

function model_menu_lines(menu::ModelMenu,width::Integer;selectors::NativeSelectorBindings=NativeSelectorBindings())
    lines=Vector{Tachikoma.Span}[]
    push!(lines,[model_menu_span(repeat("─",max(0,width)),:border)])
    model_menu_blank!(lines)
    if isempty(menu.scoped)
        model_menu_text!(lines,"Only showing models from configured providers. Use /login to add providers.",width,:warning)
    else
        model_menu_text!(lines,[model_menu_span("Scope: ",:muted),model_menu_span("all",menu.scope==:all ? :accent : :muted),model_menu_span(" | ",:muted),model_menu_span("scoped",menu.scope==:scoped ? :accent : :muted)],width)
        model_menu_text!(lines,[model_menu_span("tab",:dim),model_menu_span(" scope",:muted),model_menu_span(" (all/scoped)",:muted)],width)
    end
    model_menu_blank!(lines)
    menu.width=max(0,width)
    menu.search_row=length(lines)
    push!(lines,menu_search_spans(menu.search,width))
    model_menu_blank!(lines)
    count=length(menu.filtered)
    first=max(1,min(menu.cursor-5,count-9))
    last=min(first+9,count)
    for index in first:last
        model=menu.filtered[index]
        model_menu_text!(lines,model_menu_row(model,index==menu.cursor,selector_key(model)==menu.current;default=selector_key(model)==menu.default),width)
    end
    if first>1 || last<count
        model_menu_text!(lines,"  ($(menu.cursor)/$count)",width,:muted)
    end
    if !isempty(menu.error)
        for line in split(menu.error,'\n')
            model_menu_text!(lines,line,width,:error)
        end
    elseif count==0
        model_menu_text!(lines,"  No matching models",width,:muted)
    else
        model_menu_blank!(lines)
        model_menu_text!(lines,"  Model Name: "*menu.filtered[menu.cursor].name,width,:muted)
    end
    if !isempty(menu.status)
        model_menu_blank!(lines)
        model_menu_text!(lines,"  "*menu.status,width,menu.status_kind)
    end
    model_menu_blank!(lines)
    if menu.can_save
        model_menu_text!(lines,"  "*native_selector_text(selectors,:confirm;capitalize=true)*" to select · Ctrl+S to set as default · "*native_selector_text(selectors,:cancel;capitalize=true)*" to cancel",width,:dim)
    end
    push!(lines,[model_menu_span(repeat("─",max(0,width)),:border)])
    menu.height=length(lines)
    lines
end

function scoped_models_footer(menu::ScopedModelMenu;selectors::NativeSelectorBindings=NativeSelectorBindings())
    enabled=menu.enabled
    ids=selector_key.(menu.models)
    count_text=isnothing(enabled) ? "all enabled" : "$(count(id->id in ids,enabled))/$(length(ids)) enabled"
    unavailable=isnothing(enabled) ? 0 : count(id->!(id in ids),enabled)
    if unavailable>0
        count_text*=" · $unavailable unavailable"
    end
    text="  "*native_selector_text(selectors,:confirm;capitalize=true)*" toggle · Ctrl+A all · Ctrl+X clear · Ctrl+P provider · Alt+Up/Alt+Down reorder · Ctrl+S save · "*count_text
    spans=[model_menu_span(text*(menu.dirty ? " " : ""),:dim)]
    if menu.dirty
        push!(spans,model_menu_span("(unsaved)",:warning))
    end
    spans
end

function scoped_models_lines(menu::ScopedModelMenu,width::Integer;selectors::NativeSelectorBindings=NativeSelectorBindings())
    lines=Vector{Tachikoma.Span}[]
    push!(lines,[model_menu_span(repeat("─",max(0,width)),:border)])
    model_menu_blank!(lines)
    model_menu_text!(lines,"Model Configuration",width,:accent;bold=true)
    model_menu_text!(lines,"Session-only. Ctrl+S to save to settings.",width,:muted)
    model_menu_blank!(lines)
    menu.width=max(0,width)
    menu.search_row=length(lines)
    push!(lines,menu_search_spans(menu.search,width))
    model_menu_blank!(lines)
    count=length(menu.filtered)
    first=max(1,min(menu.cursor-4,count-7))
    last=min(first+7,count)
    for index in first:last
        id=menu.filtered[index]
        model=scoped_models_model(menu,id)
        selected=index==menu.cursor
        spans=if isnothing(model)
            [model_menu_span(selected ? "→ " : "  ",selected ? :accent : :default),model_menu_span("  "),model_menu_span(id,selected ? :accent : :default;strike=true),model_menu_span(" [unavailable]",:muted)]
        else
            model_menu_row(model,selected,scoped_models_enabled(menu,id);scoped=true)
        end
        model_menu_text!(lines,spans,width)
    end
    if first>1 || last<count
        model_menu_text!(lines,"  ($(menu.cursor)/$count)",width,:muted)
    end
    if count==0
        model_menu_text!(lines,"  No matching models",width,:muted)
    else
        model_menu_blank!(lines)
        model=scoped_models_model(menu,menu.filtered[menu.cursor])
        model_menu_text!(lines,"  "*(isnothing(model) ? "Model unavailable" : "Model Name: "*model.name),width,:muted)
    end
    model_menu_blank!(lines)
    status=menu.status
    if !isnothing(status)
        model_menu_text!(lines,"  "*status,width,menu.status_kind)
    end
    model_menu_text!(lines,scoped_models_footer(menu;selectors),width)
    push!(lines,[model_menu_span(repeat("─",max(0,width)),:border)])
    menu.height=length(lines)
    lines
end


"""Dispatch only the original search control; text model rows have no mouse action."""
function model_selector_mouse!(menu,x::Integer,y::Integer;action::Symbol=:press,button::Symbol=:left,wheel_delta::Integer=0,width::Integer=menu.width,height=nothing,bounded::Bool=true)
    if width!=menu.width || menu.search_row<0
        model_selector_lines(menu,width)
    end
    available=isnothing(height) ? menu.height : height
    result=nothing
    inside_y=0<=y<available
    inside_x=!bounded || 0<=x<width
    if inside_y && inside_x && y==menu.search_row
        if menu_search_click!(menu.search,x,0;button,action)
            result=(handled=true,focus=true,capture=false,render=nothing,target="search",focusTarget="selector",request=ModelMenuAction())
        end
    end
    result
end
model_selector_lines(menu::ModelMenu,width::Integer)=model_menu_lines(menu,width)
model_selector_lines(menu::ScopedModelMenu,width::Integer)=scoped_models_lines(menu,width)
model_menu_mouse!(menu::ModelMenu,x::Integer,y::Integer;kwargs...)=model_selector_mouse!(menu,x,y;kwargs...)
scoped_models_mouse!(menu::ScopedModelMenu,x::Integer,y::Integer;kwargs...)=model_selector_mouse!(menu,x,y;kwargs...)
