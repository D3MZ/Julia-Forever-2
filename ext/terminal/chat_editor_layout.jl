"""A wrapped row retains logical character offsets for rendering, navigation and hit testing."""
Base.@kwdef struct ChatEditorRow
    text::String = ""
    line::Int = 1
    start::Int = 0
    stop::Int = 0
    cursor::Union{Nothing,Int} = nothing
end

"""Wrap at whitespace/CJK boundaries, keeping paste markers atomic except when wider than a row."""
function chat_wrap(editor::ChatEditorState,text::AbstractString,width::Int;atomic::Bool=true)
    chunks=Tuple{String,Int,Int}[]
    if isempty(text) || width<=0
        push!(chunks,("",0,0))
    elseif menu_search_width(text)<=width
        push!(chunks,(String(text),0,length(text)))
    else
        segments=atomic ? chat_segments(editor,text) : chat_segments(ChatEditorState(),text)
        start=0;columns=0;boundary=-1;boundary_columns=0
        for (index,segment) in enumerate(segments)
            size=menu_search_width(segment.text)
            if columns+size>width
                if boundary>=0 && columns-boundary_columns+size<=width
                    push!(chunks,(chat_slice(text,start,boundary),start,boundary))
                    start=boundary;columns-=boundary_columns
                elseif start<segment.start
                    push!(chunks,(chat_slice(text,start,segment.start),start,segment.start))
                    start=segment.start;columns=0
                end
                boundary=-1
            end
            if size>width && segment.atomic
                parts=chat_wrap(editor,segment.text,width;atomic=false)
                for part in parts[1:end-1]
                    push!(chunks,(part[1],segment.start+part[2],segment.start+part[3]))
                end
                start=segment.start+last(parts)[2];columns=menu_search_width(last(parts)[1]);boundary=-1
            else
                columns+=size
                if index<length(segments)
                    next=segments[index+1]
                    whitespace=!segment.atomic && chat_space(segment.text)
                    nextspace=!next.atomic && chat_space(next.text)
                    if whitespace && !nextspace || !whitespace && !nextspace && ((!segment.atomic && chat_cjk(segment.text)) || (!next.atomic && chat_cjk(next.text)))
                        boundary=next.start;boundary_columns=columns
                    end
                end
            end
        end
        push!(chunks,(chat_suffix(text,start),start,length(text)))
    end
    chunks
end

"""Build the exact logical-to-visual row map without modifying the backing text."""
function chat_layout(editor::ChatEditorState,width::Int)
    position=chat_position(editor);rows=ChatEditorRow[]
    for (line,text) in enumerate(split(chat_text(editor),'\n';keepempty=true))
        chunks=chat_wrap(editor,text,width)
        for (index,chunk) in enumerate(chunks)
            hascursor=line==position.line && position.col>=chunk[2] && (index==length(chunks) || position.col<chunk[3])
            push!(rows,ChatEditorRow(;text=chunk[1],line,start=chunk[2],stop=chunk[3],cursor=hascursor ? position.col-chunk[2] : nothing))
        end
    end
    rows
end
function chat_scroll_border(direction::String,count::Int,width::Int)
    available=max(0,width);label=" $direction $count more ";size=menu_search_width(label)
    if size+2<=available
        left=fld(available-size,2)
        repeat("─",left)*label*repeat("─",available-left-size)
    else
        indicator="─── $direction $count more ";remaining=available-menu_search_width(indicator)
        remaining>=0 ? indicator*repeat("─",remaining) : menu_search_slice(indicator,0,max(0,available-min(3,available)))*first("...",min(3,available))
    end
end
chat_editor_border_style(runtime::Nothing) = pi_style(:text_dim)
chat_editor_border_style(runtime::ThemeRuntime) = theme_style(runtime,:borderMuted)

"""Render bordered native editor rows and IME coordinates for the fullscreen scene compositor."""
function chat_editor_lines(editor::ChatEditorState,width::Integer,height::Integer;runtime=nothing,padding::Integer=0,hardware_cursor::Bool=false,top_border=nothing,border_style=nothing)
    chat_sync!(editor)
    margin=clamp(padding,0,max(0,fld(width-1,2)))
    content=max(1,width-2margin);layoutwidth=max(1,content-(margin==0 ? 1 : 0))
    editor.layout_width=layoutwidth;editor.terminal_rows=height
    rows=chat_layout(editor,layoutwidth)
    index=something(findfirst(row->!isnothing(row.cursor),rows),1)
    maximum=max(5,floor(Int,height*0.3))
    editor.scroll=index<=editor.scroll ? index-1 : index>editor.scroll+maximum ? index-maximum : editor.scroll
    editor.scroll=clamp(editor.scroll,0,max(0,length(rows)-maximum))
    visible=rows[editor.scroll+1:min(end,editor.scroll+maximum)]
    editor.visible_rows=length(visible)
    border=isnothing(border_style) ? chat_editor_border_style(runtime) : border_style
    top=editor.scroll>0 ? chat_scroll_border("↑",editor.scroll,width) : repeat("─",max(0,width))
    result=Vector{Tachikoma.Span}[isnothing(top_border) ? [Tachikoma.Span(top,border)] : top_border(width,editor.scroll)]
    cursor_row=nothing;cursor_col=nothing
    for (row_index,row) in enumerate(visible)
        spans=Tachikoma.Span[Tachikoma.Span(repeat(" ",margin),Tachikoma.RESET)]
        columns=menu_search_width(row.text)
        if isnothing(row.cursor)
            push!(spans,Tachikoma.Span(row.text,Tachikoma.RESET))
        else
            before=chat_prefix(row.text,row.cursor);after=chat_suffix(row.text,row.cursor)
            segments=chat_segments(editor,after)
            selected=isempty(segments) ? " " : first(segments).text
            rest=isempty(segments) ? "" : chat_suffix(after,length(selected))
            push!(spans,Tachikoma.Span(before,Tachikoma.RESET))
            push!(spans,Tachikoma.Span(selected,editor.focused && hardware_cursor ? Tachikoma.RESET : Tachikoma.Style(;fg=MenuSearchInverseColor())))
            push!(spans,Tachikoma.Span(rest,Tachikoma.RESET))
            isempty(after) && (columns+=1)
            editor.focused && (cursor_row=row_index+1;cursor_col=margin+menu_search_width(before)+1)
        end
        right=margin>0 && columns>content ? margin-1 : margin
        push!(spans,Tachikoma.Span(repeat(" ",max(0,content-columns)+right),Tachikoma.RESET))
        push!(result,spans)
    end
    below=length(rows)-(editor.scroll+length(visible))
    bottom=below>0 ? chat_scroll_border("↓",below,width) : repeat("─",max(0,width))
    push!(result,[Tachikoma.Span(bottom,border)])
    (lines=result,cursor_row,cursor_col,scroll=editor.scroll,rows=rows)
end
