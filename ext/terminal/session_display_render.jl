using Printf

"""Independent transcript view controls; none of these mutate model context or archived payloads."""
Base.@kwdef mutable struct SessionDisplayState
    expanded::Set{String} = Set{String}()
    collapsed::Set{String} = Set{String}()
    expand_all::Bool = false
    hide_thinking::Bool = false
    hidden_thinking_label::String = "Thinking..."
    show_usage::Bool = false
    output_padding::Int = 1
    retry_attempt::Int = 0
end

const SessionDisplayRows = Vector{Vector{Tachikoma.Span}}

"""Opt into actual transcript row offsets without changing legacy two-argument extras callbacks."""
struct SessionAfterRecordLayout{F}
    render::F
end
session_after_record_rows(render,anchor,width::Int,offset::Int)=render(anchor,width)
session_after_record_rows(render::SessionAfterRecordLayout,anchor,width::Int,offset::Int)=render.render(anchor,width,offset)

"""Apply an explicit display transition without invoking tools, models or archive writes."""
function session_display_transition!(state::SessionDisplayState, action::Symbol, identity::AbstractString="")
    id = String(identity)
    if action == :expand
        push!(state.expanded, id)
        delete!(state.collapsed, id)
    elseif action == :collapse
        delete!(state.expanded, id)
        push!(state.collapsed, id)
    elseif action == :toggle
        session_display_transition!(state,session_display_expanded(state,id) ? :collapse : :expand,id)
    elseif action == :expand_all
        state.expand_all = true
        empty!(state.expanded)
        empty!(state.collapsed)
    elseif action == :collapse_all
        state.expand_all = false
        empty!(state.expanded)
        empty!(state.collapsed)
    elseif action == :hide_thinking
        state.hide_thinking = true
    elseif action == :show_thinking
        state.hide_thinking = false
    else
        error("Unknown session display transition: $(action)")
    end
    state
end

function session_display_style(kind::Symbol; bg=Tachikoma.NoColor(), bold=false, italic=false)
    runtime = isdefined(@__MODULE__, :ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    if !isnothing(runtime)
        tokens = (thinking="thinkingText", bash="bashMode", heading="mdHeading", link="mdLink", linkurl="mdLinkUrl", code="mdCode", codeblock="mdCodeBlock", user="userMessageText", tool="toolOutput")
        style = theme_token_style(runtime, haskey(tokens, kind) ? tokens[kind] : String(kind); bold, italic)
        Tachikoma.Style(; fg=style.fg, bg, bold, italic, dim=style.dim)
    else
        colors = (text=(222,224,225), muted=(157,165,169), dim=(126,136,142), accent=(167,152,215),
            thinking=(150,160,164), error=(234,127,129), warning=(205,154,34), bash=(94,178,134),
            heading=(205,154,34), link=(105,173,208), linkurl=(157,165,169), code=(167,152,215), codeblock=(104,183,141), user=(222,224,225), tool=(222,224,225))
        fg = haskey(colors, kind) ? Tachikoma.ColorRGB(colors[kind]...) : Tachikoma.NoColor()
        Tachikoma.Style(; fg, bg, bold, italic)
    end
end
function session_display_bg(kind::Symbol)
    runtime = isdefined(@__MODULE__, :ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    if !isnothing(runtime)
        token = kind == :user ? "userMessageBg" : kind == :custom ? "customMessageBg" : kind == :success ? "toolSuccessBg" : kind == :error ? "toolErrorBg" : "toolPendingBg"
        theme_token_style(runtime, token).bg
    else
        Tachikoma.ColorRGB((kind == :user ? (33,59,73) : kind == :custom ? (58,48,85) :
            kind == :success ? (37,65,49) : kind == :error ? (91,40,42) : (55,57,59))...)
    end
end

"""Replace terminal controls in untrusted content instead of interpreting embedded escape programs."""
function session_display_safe(text::AbstractString)
    clean = replace(String(text), r"\e\][^\a]*(?:\a|\e\\)" => "", r"\e\[[0-?]*[ -/]*[@-~]" => "", "\r\n" => "\n", '\r' => '\n', '\t' => "   ")
    join(char == '\n' || !iscntrl(char) ? string(char) : "�" for char in clean)
end
session_display_blank(width, bg=Tachikoma.NoColor()) = [Tachikoma.Span(repeat(" ", width), Tachikoma.Style(;bg))]

"""Identify the script-extension boundaries used by the reference Unicode word wrapper."""
session_display_cjk(text::AbstractString)=!isascii(text)&&occursin(r"[\p{scx:Han}\p{scx:Hiragana}\p{scx:Katakana}\p{scx:Hangul}\p{scx:Bopomofo}]",text)

"""Wrap styled content and fill a full terminal row with deliberate background and padding."""
function session_display_wrap(spans::Vector{Tachikoma.Span}, width::Int, padding::Int; bg=Tachikoma.NoColor(),preserve_background=false,preserve_gap_style=false,boundary_styles=false)
    padding = min(padding, max(0, fld(width - 1, 2)))
    capacity = max(1, width - 2padding)
    source = [(String(grapheme),span.style,index) for (index,span) in enumerate(spans) for grapheme in Base.Unicode.graphemes(span.content)]
    ranges = UnitRange{Int}[]
    start = 1
    while start <= length(source)
        stop, used = start - 1, 0
        while stop < length(source) && used + menu_search_grapheme_width(source[stop+1][1]) <= capacity
            stop += 1
            used += menu_search_grapheme_width(source[stop][1])
        end
        stop = max(start, stop)
        endpoint = stop
        if stop < length(source) && !all(isspace, source[stop][1]) && !all(isspace, source[stop+1][1])
            lastspace = findlast(index -> all(isspace,source[index][1]) || session_display_cjk(source[index][1]) || index<length(source) && session_display_cjk(source[index+1][1]), start:stop)
            if !isnothing(lastspace) && lastspace > 1
                boundary = start + lastspace - 1
                endpoint = all(isspace,source[boundary][1]) ? boundary-1 : boundary
            end
        end
        if endpoint < length(source)
            while endpoint > start && all(isspace,source[endpoint][1])
                endpoint -= 1
            end
        end
        push!(ranges,start:endpoint)
        start = endpoint + 1
        while start <= length(source) && all(isspace,source[start][1])
            start += 1
        end
    end
    isempty(ranges) && push!(ranges,1:0)
    rows = SessionDisplayRows()
    leading = Tachikoma.Style(;bg)
    for (index,range) in enumerate(ranges)
        row = Tachikoma.Span[Tachikoma.Span(repeat(" ", padding),leading)]
        used = 0
        for position in range
            grapheme,old,_ = source[position]
            style = Tachikoma.Style(;fg=old.fg,bg=preserve_background && !(old.bg isa Tachikoma.NoColor) ? old.bg : bg,bold=old.bold,dim=old.dim,italic=old.italic,
                underline=old.underline,strikethrough=old.strikethrough,hyperlink=old.hyperlink)
            push!(row,Tachikoma.Span(grapheme,style))
            used += menu_search_grapheme_width(grapheme)
        end
        trailing = Tachikoma.Style(;bg)
        if index < length(ranges) && !isempty(range) && (source[max(last(range),first(ranges[index+1])-1)][3] == source[first(ranges[index+1])][3] || preserve_gap_style && first(ranges[index+1])>last(range)+1)
            old = source[max(last(range),first(ranges[index+1])-1)][2]
            trailing = Tachikoma.Style(;fg=old.fg,bg,bold=old.bold,dim=old.dim,italic=old.italic,
                underline=old.underline,strikethrough=old.strikethrough)
        end
        if boundary_styles && index==length(ranges) && !isempty(spans) && isempty(last(spans).content)
            old=last(spans).style
            trailing=Tachikoma.Style(;fg=old.fg,bg,bold=old.bold,dim=old.dim,italic=old.italic,underline=old.underline,strikethrough=old.strikethrough)
        end
        if index<length(ranges)
            old=trailing
            trailing=Tachikoma.Style(;fg=old.fg,bg=old.bg,bold=old.bold,dim=old.dim,italic=old.italic,underline=false,strikethrough=false)
        end
        push!(row,Tachikoma.Span(repeat(" ",max(0,width-padding-used)),trailing))
        leading = Tachikoma.Style(;bg)
        push!(rows,row)
    end
    rows
end

function session_display_text_rows(text::AbstractString,width::Int,padding::Int;style=Tachikoma.Style(),bg=Tachikoma.NoColor())
    rows=SessionDisplayRows()
    for line in split(session_display_safe(text),'\n';keepempty=true)
        append!(rows,session_display_wrap([Tachikoma.Span(String(line),style)],width,padding;bg))
    end
    rows
end

function session_display_markdown(text::AbstractString,width::Int,padding::Int;kind::Symbol=:default,bg=Tachikoma.NoColor(),italic=false,render_math::Bool=true)
    lines=session_markdown_spans(text,max(1,width-2padding);kind,italic,render_math)
    rows=SessionDisplayRows()
    for line in lines
        append!(rows,session_display_wrap(line,width,padding;bg,boundary_styles=true))
    end
    rows
end

session_display_string(value::AbstractString)::String = String(value)
session_display_string(value)::String = error("Expected text in a typed display record")
session_display_block_kind(block::AbstractDict)::String = get(block,"type",nothing) isa AbstractString ? String(block["type"]) : "invalid"

session_display_expanded(state::SessionDisplayState,id) = !(id in state.collapsed) && (state.expand_all || id in state.expanded)
session_display_content(content::AbstractString) = [Dict("type"=>"text","text"=>String(content))]
function session_display_block(block::AbstractDict)
    kind=session_display_block_kind(block)
    valid=kind isa AbstractString && (kind!="text" || get(block,"text",nothing) isa AbstractString) &&
        (kind!="thinking" || get(block,"thinking",nothing) isa AbstractString)
    valid ? block : Dict("type"=>"invalid","original"=>block)
end
session_display_block(block) = Dict("type"=>"invalid","original"=>block)
session_display_content(content::AbstractVector) = session_display_block.(content)
session_display_content(content) = [Dict("type"=>"invalid","value"=>content)]

"""Show absent rendering support explicitly while the typed source record remains available."""
function session_display_unsupported(block,width,padding;bg=Tachikoma.NoColor())
    kind=get(block,"type","unknown")
    detail=kind=="image" ? ": " * session_display_string(get(block,"mimeType","image/unknown")) : ""
    session_display_text_rows("[Unsupported $(kind) display$(detail); original data retained]",width,padding;
        style=session_display_style(:error),bg)
end

function session_display_user(message::AbstractDict,width::Int,state::SessionDisplayState)
    bg=session_display_bg(:user)
    rows=SessionDisplayRows([session_display_blank(width,bg)])
    blocks=session_display_content(get(message,"content",nothing))
    text=join(session_display_string(get(block,"text","")) for block in blocks if session_display_block_kind(block)=="text")
    isempty(text) || append!(rows,session_display_markdown(text,width,state.output_padding;kind=:user,bg))
    for block in blocks
        session_display_block_kind(block) in ("text","image") || append!(rows,session_display_unsupported(block,width,state.output_padding;bg))
    end
    push!(rows,session_display_blank(width,bg))
    rows
end

function session_display_assistant(message::AbstractDict,width::Int,state::SessionDisplayState)
    rows=SessionDisplayRows()
    spacer=true
    blocks=session_display_content(get(message,"content",nothing))
    index=1
    while index<=length(blocks)
        block=blocks[index]
        kind=session_display_block_kind(block)
        if kind=="text"
            text=strip(session_display_string(get(block,"text","")))
            if !isempty(text)
                spacer && push!(rows,session_display_blank(width))
                append!(rows,session_display_markdown(text,width,state.output_padding))
                spacer=false
            end
        elseif kind=="thinking"
            thoughts=String[]
            while index<=length(blocks) && session_display_block_kind(blocks[index])=="thinking"
                thought=strip(session_display_string(get(blocks[index],"thinking","")))
                isempty(thought) || push!(thoughts,thought)
                index+=1
            end
            index-=1
            text=state.hide_thinking ? state.hidden_thinking_label : join(thoughts,"\n\n")
            if !isempty(thoughts) && !isempty(strip(text))
                spacer && push!(rows,session_display_blank(width))
                append!(rows,session_display_markdown(text,width,state.output_padding;kind=:thinking,italic=true))
                spacer=true
            end
        elseif !(kind in ("toolCall","image"))
            spacer && push!(rows,session_display_blank(width))
            append!(rows,session_display_unsupported(block,width,state.output_padding))
            spacer=true
        end
        index+=1
    end
    stop=get(message,"stopReason",nothing)
    tools=any(block->session_display_block_kind(block)=="toolCall",blocks)
    failure=stop=="length" ? "Response was truncated before completion." : !tools && stop=="error" ? "Error: " * session_display_string(get(message,"errorMessage","Unknown error")) :
        !tools && stop=="aborted" ? (get(message,"errorMessage","") in ("","Request was aborted") ? "Operation aborted" : session_display_string(message["errorMessage"])) : ""
    if !isempty(failure)
        push!(rows,session_display_blank(width))
        append!(rows,session_display_text_rows(failure,width,state.output_padding;style=session_display_style(:error)))
    end
    rows
end

function session_display_box(label::AbstractString,body::SessionDisplayRows,width::Int,state::SessionDisplayState)
    bg=session_display_bg(:custom)
    rows=SessionDisplayRows([session_display_blank(width),session_display_blank(width,bg)])
    append!(rows,session_display_text_rows(label,width,state.output_padding;style=session_display_style(:accent;bold=true),bg))
    push!(rows,session_display_blank(width,bg))
    append!(rows,body)
    push!(rows,session_display_blank(width,bg))
    rows
end

function session_display_summary(message::AbstractDict,id::AbstractString,width::Int,state::SessionDisplayState)
    bg=session_display_bg(:custom)
    compact=message["role"]=="compactionSummary"
    tokens=replace(string(get(message,"tokensBefore",0)),r"\B(?=(\d{3})+(?!\d))"=>",")
    title=compact ? "Compacted from $(tokens) tokens" : "Branch Summary"
    body=SessionDisplayRows()
    if session_display_expanded(state,id)
        append!(body,session_display_text_rows(title,width,state.output_padding;style=session_display_style(:muted;bold=true),bg))
        push!(body,session_display_blank(width,bg))
        isempty(message["summary"]) || append!(body,session_display_markdown(session_display_string(message["summary"]),width,state.output_padding;kind=:muted,bg))
    else
        label=compact ? title : "Branch summary"
        spans=[Tachikoma.Span(label*" (",session_display_style(:muted)),Tachikoma.Span("ctrl+o",session_display_style(:dim)),Tachikoma.Span(" to expand)",session_display_style(:muted))]
        append!(body,session_display_wrap(spans,width,state.output_padding;bg))
    end
    session_display_box(compact ? "[compaction]" : "[branch]",body,width,state)
end

function session_display_custom(message::AbstractDict,width::Int,state::SessionDisplayState)
    bg=session_display_bg(:custom)
    blocks=session_display_content(get(message,"content",nothing))
    text=join([session_display_string(get(block,"text","")) for block in blocks if session_display_block_kind(block)=="text"],"\n")
    body=session_display_markdown(text,width,state.output_padding;kind=:muted,bg)
    for block in blocks
        session_display_block_kind(block)=="text" || append!(body,session_display_unsupported(block,width,state.output_padding;bg))
    end
    session_display_box("["*session_display_string(message["customType"])*"]",body,width,state)
end

function session_display_bash(message::AbstractDict,id::AbstractString,width::Int,state::SessionDisplayState;running::Bool=false,frame::Int=1)
    color=get(message,"excludeFromContext",false) === true ? :dim : :bash
    rows=SessionDisplayRows([session_display_blank(width)])
    border=[Tachikoma.Span(repeat("─",width),session_display_style(color))]
    push!(rows,border)
    append!(rows,session_display_text_rows("\$ "*session_display_string(message["command"]),width,state.output_padding;style=session_display_style(color;bold=true)))
    limited=JuliaForever2.UserShellOutput.truncate_tail(session_display_safe(session_display_string(message["output"])))
    output=limited.content
    expanded=session_display_expanded(state,id)
    logical=isempty(output) ? SubString{String}[] : split(output,'\n';keepempty=true)
    hidden=max(0,length(logical)-20)
    selected=expanded ? logical : logical[max(1,length(logical)-19):end]
    if !isempty(selected)
        preview=session_display_text_rows("\n"*join(selected,"\n"),width,state.output_padding;style=session_display_style(:muted))
        append!(rows,expanded ? preview : preview[max(1,length(preview)-19):end])
    end
    statuses=Vector{Tachikoma.Span}[]
    if !running && hidden>0
        label=expanded ? "(" : "... $(hidden) more lines ("
        verb=expanded ? "to collapse" : "to expand"
        push!(statuses,[Tachikoma.Span(label,session_display_style(:muted)),Tachikoma.Span("ctrl+o",session_display_style(:dim)),Tachikoma.Span(" "*verb*")",session_display_style(:muted))])
    end
    if !running && get(message,"cancelled",false) === true
        push!(statuses,[Tachikoma.Span("(cancelled)",session_display_style(:warning))])
    elseif !running && !isnothing(get(message,"exitCode",nothing)) && message["exitCode"]!=0
        push!(statuses,[Tachikoma.Span("(exit $(message["exitCode"]))",session_display_style(:error))])
    end
    path=get(message,"fullOutputPath",nothing)
    if !running && (get(message,"truncated",false) === true || limited.truncated) && path isa AbstractString && !isempty(path)
        push!(statuses,[Tachikoma.Span("Output truncated. Full output: "*path,session_display_style(:warning))])
    end
    if running
        push!(rows,session_display_blank(width))
        frames=("⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏")
        status=[Tachikoma.Span(frames[mod1(frame,10)],session_display_style(color)),Tachikoma.Span(" ",Tachikoma.Style()),Tachikoma.Span("Running... (escape/ctrl+c to cancel)",session_display_style(:muted))]
        append!(rows,session_display_wrap(status,width,1))
    elseif !isempty(statuses)
        push!(rows,session_display_blank(width))
        for status in statuses
            append!(rows,session_display_wrap(status,width,state.output_padding))
        end
    end
    push!(rows,copy(border))
    rows
end

function session_display_tool(tool::JuliaForever2.TimelineDisplayTool,width::Int,state::SessionDisplayState)
    result=tool.result
    bg=session_display_bg(isnothing(result) ? :pending : get(result,"isError",false) === true ? :error : :success)
    rows=SessionDisplayRows([session_display_blank(width),session_display_blank(width,bg)])
    append!(rows,session_display_text_rows(session_display_string(tool.call["name"]),width,state.output_padding;style=session_display_style(:text;bold=true),bg))
    push!(rows,session_display_blank(width,bg))
    args=get(tool.call,"arguments",nothing)
    append!(rows,session_display_text_rows(JSON.json(args;pretty=2),width,state.output_padding;bg))
    if !isnothing(result)
        blocks=session_display_content(get(result,"content",Any[]))
        for block in blocks
            if session_display_block_kind(block)=="text"
                append!(rows,session_display_text_rows(session_display_string(get(block,"text","")),width,state.output_padding;bg))
            else
                append!(rows,session_display_unsupported(block,width,state.output_padding;bg))
            end
        end
    end
    push!(rows,session_display_blank(width,bg))
    rows
end

function session_display_usage(item::JuliaForever2.TimelineDisplayItem,width::Int,state::SessionDisplayState)
    usage=get(item.payload,"usage",nothing)
    rows=SessionDisplayRows([session_display_blank(width)])
    if usage isa AbstractDict
        cost=get(usage,"cost",nothing)
        total=cost isa AbstractDict ? get(cost,"total",nothing) : cost
        if item.kind==:usage
            label=total isa Real ? "Cache warmed: \$"*Printf.@sprintf("%.3f",total) : "Cache warmed: cost unavailable"
            append!(rows,session_display_text_rows(label,width,1;style=session_display_style(:dim)))
        else
            values=[get(usage,key,nothing) for key in ("input","output","cacheRead","cacheWrite")]
            tokens=all(value->value isa Int && value>=0,values) ? sum(Int[value for value in values]) : nothing
            label=get(item.payload,"kind",nothing)=="compaction" ? "Compaction" : "Branch summary"
            number::String=isnothing(tokens) ? "unknown" : string(tokens)
            price=total isa Real && total>=0.01 ? " (~\$"*Printf.@sprintf("%.2f",total)*")" : ""
            append!(rows,session_display_text_rows(label*": "*number*" tokens billed"*price,width,1;style=session_display_style(:warning)))
        end
    else
        append!(rows,session_display_text_rows("Usage unavailable",width,1;style=session_display_style(:error)))
    end
    rows
end

"""Render typed archival contributions without using their context-projected or edited replacements."""
function session_display_lines(projection::JuliaForever2.TimelineDisplayProjection,width::Int;
        state=SessionDisplayState(),custom_entry_renderer=nothing,tool_renderers=nothing,tool_layout=nothing,after_record=nothing,on_component=nothing)
    if width<1 || state.output_padding<0 || state.output_padding>3
        error("Invalid transcript width or padding")
    end
    view=JuliaForever2.timeline_display_records(projection;show_usage=state.show_usage,
        custom_entry_visible=entry->is_interrupted_response_entry(entry) || !isnothing(custom_entry_renderer),retry_attempt=state.retry_attempt)
    overlays=JuliaForever2.timeline_display_overlays(projection)
    rows=SessionDisplayRows()
    hascomponent=false
    if !isnothing(after_record)
        append!(rows,session_after_record_rows(after_record,nothing,width,length(rows)))
        hascomponent=!isempty(rows)
    end
    for (record_index,record) in enumerate(view.records)
        item=record.item
        message=deepcopy(item.payload)
        if haskey(overlays,item.source_entry_id) && item.kind==:message
            message["content"]=deepcopy(overlays[item.source_entry_id].content)
        end
        kind=record.presentation
        blocks=session_display_content(get(message,"content",Any[]))
        imageonly=kind==:user && blocks isa AbstractVector && any(block->!(session_display_block_kind(block) in ("text","image")),blocks)
        if record.visible || imageonly
            if kind==:user
                hascomponent && push!(rows,session_display_blank(width))
                rendered=session_display_user(message,width,state)
                isnothing(on_component) || on_component(kind,message,length(rows),length(rendered))
                append!(rows,rendered)
            elseif kind==:assistant
                rendered=session_display_assistant(message,width,state)
                isnothing(on_component) || on_component(kind,message,length(rows),length(rendered))
                append!(rows,rendered)
                for tool in view.tools
                    if tool.source_entry_id==item.source_entry_id
                        rendered = isnothing(tool_layout) ? session_display_tool(tool,width,state,tool_renderers) : tool_layout(tool,width,state,tool_renderers,length(rows))
                        rendered isa SessionDisplayRows || error("Tool layout must return native styled rows")
                        append!(rows,rendered)
                    end
                end
            elseif kind in (:native_code,:native_code_result)
                bg=session_display_bg(:success)
                push!(rows,session_display_blank(width,bg))
                for block in session_display_content(get(message,"content",nothing))
                    if session_display_block_kind(block)=="text"
                        append!(rows,session_display_text_rows(session_display_string(block["text"]),width,state.output_padding;style=session_display_style(:text),bg))
                    else
                        append!(rows,session_display_unsupported(block,width,state.output_padding;bg))
                    end
                end
                push!(rows,session_display_blank(width,bg))
            elseif kind in (:branchSummary,:compactionSummary)
                append!(rows,session_display_summary(message,item.source_entry_id,width,state))
            elseif kind==:custom && item.kind==:message
                append!(rows,session_display_custom(message,width,state))
            elseif kind==:bashExecution
                append!(rows,session_display_bash(message,item.source_entry_id,width,state))
            elseif kind in (:usage,:compaction_cost)
                append!(rows,session_display_usage(item,width,state))
            elseif item.kind==:custom && is_interrupted_response_entry(message)
                rendered=interrupted_response_rows(message,width,state)
                display=interrupted_display_message(message)
                if !isnothing(on_component) && !isnothing(display)
                    on_component(:assistant,display,length(rows),length(rendered))
                end
                append!(rows,rendered)
            elseif item.kind==:custom && !isnothing(custom_entry_renderer)
                rendered=custom_entry_renderer(deepcopy(item),width,state)
                if !(rendered isa SessionDisplayRows)
                    error("Custom entry renderer must return actual native styled rows")
                end
                push!(rows,session_display_blank(width))
                append!(rows,rendered)
            elseif kind!=:toolResult
                append!(rows,session_display_unsupported(Dict("type"=>String(kind)),width,state.output_padding))
            end
            kind==:toolResult || (hascomponent=true)
        end
        if !isnothing(after_record) && (record_index==length(view.records) || view.records[record_index+1].item.source_entry_id!=item.source_entry_id)
            extra=session_after_record_rows(after_record,item.source_entry_id,width,length(rows))
            append!(rows,extra)
            hascomponent=hascomponent||!isempty(extra)
        end
    end
    rows
end

"""Draw already padded full-width native transcript spans with no second padding or flattening."""
function draw_session_display_line!(buffer,x,y,width,row::Vector{Tachikoma.Span})
    column=x
    for span in row
        column=Tachikoma.set_string!(buffer,column,y,span.content,span.style;max_x=x+width-1)
    end
    nothing
end
