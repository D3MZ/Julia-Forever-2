# Pure native footer projection. Inputs are factual service snapshots, never inferred model/auth state.
public FooterModel, FooterContext, FooterUsage, FooterUsageEvent, FooterAccounting, FooterSnapshot
public footer_native_totals, footer_native_tokens, footer_native_cwd, footer_native_lines, footer_native_draw!

Base.@kwdef struct FooterModel
    id::String
    provider::String=""
    reasoning::Bool=false
    context_window::Union{Nothing,Float64}=nothing
end
Base.@kwdef struct FooterContext
    percent::Union{Missing,Nothing,Float64}=missing
    window::Union{Nothing,Float64}=nothing
end
Base.@kwdef struct FooterUsage
    input::Float64=0.0
    output::Float64=0.0
    cache_read::Float64=0.0
    cache_write::Float64=0.0
    cost::Float64=0.0
end
Base.@kwdef struct FooterUsageEvent
    kind::Symbol
    role::Union{Nothing,Symbol}=nothing
    usage::Union{Nothing,FooterUsage}=nothing
end
Base.@kwdef struct FooterAccounting
    usage::FooterUsage=FooterUsage()
    cache_rate::Union{Nothing,Float64}=nothing
end
Base.@kwdef struct FooterSnapshot
    cwd::String
    home::Union{Nothing,String}=nothing
    branch::Union{Nothing,String}=nothing
    name::Union{Nothing,String}=nothing
    model::Union{Nothing,FooterModel}=nothing
    thinking::Union{Nothing,String}=nothing
    routed::Union{Nothing,FooterModel}=nothing
    routed_thinking::Union{Nothing,String}=nothing
    context::Union{Nothing,FooterContext}=nothing
    events::Vector{FooterUsageEvent}=FooterUsageEvent[]
    accounting::Union{Nothing,FooterAccounting}=nothing
    subscription::Bool=false
    available_providers::Int=1
    auto_compact::Bool=true
    experimental::Bool=false
    statuses::Vector{Pair{String,String}}=Pair{String,String}[]
end

"""Keep all recognized usage events, and derive prompt cache rate only from the latest assistant."""
function footer_native_totals(events::AbstractVector{FooterUsageEvent})
    input=output=cache_read=cache_write=cost=0.0
    cache_rate=nothing
    for event in events
        usage=event.usage
        accepted=event.kind in (:usage,:branch_summary,:compaction) || (event.kind==:message && event.role in (:assistant,:toolResult))
        if accepted && !isnothing(usage)
            input+=usage.input
            output+=usage.output
            cache_read+=usage.cache_read
            cache_write+=usage.cache_write
            cost+=usage.cost
            if event.kind==:message && event.role==:assistant
                prompt=usage.input+usage.cache_read+usage.cache_write
                cache_rate=prompt>0 ? usage.cache_read/prompt*100 : nothing
            end
        end
    end
    FooterAccounting(;usage=FooterUsage(;input,output,cache_read,cache_write,cost),cache_rate)
end

"""Round the exact binary floating-point value to fixed decimal digits, with ties away from zero."""
function footer_native_fixed(value::Real,digits::Int)
    number=Float64(value)
    if isfinite(number)
        exact=Rational{BigInt}(abs(number))
        scale=big(10)^digits
        whole,remainder=divrem(numerator(exact)*scale,denominator(exact))
        whole+=2remainder>=denominator(exact)
        integer,fraction=divrem(whole,scale)
        sign=number<0 ? "-" : ""
        digits==0 ? sign*string(integer) : sign*string(integer)*"."*lpad(string(fraction),digits,'0')
    else
        isnan(number) ? "NaN" : number<0 ? "-Infinity" : "Infinity"
    end
end
footer_native_number(value::Real)=isinteger(value) && abs(value)<1e21 ? string(BigInt(value)) : string(Float64(value))

"""Match compact token thresholds after binary division, including 2550→2.5k."""
function footer_native_tokens(value::Real)
    count=Float64(value)
    if count<1000
        footer_native_number(count)
    elseif count<10000
        footer_native_fixed(count/1000,1)*"k"
    elseif count<1000000
        footer_native_number(floor(count/1000+0.5))*"k"
    elseif count<10000000
        footer_native_fixed(count/1000000,1)*"M"
    else
        footer_native_number(floor(count/1000000+0.5))*"M"
    end
end

footer_native_cwd(cwd::AbstractString,::Nothing)=String(cwd)
function footer_native_cwd(cwd::AbstractString,home::AbstractString)
    result=String(cwd)
    if !isempty(home)
        relative=relpath(abspath(cwd),abspath(home))
        inside=relative=="." || (relative!=".." && !startswith(relative,".."*string(Base.Filesystem.path_separator)) && !isabspath(relative))
        if inside
            result=relative=="." ? "~" : "~"*string(Base.Filesystem.path_separator)*relative
        end
    end
    result
end

function footer_native_style(token::Symbol)
    color=token==:error ? (234,127,129) : token==:warning ? (205,154,34) : token==:success ? (104,183,141) : (126,136,142)
    Tachikoma.Style(;fg=Tachikoma.ColorRGB(color...))
end

"""Apply a palette foreground without rewriting nested style boundaries."""
function footer_native_fg(style,token::Symbol,text::AbstractString)
    selected=style(token)
    prefix=selected.fg isa Tachikoma.NoColor ? "\e[39m" : sprint(io->Tachikoma.write_fg(io,selected.fg))
    selected.dim ? prefix*"\e[2m"*text*"\e[22;39m" : prefix*text*"\e[39m"
end

"""Column-clip native terminal text, retaining complete graphemes and explicit reset boundaries."""
function footer_native_clip(text::AbstractString,width::Int,marker::AbstractString="...")
    if width<=0
        ""
    elseif menu_search_width(text)<=width
        String(text)
    else
        suffix=menu_search_width(marker)>=width ? menu_search_slice(marker,0,width) : String(marker)
        available=max(0,width-menu_search_width(suffix))
        menu_search_slice(text,0,available)*"\e[0m"*suffix*"\e[0m"
    end
end

footer_native_window(::Nothing)=0.0
footer_native_window(model::FooterModel)=something(model.context_window,0.0)
footer_native_percent(::Nothing)=0.0
footer_native_percent(context::FooterContext)=ismissing(context.percent) ? 0.0 : context.percent
footer_native_window(context::Nothing,model)=footer_native_window(model)
footer_native_window(context::FooterContext,model)=something(context.window,footer_native_window(model))
footer_native_subscribed(snapshot::FooterSnapshot,::Nothing)=false
footer_native_subscribed(snapshot::FooterSnapshot,model::FooterModel)=model.provider=="kimi-coding" || snapshot.subscription

function footer_native_right(snapshot::FooterSnapshot)
    model=snapshot.model
    name=isnothing(model) || isempty(model.id) ? "no-model" : model.id
    if !isnothing(model) && model.reasoning
        level=isnothing(snapshot.thinking) || isempty(snapshot.thinking) ? "off" : snapshot.thinking
        name*=" • "*(level=="off" ? "thinking off" : level)
    end
    routed=snapshot.routed
    if !isnothing(routed)
        level=snapshot.routed_thinking
        name*=" → "*routed.id*(isnothing(level) || isempty(level) ? "" : " • "*level)
    end
    name
end

"""Order common status keys by English primary/secondary/case weights; callers may supply locale collation."""
function footer_native_status_key(value::AbstractString)
    decomposed=Base.Unicode.normalize(value;decompose=true,compat=false)
    primary=lowercase(Base.Unicode.normalize(value;stripmark=true))
    weights=[character=='_' ? 1 : character=='-' ? 2 : Int(character)+10 for character in primary]
    accents=[Int(character) for character in decomposed if occursin(r"^\p{M}$",string(character))]
    cases=[isuppercase(character) ? 1 : 0 for character in value]
    (weights,accents,cases)
end
footer_native_space(character::Char)=character in ('\t','\n','\v','\f','\r',' ','\u00a0','\u1680','\u2028','\u2029','\u202f','\u205f','\u3000','\ufeff') || 0x2000<=Int(character)<=0x200a
footer_native_sanitize(text::AbstractString)=String(strip(footer_native_space,replace(replace(text,r"[\r\n\t]"=>" "),r" +"=>" ")))

"""Render factual snapshot values with left-first allocation and an optional third status row."""
function footer_native_ansi(snapshot::FooterSnapshot,width::Integer;style=footer_native_style,bold::Bool=false,status_key=footer_native_status_key)
    columns=Int(width)
    totals=isnothing(snapshot.accounting) ? footer_native_totals(snapshot.events) : snapshot.accounting
    usage=totals.usage
    parts=String[]
    for (prefix,value) in (("↑",usage.input),("↓",usage.output),("R",usage.cache_read),("W",usage.cache_write))
        value!=0 && !isnan(value) && push!(parts,prefix*footer_native_tokens(value))
    end
    if (usage.cache_read>0 || usage.cache_write>0) && !isnothing(totals.cache_rate)
        push!(parts,"CH"*footer_native_fixed(totals.cache_rate,1)*"%")
    end
    subscription=footer_native_subscribed(snapshot,snapshot.model)
    if usage.cost!=0 && !isnan(usage.cost) || subscription
        push!(parts,"\$"*footer_native_fixed(usage.cost,3)*(subscription ? " (sub)" : ""))
    end
    percent=footer_native_percent(snapshot.context)
    display=isnothing(percent) ? "?" : footer_native_fixed(percent,1)*"%"
    display*="/"*footer_native_tokens(footer_native_window(snapshot.context,snapshot.model))*(snapshot.auto_compact ? " (auto)" : "")
    if !isnothing(percent) && percent>70
        display=footer_native_fg(style,percent>90 ? :error : :warning,display)
    end
    push!(parts,display)
    if snapshot.experimental
        badge=footer_native_fg(style,:warning,"xp")
        push!(parts,footer_native_fg(style,:dim,"•")*" "*(bold ? "\e[1m"*badge*"\e[22m" : badge))
    end
    left=footer_native_clip(join(parts," "),columns)
    left_width=menu_search_width(left)
    right=footer_native_right(snapshot)
    model=snapshot.model
    if snapshot.available_providers>1 && !isnothing(model)
        qualified="($(model.provider)) "*right
        if left_width+2+menu_search_width(qualified)<=columns
            right=qualified
        end
    end
    available=columns-left_width-2
    remainder=""
    if available>0
        right=footer_native_clip(right,available,"")
        remainder=repeat(" ",max(0,columns-left_width-menu_search_width(right)))*right
    elseif left_width+2+menu_search_width(right)<=columns
        remainder=repeat(" ",max(0,columns-left_width-menu_search_width(right)))*right
    end
    pwd=footer_native_cwd(snapshot.cwd,snapshot.home)
    if !isnothing(snapshot.branch) && !isempty(snapshot.branch)
        pwd*=" ($(snapshot.branch))"
    end
    if !isnothing(snapshot.name) && !isempty(snapshot.name)
        pwd*=" • "*snapshot.name
    end
    marker=footer_native_fg(style,:dim,"...")
    lines=[footer_native_clip(footer_native_fg(style,:dim,pwd),columns,marker),
        footer_native_fg(style,:dim,left)*footer_native_fg(style,:dim,remainder)]
    if !isempty(snapshot.statuses)
        ordered=sort(snapshot.statuses;by=pair->status_key(first(pair)),alg=Base.Sort.MergeSort)
        push!(lines,footer_native_clip(join((footer_native_sanitize(last(pair)) for pair in ordered)," "),columns,marker))
    end
    lines
end
footer_native_lines(snapshot::FooterSnapshot,width::Integer;kwargs...)=Tachikoma.parse_ansi.(footer_native_ansi(snapshot,width;kwargs...))

"""Draw palette-resolved native spans using grapheme widths rather than codepoint sums."""
function footer_native_draw!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,snapshot::FooterSnapshot;kwargs...)
    lines=footer_native_lines(snapshot,width;kwargs...)
    for (row,spans) in enumerate(lines)
        column,previous=x,x-1
        for span in spans
            for grapheme in Base.Unicode.graphemes(span.content)
                glyph=String(grapheme)
                count=menu_search_grapheme_width(glyph)
                if count==0 && previous>=x && Tachikoma.in_bounds(buffer,previous,y+row-1)
                    cell=buffer.content[Tachikoma.buf_index(buffer,previous,y+row-1)]
                    if !all(iscntrl,glyph)
                        Tachikoma.set!(buffer,previous,y+row-1,Tachikoma.Cell(cell.char,cell.style,cell.suffix*glyph))
                    end
                elseif count>0 && column+count<=x+width
                    characters=collect(glyph)
                    Tachikoma.set!(buffer,column,y+row-1,Tachikoma.Cell(first(characters),span.style,join(characters[2:end])))
                    for offset in 1:count-1
                        Tachikoma.set!(buffer,column+offset,y+row-1,Tachikoma.Cell('\0',span.style))
                    end
                    previous=column
                    column+=count
                end
            end
        end
    end
    nothing
end
