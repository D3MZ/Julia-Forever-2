"""Explicit display registry for built-in tool records; it never opens paths or executes archived calls."""
Base.@kwdef struct SessionBuiltinToolRenderers{F,S}
    cwd::String = pwd()
    home::String = homedir()
    docs_root::Union{Nothing,String} = nothing
    image_fallback::F = nothing
    syntax_renderer::S = nothing
end

session_tool_arg(value::AbstractString) = String(session_display_safe(value))
session_tool_arg(::Nothing) = ""
session_tool_arg(value) = nothing
session_tool_args(tool) = get(tool.call,"arguments",nothing) isa AbstractDict ? tool.call["arguments"] : Dict{String,Any}()
session_tool_details(tool) = session_tool_result_details(tool.result)
session_tool_result_details(::Nothing) = Dict{String,Any}()
function session_tool_result_details(result::AbstractDict)
    details=get(result,"details",nothing)
    details isa AbstractDict ? details : Dict{String,Any}()
end
function session_tool_style(kind::Symbol;bg=Tachikoma.NoColor(),bold=false)
    tokens=(title="toolTitle",output="toolOutput",added="toolDiffAdded",removed="toolDiffRemoved",context="toolDiffContext",skill="customMessageLabel",skilltext="customMessageText")
    fallbacks=(title=:text,output=:muted,added=:codeblock,removed=:error,context=:muted,skill=:accent,skilltext=:muted)
    runtime=isdefined(@__MODULE__,:ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    if !isnothing(runtime)&&haskey(tokens,kind)
        source=theme_token_style(runtime,tokens[kind];bold)
        Tachikoma.Style(;fg=source.fg,bg,bold,dim=source.dim)
    else
        session_display_style(haskey(fallbacks,kind) ? fallbacks[kind] : kind;bg,bold)
    end
end
session_tool_span(text,kind=:default;bold=false) = Tachikoma.Span(String(text),session_tool_style(kind;bold))
function session_tool_bg(kind::Symbol)
    runtime=isdefined(@__MODULE__,:ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    kind==:pending&&isnothing(runtime) ? Tachikoma.ColorRGB(52,56,58) : session_display_bg(kind)
end
session_tool_rows(spans,width,state,bg) = session_display_wrap(spans,width,state.output_padding;bg,preserve_background=true,preserve_gap_style=true)
function session_tool_restyle_edge!(row,which,style)
    index=which==:last ? lastindex(row) : firstindex(row)
    row[index]=Tachikoma.Span(row[index].content,style)
    row
end

"""Render a registered name, falling back to the generic truthful representation for all other names."""
function session_display_tool(tool::JuliaForever2.TimelineDisplayTool,width::Int,state::SessionDisplayState,registry::SessionBuiltinToolRenderers)
    name=get(tool.call,"name",nothing)
    if name=="read"
        session_tool_read(tool,width,state,registry)
    elseif name=="edit"
        session_tool_edit(tool,width,state,registry)
    elseif name in ("bash","powershell")
        session_tool_shell(tool,width,state,name=="powershell" ? "PS>" : "\$",registry)
    else
        session_display_tool(tool,width,state)
    end
end
session_display_tool(tool,width,state,::Nothing) = session_display_tool(tool,width,state)

function session_tool_path(args::AbstractDict,registry::SessionBuiltinToolRenderers)
    raw=get(args,"file_path",nothing)
    path=session_tool_arg(isnothing(raw) ? get(args,"path",nothing) : raw)
    if isnothing(path)
        session_tool_span("[invalid arg]",:error)
    elseif isempty(path)
        session_tool_span("...",:output)
    else
        shortened=path==registry.home ? "~" : startswith(path,registry.home*"/") ? "~"*path[nextind(path,lastindex(registry.home)):end] : path
        session_tool_span(shortened,:accent)
    end
end
session_tool_number(x::Real) = !(x isa Bool) && isfinite(x) ? x : nothing
function session_tool_number(x::AbstractString)
    parsed=isempty(strip(x)) ? nothing : tryparse(Float64,strip(x))
    isnothing(parsed) ? nothing : session_tool_number(parsed)
end
session_tool_number(x) = nothing
session_tool_numeric(x::Real) = isinteger(x) && abs(x)<=typemax(Int) ? string(Int(x)) : string(x)
function session_tool_range(args)
    offset,limit=get(args,"offset",nothing),get(args,"limit",nothing)
    start=isnothing(offset) ? 1 : session_tool_number(offset)
    count=session_tool_number(limit)
    if (isnothing(offset)&&isnothing(limit)) || isnothing(start) || (!isnothing(limit)&&isnothing(count))
        ""
    elseif isnothing(limit)
        ":"*session_tool_numeric(start)
    else
        finish=(start::Real)+(count::Real)-1
        ":"*session_tool_numeric(start)*(iszero(finish) ? "" : "-"*session_tool_numeric(finish))
    end
end

function session_tool_read_header(args::AbstractDict,registry::SessionBuiltinToolRenderers,expanded::Bool;expand_key::AbstractString="ctrl+o")
    raw=get(args,"file_path",nothing)
    path=session_tool_arg(isnothing(raw) ? get(args,"path",nothing) : raw)
    spans=Tachikoma.Span[]
    classification=""
    label=""
    if !expanded && !isnothing(path) && !isempty(path)
        absolute=normpath(isabspath(path) ? path : joinpath(registry.cwd,path))
        filename=basename(absolute)
        if filename=="SKILL.md"
            classification="skill";label=basename(dirname(absolute))
        elseif !isnothing(registry.docs_root) && startswith(absolute,normpath(registry.docs_root)*"/")
            relative=relpath(absolute,registry.docs_root)
            if relative=="README.md" || startswith(relative,"docs/") || startswith(relative,"examples/")
                classification="docs";label=relative
            end
        end
        if isempty(classification) && filename in ("AGENTS.override.md","AGENTS.md","AGENTS.MD","CLAUDE.md","CLAUDE.MD")
            classification="resource";label=startswith(absolute,normpath(registry.cwd)*"/") ? relpath(absolute,registry.cwd) : absolute
        end
    end
    if classification=="skill"
        push!(spans,session_tool_span("[skill]",:skill;bold=true),session_tool_span(" ",:skill),session_tool_span(label,:skilltext))
    elseif !isempty(classification)
        push!(spans,session_tool_span("read "*classification,:title;bold=true),session_tool_span(" "),session_tool_span(label,:accent))
    else
        push!(spans,session_tool_span("read",:title;bold=true),session_tool_span(" "),session_tool_path(args,registry))
    end
    range=session_tool_range(args)
    !isempty(range)&&push!(spans,session_tool_span(range,:warning))
    !isempty(classification)&&push!(spans,session_tool_span(" ("*expand_key*" to expand)",:dim))
    spans
end

"""Extract sanitized textual output and preserve unsupported blocks as explicit visible notices."""
function session_tool_output(tool,registry=nothing)
    result=tool.result
    content=isnothing(result) ? Any[] : session_display_content(get(result,"content",Any[]))
    lines=String[]
    for block in content
        kind=session_display_block_kind(block)
        if kind=="text"
            push!(lines,session_display_safe(replace(session_display_string(block["text"]),'\r'=>"")))
        elseif kind=="image"
            fallback=isnothing(registry) || isnothing(registry.image_fallback) ? "[Image: ["*session_display_safe(string(get(block,"mimeType","image/unknown")))*"]]" : registry.image_fallback(deepcopy(block))
            fallback isa AbstractString || error("Image fallback callback must return text")
            !isempty(fallback)&&push!(lines,session_display_safe(fallback))
        else
            push!(lines,"[Unsupported "*kind*" tool output; original payload retained]")
        end
    end
    join(lines,"\n")
end
function session_tool_size(bytes)::String
    n=bytes isa Real ? bytes : 51200
    n<1024 ? string(n,"B") : n<1048576 ? Printf.@sprintf("%.1fKB",n/1024) : Printf.@sprintf("%.1fMB",n/1048576)
end
session_tool_truncation(details) = get(details,"truncation",nothing) isa AbstractDict ? details["truncation"] : Dict{String,Any}()
function session_tool_read_warning(truncation)::String
    if get(truncation,"firstLineExceedsLimit",false)===true
        "[First line exceeds "*session_tool_size(get(truncation,"maxBytes",51200))*" limit]"
    elseif get(truncation,"truncatedBy",nothing)=="lines"
        "[Truncated: showing $(get(truncation,"outputLines","?")) of $(get(truncation,"totalLines","?")) lines ($(get(truncation,"maxLines",2000)) line limit)]"
    else
        "[Truncated: $(get(truncation,"outputLines","?")) lines shown ("*session_tool_size(get(truncation,"maxBytes",51200))*" limit)]"
    end
end
function session_tool_hint(count,label;expand_key::AbstractString="ctrl+o")
    [session_tool_span("... ($(count) $(label),",:muted),session_tool_span(" "),session_tool_span(expand_key,:dim),session_tool_span(" to expand",:muted),session_tool_span(")",:muted)]
end
function session_tool_read(tool,width,state,registry)
    result=tool.result
    expanded=session_display_expanded(state,tool.source_entry_id)
    failure=!isnothing(result)&&get(result,"isError",false)===true
    bg=session_tool_bg(isnothing(result) ? :pending : failure ? :error : :success)
    rows=SessionDisplayRows([session_display_blank(width),session_display_blank(width,bg)])
    append!(rows,session_tool_rows(session_tool_read_header(session_tool_args(tool),registry,expanded;expand_key=state.expand_key),width,state,bg))
    if !isnothing(result)&&(expanded||failure)
        args=session_tool_args(tool)
        path=session_tool_arg(get(args,"file_path",get(args,"path",nothing)))
        raw=session_tool_output(tool,registry)
        syntax=if !failure&&!isnothing(path)&&!isnothing(registry.syntax_renderer)
            registry.syntax_renderer(path,raw)
        else
            nothing
        end
        output=if isnothing(syntax)
            lines=split(raw,'\n';keepempty=true)
            while !isempty(lines)&&isempty(last(lines))
                pop!(lines)
            end
            kind=!failure && !isnothing(path) && lowercase(splitext(path)[2]) in (".md",".markdown") ? :codeblock : :output
            [[Tachikoma.Span(String(line),session_tool_style(kind))] for line in lines]
        else
            syntax.lines::SessionDisplayRows
        end
        count=expanded ? length(output) : min(length(output),10)
        !isempty(output)&&push!(rows,session_display_blank(width,bg))
        for line in output[1:count]
            append!(rows,session_tool_rows(line,width,state,bg))
        end
        if count<length(output)
            session_tool_restyle_edge!(last(rows),:last,session_display_style(:muted;bg))
            hintrows=session_tool_rows(session_tool_hint(length(output)-count,"more lines";expand_key=state.expand_key),width,state,bg)
            append!(rows,hintrows)
        end
        truncation=session_tool_truncation(session_tool_details(tool))
        if get(truncation,"truncated",false)===true
            append!(rows,session_display_text_rows(session_tool_read_warning(truncation),width,state.output_padding;style=session_display_style(:warning),bg))
        end
    end
    push!(rows,session_display_blank(width,bg))
    rows
end

function session_tool_duration(ms::Real)
    seconds=ms/1000
    total=floor(Int,seconds)
    if seconds<60
        Printf.@sprintf("%.1fs",seconds)
    elseif total<3600
        "$(fld(total,60))m $(mod(total,60))s"
    else
        "$(fld(total,3600))h $(mod(fld(total,60),60))m $(mod(total,60))s"
    end
end
function session_tool_clip(spans,width)
    remaining=max(0,width-3)
    clipped=Tachikoma.Span[]
    laststyle=Tachikoma.Style()
    if sum(textwidth(span.content) for span in spans)<=width
        append!(clipped,spans)
    else
        for span in spans
            content=""
            for g in Base.Unicode.graphemes(span.content)
                if textwidth(g)<=remaining
                    content*=g;remaining-=textwidth(g)
                else
                    break
                end
            end
            if !isempty(content)
                push!(clipped,Tachikoma.Span(content,span.style));laststyle=span.style
            end
            if iszero(remaining)
                break
            end
        end
        push!(clipped,Tachikoma.Span(repeat(".",min(3,width)),laststyle))
    end
    clipped
end
function session_tool_shell(tool::JuliaForever2.TimelineDisplayTool,width::Int,state::SessionDisplayState,prompt::AbstractString,registry::SessionBuiltinToolRenderers)
    args=session_tool_args(tool);result=tool.result;details=session_tool_details(tool)
    bg=session_tool_bg(isnothing(result) ? :pending : get(result,"isError",false)===true ? :error : :success)
    rows=SessionDisplayRows([session_display_blank(width),session_display_blank(width,bg)])
    command=session_tool_arg(get(args,"command",nothing))
    header=[session_tool_span(prompt*" ",:title;bold=true),session_tool_span(isnothing(command) ? "[invalid arg]" : isempty(command) ? "..." : command,isnothing(command) ? :error : isempty(command) ? :output : :title;bold=true)]
    timeout=get(args,"timeout",nothing)
    !isnothing(timeout)&&timeout!=0&&timeout!=false&&push!(header,session_tool_span(" (timeout $(timeout)s)",:muted))
    append!(rows,session_tool_rows(header,width,state,bg))
    if !isnothing(result)
        output=String(strip(session_tool_output(tool,registry)))
        truncation=session_tool_truncation(details);path=get(details,"fullOutputPath",nothing)
        if get(truncation,"truncated",false)===true && path isa AbstractString && endswith(output,"]")
            footer=findlast("\n\n[",output)
            if !isnothing(footer)&&occursin(path,output[first(footer):end])
                output=String(rstrip(output[begin:prevind(output,first(footer))]))
            end
        end
        if !isempty(output)
            push!(rows,session_display_blank(width,bg))
            rendered=session_display_text_rows(output,width,state.output_padding;style=session_tool_style(:output),bg)
            if !session_display_expanded(state,tool.source_entry_id)&&length(rendered)>5
                hint=session_tool_clip(session_tool_hint(length(rendered)-5,"earlier lines";expand_key=state.expand_key),max(1,width-2state.output_padding))
                hintrows=session_tool_rows(hint,width,state,bg)
                if sum(textwidth(span.content) for span in session_tool_hint(length(rendered)-5,"earlier lines";expand_key=state.expand_key))>max(1,width-2state.output_padding)
                    row=last(hintrows)
                    # The original truncator emits a full reset before its ellipsis.
                    capacity=max(1,width-2state.output_padding)
                    stop=state.output_padding+capacity-3
                    position=0
                    for i in eachindex(row)
                        span=row[i]
                        if position>=stop
                            row[i]=Tachikoma.Span(span.content,Tachikoma.Style())
                        end
                        position+=textwidth(span.content)
                    end
                end
                append!(rows,hintrows)
                preview=rendered[end-4:end]
                session_tool_restyle_edge!(first(preview),:first,Tachikoma.Style(;bg))
                append!(rows,preview)
            else
                append!(rows,rendered)
            end
        end
        if get(truncation,"truncated",false)===true || path isa AbstractString
            warnings=String[]
            path isa AbstractString&&push!(warnings,"Full output: "*session_display_safe(path))
            if get(truncation,"truncated",false)===true
                push!(warnings,get(truncation,"truncatedBy",nothing)=="lines" ? "Truncated: showing $(get(truncation,"outputLines","?")) of $(get(truncation,"totalLines","?")) lines" : "Truncated: $(get(truncation,"outputLines","?")) lines shown ("*session_tool_size(get(truncation,"maxBytes",51200))*" limit)")
            end
            push!(rows,session_display_blank(width,bg))
            append!(rows,session_display_text_rows("["*join(warnings,". ")*"]",width,state.output_padding;style=session_display_style(:warning),bg))
        end
        duration=get(result,"durationMs",nothing)
        if duration isa Real&&isfinite(duration)&&duration>=0
            push!(rows,session_display_blank(width,bg))
            append!(rows,session_display_text_rows("Took "*session_tool_duration(duration),width,state.output_padding;style=session_display_style(:muted),bg))
        end
    end
    push!(rows,session_display_blank(width,bg));rows
end

function session_tool_edit(tool,width,state,registry)
    result=tool.result;details=session_tool_details(tool)
    diff=get(details,"diff",nothing)
    hasdiff=diff isa AbstractString&&!isempty(diff)
    failure=!isnothing(result)&&get(result,"isError",false)===true
    bg=session_tool_bg(hasdiff ? :success : failure ? :error : :pending)
    rows=SessionDisplayRows([session_display_blank(width),session_display_blank(width,bg)])
    header=[session_tool_span("edit",:title;bold=true),session_tool_span(" "),session_tool_path(session_tool_args(tool),registry)]
    append!(rows,session_tool_rows(header,width,state,bg))
    if hasdiff
        push!(rows,session_display_blank(width,bg))
        append!(rows,session_tool_diff(diff,width,state,bg))
    end
    push!(rows,session_display_blank(width,bg))
    if failure
        output=session_tool_output(tool,registry)
        if !isempty(output)
            push!(rows,session_display_blank(width))
            append!(rows,session_display_text_rows(output,width,state.output_padding;style=session_display_style(:error)))
        end
    end
    rows
end

"""Align lexical tokens independently, bounding work while preserving all original diff text."""
function session_tool_word_masks(old::AbstractString,new::AbstractString)
    texts=(String(old),String(new))
    chars=collect.(texts)
    matches=[collect(eachmatch(r"[\p{L}\p{N}_]+|[^\s]",text)) for text in texts]
    tokens=[[String(match.match) for match in list] for list in matches]
    ranges=[[length(texts[side][begin:prevind(texts[side],m.offset)])+1:length(texts[side][begin:prevind(texts[side],m.offset)])+length(m.match) for m in matches[side]] for side in 1:2]
    left,right=length.(tokens)
    paired=Tuple{Int,Int}[]
    if left*right<=1_000_000
        lengths=zeros(Int,left+1,right+1)
        for a in left:-1:1,b in right:-1:1
            lengths[a,b]=tokens[1][a]==tokens[2][b] ? 1+lengths[a+1,b+1] : max(lengths[a+1,b],lengths[a,b+1])
        end
        a,b=1,1
        while a<=left&&b<=right
            if tokens[1][a]==tokens[2][b]
                push!(paired,(a,b));a+=1;b+=1
            elseif lengths[a+1,b]>=lengths[a,b+1]
                a+=1
            else
                b+=1
            end
        end
    end
    masks=[trues(length(cs)) for cs in chars]
    previous=[0,0]
    for pair in [paired;(left+1,right+1)]
        starts=[pair[side]<=length(ranges[side]) ? first(ranges[side][pair[side]]) : length(chars[side])+1 for side in 1:2]
        gaps=[previous[side]+1:starts[side]-1 for side in 1:2]
        prefix=0
        while prefix<min(length(gaps[1]),length(gaps[2])) && isspace(chars[1][first(gaps[1])+prefix])&&isspace(chars[2][first(gaps[2])+prefix])
            prefix+=1
        end
        suffix=0
        while suffix<min(length(gaps[1]),length(gaps[2]))-prefix && isspace(chars[1][last(gaps[1])-suffix])&&isspace(chars[2][last(gaps[2])-suffix])
            suffix+=1
        end
        for side in 1:2
            for pos in first(gaps[side]):first(gaps[side])+prefix-1
                masks[side][pos]=false
            end
            for pos in last(gaps[side])-suffix+1:last(gaps[side])
                masks[side][pos]=false
            end
            if pair[side]<=length(ranges[side])
                masks[side][ranges[side][pair[side]]].=false
                previous[side]=last(ranges[side][pair[side]])
            end
        end
    end
    for side in 1:2
        firstchanged=findfirst(masks[side])
        if !isnothing(firstchanged)
            while firstchanged<=length(chars[side])&&masks[side][firstchanged]&&isspace(chars[side][firstchanged])
                masks[side][firstchanged]=false;firstchanged+=1
            end
        end
    end
    masks
end
function session_tool_diff_spans(prefix,content,mask,kind,bg)
    base=session_tool_style(kind)
    inverse=Tachikoma.Style(;fg=bg,bg=base.fg)
    spans=[session_tool_span(prefix,kind)]
    for (i,char) in enumerate(content)
        push!(spans,Tachikoma.Span(string(char),mask[i] ? inverse : base))
    end
    spans
end
function session_tool_diff(diff::AbstractString,width::Int,state::SessionDisplayState,bg)
    rows=SessionDisplayRows()
    lines=split(session_display_safe(diff),'\n';keepempty=true)
    index=1
    while index<=length(lines)
        parsed=match(r"^([+\s-])(\s*\d*)\s(.*)$",lines[index])
        nextparsed=index<length(lines) ? match(r"^([+\s-])(\s*\d*)\s(.*)$",lines[index+1]) : nothing
        previousremoved=index>1&&startswith(lines[index-1],"-")
        nextadded=index+2<=length(lines)&&startswith(lines[index+2],"+")
        if !isnothing(parsed)&&!isnothing(nextparsed)&&parsed[1]=="-"&&nextparsed[1]=="+"&&!previousremoved&&!nextadded
            masks=session_tool_word_masks(parsed[3]::AbstractString,nextparsed[3]::AbstractString)
            for (side,item) in enumerate((parsed,nextparsed))
                spans=session_tool_diff_spans(string(item[1]::AbstractString,item[2]::AbstractString," "),item[3]::AbstractString,masks[side],side==1 ? :removed : :added,bg)
                append!(rows,session_tool_rows(spans,width,state,bg))
            end
            index+=2
        else
            kind=!isnothing(parsed)&&parsed[1]=="-" ? :removed : !isnothing(parsed)&&parsed[1]=="+" ? :added : :context
            append!(rows,session_display_text_rows(lines[index],width,state.output_padding;style=session_tool_style(kind),bg))
            index+=1
        end
    end
    rows
end
