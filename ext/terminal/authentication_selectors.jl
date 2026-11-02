# Native authentication presentation; upstream Pi is an MIT, test-only behavior oracle.
public AuthProviderStatus, AuthProviderOption, AuthProviderMenu, AuthMethodOption, AuthMethodMenu
public auth_selector_input!, auth_selector_lines, auth_selector_dispose!, auth_selector_replace!

"""Describe an observed credential source, never an attempted or presumed sign-in."""
Base.@kwdef struct AuthProviderStatus
    kind::Symbol
    source::String = ""
end

"""A host-supplied, actually implemented authentication method and its observed credential state."""
Base.@kwdef struct AuthProviderOption
    id::String
    name::String
    kind::Symbol
    method_name::String = ""
    subscription::Bool = true
    status::Union{Nothing,AuthProviderStatus} = nothing
end

"""A supported method choice; identifiers are host-owned and labels are presentation only."""
Base.@kwdef struct AuthMethodOption
    id::String
    label::String
end

abstract type AuthenticationSelector end

Base.@kwdef mutable struct AuthProviderMenu{S,F,C} <: AuthenticationSelector
    options::Vector{AuthProviderOption}
    style::S
    on_select::F
    on_cancel::C
    mode::Symbol = :login
    bold::Bool = false
    search::MenuSearchInput = MenuSearchInput()
    filtered::Vector{AuthProviderOption} = AuthProviderOption[]
    cursor::Int = 1
    show_kinds::Bool = false
    disposed::Bool = false
    width::Int = 0
    height::Int = 0
end

Base.@kwdef mutable struct AuthMethodMenu{S,F,C,E} <: AuthenticationSelector
    title::String
    options::Vector{AuthMethodOption}
    style::S
    on_select::F
    on_cancel::C
    on_expand::E
    description::String = ""
    bold::Bool = false
    cursor::Int = 1
    disposed::Bool = false
    width::Int = 0
    height::Int = 0
end

"""Construct presentation only; the callbacks own authentication, errors, back navigation and persistence."""
function AuthProviderMenu(options::AbstractVector;style, on_select, on_cancel, mode::Symbol=:login,query="",bold::Bool=false)
    menu=AuthProviderMenu(;options=AuthProviderOption[options...],style,on_select,on_cancel,mode,bold)
    menu.show_kinds=length(Set(option.kind for option in menu.options))>1
    menu_search_set!(menu.search,query)
    auth_selector_filter!(menu)
    menu
end

function AuthMethodMenu(title::AbstractString,options::AbstractVector;style,on_select,on_cancel,
        description::AbstractString="",on_expand=Returns(nothing),bold::Bool=false)
    AuthMethodMenu(;title=String(title),options=AuthMethodOption[options...],style,on_select,on_cancel,
        description=String(description),on_expand,bold)
end

"""Search actual methods without changing provider availability or credential state."""
function auth_selector_filter!(menu::AuthProviderMenu)
    menu.filtered=isempty(menu.search.value) ? copy(menu.options) : selector_filter(menu.options,menu.search.value,
        option->join((option.name,option.id,String(option.kind),option.method_name)," "))
    menu.cursor=clamp(menu.cursor,1,max(1,length(menu.filtered)))
    nothing
end

"""Replace an observed catalog snapshot while preserving the user's clamped search selection."""
function auth_selector_replace!(menu::AuthProviderMenu,options::AbstractVector)
    if !menu.disposed
        menu.options=AuthProviderOption[options...]
        menu.show_kinds=length(Set(option.kind for option in menu.options))>1
        auth_selector_filter!(menu)
    end
    nothing
end

auth_selector_dispose!(menu::AuthenticationSelector)=(menu.disposed=true;nothing)

"""Dispatch a keyboard packet without submitting a grant or claiming the requested action succeeded."""
function auth_selector_input!(menu::AuthProviderMenu,packet::AbstractString)
    if !menu.disposed
        count=length(menu.filtered)
        if menu.search.pasting || occursin("\e[200~",packet)
            menu_search_input!(menu.search,packet)
            auth_selector_filter!(menu)
        elseif packet in ("\e[A","\e[B","\e[5~","\e[6~")
            delta=packet=="\e[A" ? -1 : packet=="\e[B" ? 1 : packet=="\e[5~" ? -8 : 8
            menu.cursor=clamp(menu.cursor+delta,1,max(1,count))
        elseif packet in ("\r","\n")
            if count>0
                menu.on_select(menu.filtered[menu.cursor])
            end
        elseif packet in ("\e","\x03")
            menu.on_cancel()
        else
            menu_search_input!(menu.search,packet)
            auth_selector_filter!(menu)
        end
    end
    nothing
end

function auth_selector_input!(menu::AuthMethodMenu,packet::AbstractString)
    if !menu.disposed
        if packet=="\x0f"
            menu.on_expand()
        elseif packet in ("\e[A","k")
            menu.cursor=max(1,menu.cursor-1)
        elseif packet in ("\e[B","j")
            menu.cursor=min(length(menu.options),menu.cursor+1)
        elseif packet in ("\r","\n")
            if 1<=menu.cursor<=length(menu.options)
                menu.on_select(menu.options[menu.cursor])
            end
        elseif packet in ("\e","\x03")
            menu.on_cancel()
        end
    end
    nothing
end

function auth_selector_span(menu::AuthenticationSelector,text::AbstractString,token::Symbol=:default;bold=false)
    base=menu.style(token)
    style=Tachikoma.Style(;fg=base.fg,bg=base.bg,bold=base.bold || bold,dim=base.dim,
        italic=base.italic,underline=base.underline,strikethrough=base.strikethrough,hyperlink=base.hyperlink)
    Tachikoma.Span(String(text),style)
end

auth_selector_kind(kind::Symbol,subscription::Bool)=kind==:api_key ? "API key" : kind==:provider_flow ? "provider flow" : subscription ? "subscription" : "account"

"""Render provenance of an observed credential, including the different-method warning."""
function auth_selector_status(menu::AuthProviderMenu,option::AuthProviderOption)
    auth_selector_status(menu,option,option.status)
end
auth_selector_status(menu::AuthProviderMenu,option::AuthProviderOption,::Nothing)=[auth_selector_span(menu," • not configured",:muted)]
function auth_selector_status(menu::AuthProviderMenu,option::AuthProviderOption,status::AuthProviderStatus)
    if status.kind!=option.kind
        [auth_selector_span(menu," • ",:muted),auth_selector_span(menu,auth_selector_kind(status.kind,option.subscription)*" configured",:warning)]
    elseif status.source in ("","OAuth","stored credential")
        [auth_selector_span(menu," ✓ configured",:success)]
    else
        source=occursin(r"^[A-Z][A-Z0-9_]*(?:, [A-Z][A-Z0-9_]*)*$",status.source) ? "env: "*status.source : status.source
        [auth_selector_span(menu," ✓ "*source,:success)]
    end
end

"""Truncate the first line of styled content and add the same terminal-default ellipsis and margin."""
function auth_selector_truncated(menu::AuthenticationSelector,spans::AbstractVector{Tachikoma.Span},width::Int)
    available=max(1,width-2)
    glyphs=Tuple{String,Tachikoma.Style}[]
    complete=false
    for span in spans
        for grapheme in Base.Unicode.graphemes(span.content)
            if grapheme=="\n"
                complete=true
            elseif !complete
                push!(glyphs,(String(grapheme),span.style))
            end
        end
    end
    total=sum(glyph->menu_search_width(first(glyph)),glyphs;init=0)
    clipped=total>available
    room=clipped ? max(0,available-3) : available
    used=0
    result=Tachikoma.Span[auth_selector_span(menu," ")]
    for (glyph,style) in glyphs
        columns=menu_search_width(glyph)
        if used+columns<=room
            push!(result,Tachikoma.Span(glyph,style))
            used+=columns
        else
            break
        end
    end
    if clipped
        marker=first("...",min(available,3))
        push!(result,auth_selector_span(menu,marker))
        used+=length(marker)
    end
    push!(result,auth_selector_span(menu,repeat(" ",max(1,width-used-1))))
    result
end

"""Render a native provider selector at the requested geometry without fabricated catalog entries."""
function auth_selector_lines(menu::AuthProviderMenu,width::Integer)
    columns=Int(width)
    lines=Vector{Tachikoma.Span}[]
    push!(lines,[auth_selector_span(menu,repeat("─",max(1,columns)),:menu_border)])
    push!(lines,Tachikoma.Span[])
    title=menu.mode==:login ? "Select provider to configure:" : "Select provider to logout:"
    push!(lines,auth_selector_truncated(menu,[auth_selector_span(menu,title,:accent;bold=menu.bold)],columns))
    push!(lines,Tachikoma.Span[])
    push!(lines,menu_search_spans(menu.search,columns))
    push!(lines,Tachikoma.Span[])
    count=length(menu.filtered)
    start=max(1,min(menu.cursor-4,count-7))
    stop=min(start+7,count)
    for index in start:stop
        option=menu.filtered[index]
        selected=index==menu.cursor
        row=[auth_selector_span(menu,selected ? "→ " : "  ",selected ? :accent : :default),
            auth_selector_span(menu,option.name,selected ? :accent : :text)]
        if menu.show_kinds
            push!(row,auth_selector_span(menu," ["*auth_selector_kind(option.kind,option.subscription)*"]",:muted))
        end
        append!(row,auth_selector_status(menu,option))
        push!(lines,auth_selector_truncated(menu,row,columns))
    end
    if start>1 || stop<count
        push!(lines,auth_selector_truncated(menu,[auth_selector_span(menu,"  ($(menu.cursor)/$count)",:muted)],columns))
    end
    if count==0
        message=isempty(menu.options) ? menu.mode==:login ? "No providers available" : "No providers logged in. Use /login first." : "No matching providers"
        push!(lines,auth_selector_truncated(menu,[auth_selector_span(menu,"  "*message,:muted)],columns))
    end
    push!(lines,Tachikoma.Span[])
    push!(lines,[auth_selector_span(menu,repeat("─",max(1,columns)),:menu_border)])
    menu.width=columns
    menu.height=length(lines)
    lines
end

"""Wrap method labels with a one-column margin, retaining native styled spans."""
function auth_selector_text(menu::AuthenticationSelector,spans,width::Int)
    margin=min(1,max(0,fld(width-1,2)))
    lines=Vector{Tachikoma.Span}[]
    leading=Tachikoma.Style()
    for row in model_menu_wrap(spans,max(1,width-2margin))
        trailing=isempty(row) ? Tachikoma.Style() : last(row).style
        push!(lines,Tachikoma.Span[Tachikoma.Span(repeat(" ",margin),leading);row;Tachikoma.Span(repeat(" ",margin),trailing)])
        leading=trailing
    end
    lines
end

function auth_selector_lines(menu::AuthMethodMenu,width::Integer)
    columns=Int(width)
    lines=Vector{Tachikoma.Span}[]
    push!(lines,[auth_selector_span(menu,repeat("─",max(1,columns)),:menu_border)])
    push!(lines,Tachikoma.Span[])
    append!(lines,auth_selector_text(menu,[auth_selector_span(menu,menu.title,:accent;bold=menu.bold)],columns))
    if !isempty(menu.description)
        push!(lines,Tachikoma.Span[])
        append!(lines,auth_selector_text(menu,[auth_selector_span(menu,menu.description,:text)],columns))
    end
    push!(lines,Tachikoma.Span[])
    for (index,option) in enumerate(menu.options)
        selected=index==menu.cursor
        row=[auth_selector_span(menu,selected ? "→ " : "  ",selected ? :accent : :default),
            auth_selector_span(menu,option.label,selected ? :accent : :text)]
        append!(lines,auth_selector_text(menu,row,columns))
    end
    push!(lines,Tachikoma.Span[])
    hints=[auth_selector_span(menu,"↑↓",:dim),auth_selector_span(menu," navigate",:muted),auth_selector_span(menu,"  "),
        auth_selector_span(menu,"enter",:dim),auth_selector_span(menu," select",:muted),auth_selector_span(menu,"  "),
        auth_selector_span(menu,"escape/ctrl+c",:dim),auth_selector_span(menu," cancel",:muted)]
    append!(lines,auth_selector_text(menu,hints,columns))
    push!(lines,Tachikoma.Span[])
    push!(lines,[auth_selector_span(menu,repeat("─",max(1,columns)),:menu_border)])
    menu.width=columns
    menu.height=length(lines)
    lines
end
