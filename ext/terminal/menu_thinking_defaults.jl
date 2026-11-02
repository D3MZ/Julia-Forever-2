# Native per-model thinking defaults. Pi text/behavior is MIT; see theme_assets/LICENSE.
public ThinkingDefaultsModel, ThinkingDefaultsMenu, thinking_defaults_menu
public thinking_defaults_input!, thinking_defaults_mouse!, thinking_defaults_lines, thinking_defaults_summary

Base.@kwdef struct ThinkingDefaultsModel
    provider::String
    id::String
    levels::Vector{String} = String[]
end
ThinkingDefaultsModel(provider::AbstractString,id::AbstractString;reasoning=true,thinking_level_map=Dict{String,Any}()) =
    ThinkingDefaultsModel(;provider=String(provider),id=String(id),levels=supported_thinking_levels(reasoning,thinking_level_map))
thinking_defaults_key(model::ThinkingDefaultsModel) = model.provider*"/"*model.id

Base.@kwdef struct ThinkingDefaultsItem
    value::String
    label::String
    provider::Union{Nothing,String} = nothing
    description::String = ""
end
Base.@kwdef mutable struct ThinkingDefaultsMenu{S,R,C}
    runtime::ThemeRuntime
    models::Vector{ThinkingDefaultsModel}
    on_set::S
    on_remove::R
    on_cancel::C
    overrides::Dict{String,String} = Dict{String,String}()
    current::Union{Nothing,String} = nothing
    default_model::Union{Nothing,String} = nothing
    global_level::String = "medium"
    open::Bool = true
    step::Symbol = :model
    context::Dict{String,String} = Dict{String,String}()
    search::MenuSearchInput = MenuSearchInput()
    items::Vector{ThinkingDefaultsItem} = ThinkingDefaultsItem[]
    filtered::Vector{Int} = Int[]
    cursor::Int = 1
    baked_theme::NativeTheme
    original_parent_theme::NativeTheme
    original_summary::String = "none"
    summary::String = "none"
    last_error::String = ""
end
thinking_defaults_summary(values::AbstractDict) = isempty(values) ? "none" : "$(length(values)) configured"
thinking_defaults_summary(menu::ThinkingDefaultsMenu) = thinking_defaults_summary(menu.overrides)

"""Create independent defaults state with real save/remove callbacks, never changing active model configuration."""
function thinking_defaults_menu(runtime::ThemeRuntime,models::AbstractVector;on_set,on_remove,on_cancel,
        overrides=Dict{String,String}(),current=nothing,default_model=nothing,global_level="medium")
    values=Dict{String,String}(String(key)=>String(value) for (key,value) in overrides)
    available=ThinkingDefaultsModel[models...]
    valid_default=any(model->thinking_defaults_key(model)==default_model,available) ? default_model : nothing
    summary=thinking_defaults_summary(values)
    menu=ThinkingDefaultsMenu(;runtime,models=available,on_set,on_remove,on_cancel,overrides=values,
        current,default_model=valid_default,global_level=String(global_level),baked_theme=runtime.active,
        original_parent_theme=runtime.active,original_summary=summary,summary)
    thinking_defaults_step!(menu,:model)
    menu
end

"""Build the actual supported choices, including unavailable-model summaries and per-model removal."""
function thinking_defaults_items(menu::ThinkingDefaultsMenu)
    if menu.step==:model
        sorted=sort(menu.models;by=model->(thinking_defaults_key(model)==menu.current ? 0 :
            thinking_defaults_key(model)==menu.default_model ? 1 : 2,Base.tail(theme_name_key(model.provider))),alg=Base.Sort.MergeSort)
        result=[ThinkingDefaultsItem(;value=thinking_defaults_key(model),label=model.id*" ",provider=model.provider,
            description=get(menu.overrides,thinking_defaults_key(model),"")) for model in sorted]
        isempty(result) ? [ThinkingDefaultsItem(;value="__none__",label="No models available",description="Log in to a provider or configure an API key first")] : result
    else
        key=get(menu.context,"model","")
        index=findfirst(model->thinking_defaults_key(model)==key,menu.models)
        items=ThinkingDefaultsItem[]
        if !isnothing(index)
            current=get(menu.overrides,key,nothing)
            for level in menu.models[index].levels
                push!(items,ThinkingDefaultsItem(;value=level,label=(level==current ? "✓ " : "  ")*level,
                    description=get(THINKING_MENU_DESCRIPTIONS,level,"")))
            end
            if haskey(menu.overrides,key)
                push!(items,ThinkingDefaultsItem(;value="__clear__",label="  (clear override)",description="Revert to global default ($(menu.global_level))"))
            end
        end
        items
    end
end

"""Construct each step afresh, resetting search and using original current/default preselection."""
function thinking_defaults_step!(menu::ThinkingDefaultsMenu,step::Symbol)
    menu.step=step
    menu.baked_theme=menu.runtime.active
    menu_search_set!(menu.search,"")
    menu.items=thinking_defaults_items(menu)
    menu.filtered=collect(eachindex(menu.items))
    selected=step==:model ? something(menu.current,something(menu.default_model,"")) : get(menu.overrides,get(menu.context,"model",""),"")
    index=findfirst(item->item.value==selected,menu.items)
    menu.cursor=isnothing(index) ? 1 : index
    nothing
end

"""Retain embedded provider color sequences in fuzzy keys because the original filters its styled label."""
function thinking_defaults_label(menu::ThinkingDefaultsMenu,item::ThinkingDefaultsItem)
    label=item.label
    if !isnothing(item.provider)
        style=theme_token_style(menu.baked_theme,"muted")
        ansi=style.fg isa Tachikoma.NoColor ? "\e[39m" : sprint(io->Tachikoma.write_fg(io,style.fg))
        label*=ansi*(style.dim ? "\e[2m" : "")*"["*item.provider*"]"*(style.dim ? "\e[22;39m" : "\e[39m")
    end
    label
end

"""Filter each typed packet with stable original token scores and reset selection even when text is unchanged."""
function thinking_defaults_filter!(menu::ThinkingDefaultsMenu)
    tokens=split(strip(menu_search_text(menu.search)),r"[\s/]+";keepempty=false)
    scores=[(index,sum(token->thinking_token_score(thinking_defaults_label(menu,item)*" "*item.description,token),tokens;init=0.0)) for (index,item) in enumerate(menu.items)]
    sort!(filter!(pair->isfinite(last(pair)),scores);by=last,alg=Base.Sort.MergeSort)
    menu.filtered=first.(scores)
    menu.cursor=1
    nothing
end

"""Complete only after the owner confirms a real default-only write; failures retain the current step."""
function thinking_defaults_activate!(menu::ThinkingDefaultsMenu)
    result=nothing
    if 1<=menu.cursor<=length(menu.filtered)
        item=menu.items[menu.filtered[menu.cursor]]
        if menu.step==:model
            menu.context["model"]=item.value
            thinking_defaults_step!(menu,:level)
        else
            key=get(menu.context,"model","")
            index=findfirst(model->thinking_defaults_key(model)==key,menu.models)
            if !isnothing(index)
                model=menu.models[index]
                menu.context["level"]=item.value
                remove=item.value=="__clear__"
                outcome=remove ? menu.on_remove(model.provider,model.id) : menu.on_set(model.provider,model.id,item.value)
                result=(kind=remove ? :remove : :set,provider=model.provider,id=model.id,level=item.value,outcome)
                if hasproperty(outcome,:ok) && outcome.ok===true
                    if remove
                        delete!(menu.overrides,key)
                    else
                        menu.overrides[key]=item.value
                    end
                    empty!(menu.context)
                    menu.last_error=""
                    thinking_defaults_step!(menu,:model)
                else
                    menu.last_error=hasproperty(outcome,:reason) ? String(outcome.reason) : hasproperty(outcome,:text) ? String(outcome.text) : "Owner did not confirm saving the default"
                end
            end
        end
    end
    result
end

"""Handle real two-step navigation, search and looping without treating cancel as a default change."""
function thinking_defaults_input!(menu::ThinkingDefaultsMenu,data::AbstractString)
    result=nothing
    if menu.open
        count=length(menu.filtered)
        if data in ("\e[A","\eOA")
            menu.cursor=menu.cursor==1 ? count : menu.cursor-1
        elseif data in ("\e[B","\eOB")
            menu.cursor=menu.cursor==count ? 1 : menu.cursor+1
        elseif data in ("\e[5~","\e[6~") && count>0
            menu.cursor=clamp(menu.cursor+(data=="\e[5~" ? -1 : 1)*min(count,10),1,count)
        elseif data=="\r"
            result=thinking_defaults_activate!(menu)
        elseif data in ("\e","\x03")
            if menu.step==:level
                delete!(menu.context,"level")
                thinking_defaults_step!(menu,:model)
            else
                menu.summary=thinking_defaults_summary(menu)
                menu.open=false
                result=menu.on_cancel(menu.summary)
            end
        elseif menu.step==:model
            menu_search_input!(menu.search,data)
            thinking_defaults_filter!(menu)
        end
    end
    result
end

"""The original stepped component exposes no mouse children; keep mouse fallback unhandled."""
thinking_defaults_mouse!(menu::ThinkingDefaultsMenu,x::Int,y::Int;kwargs...) = nothing
