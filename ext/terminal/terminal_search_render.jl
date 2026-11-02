"""Clip structured search rows at complete graphemes without guessing a terminal palette."""
function terminal_search_clip_spans(spans::Vector{Tachikoma.Span},width::Int)
    result=Tachikoma.Span[];used=0;fitting=true
    for span in spans,glyph in Base.Unicode.graphemes(span.content)
        columns=menu_search_width(glyph)
        if fitting && used+columns<=max(0,width)
            push!(result,Tachikoma.Span(String(glyph),span.style));used+=columns
        else
            fitting=false
        end
    end
    result
end
terminal_search_width(spans::Vector{Tachikoma.Span})=sum(span->menu_search_width(span.content),spans;init=0)
terminal_search_span(text::AbstractString)=Tachikoma.Span(String(text),Tachikoma.Style())

"""Measure pasted control bytes as the replacement glyphs the safe native output adapter actually paints."""
function terminal_search_display_input(input::MenuSearchInput)
    safe=join(iscntrl(char) ? "�" : string(char) for char in input.value)
    if safe==input.value
        input
    else
        prefix=join(iscntrl(char) ? "�" : string(char) for char in menu_search_prefix(input))
        MenuSearchInput(;value=safe,cursor=min(length(menu_search_graphemes(prefix)),length(menu_search_graphemes(safe))),prompt=input.prompt)
    end
end

"""Render the source placeholder's dim fake cursor rather than an empty generic menu prompt."""
function terminal_search_input_lines(state::TerminalTranscriptSearch,width::Int;hardware::Bool=false)
    spans=Tachikoma.Span[];state.cursor_column=nothing
    if isempty(state.input.value) && width>1
        placeholder=terminal_indicator_clip("Find in transcript",width-1)
        glyphs=menu_search_graphemes(placeholder);cursor=isempty(glyphs) ? " " : first(glyphs)
        push!(spans,terminal_search_span(" "))
        state.cursor_column=1
        push!(spans,Tachikoma.Span(cursor,hardware ? Tachikoma.Style(;dim=true) : selection_inverse(Tachikoma.Style(;dim=true))))
        push!(spans,Tachikoma.Span(join(glyphs[2:end]),Tachikoma.Style(;dim=true)))
        push!(spans,terminal_search_span(repeat(" ",max(0,width-terminal_search_width(spans)))))
    else
        runs=menu_search_render!(terminal_search_display_input(state.input),max(1,width));column=0
        for run in runs
            if run.inverse && column<width
                state.cursor_column=column
            end
            push!(spans,Tachikoma.Span(run.text,run.inverse && !hardware ? Tachikoma.Style(;fg=MenuSearchInverseColor()) : Tachikoma.Style()))
            column+=menu_search_width(run.text)
        end
    end
    terminal_search_clip_spans(spans,width)
end

"""Render all three real search rows and save their exact zero-based navigation hitboxes."""
function terminal_search_lines(state::TerminalTranscriptSearch,width::Integer;
        previous_key::AbstractString="Shift+Enter",next_key::AbstractString="Enter",decorate::Bool=true,hardware::Bool=false)
    columns=max(1,Int(width));inner=max(0,columns-2)
    result=!isnothing(state.input_error) ? "Invalid input" : isempty(state.query) ? "" : !isempty(terminal_search_normalize(state.query)) && !isnothing(state.index.error) ? "Search unavailable" : isempty(state.matches) ? "No matches" : "$(state.selected+1)/$(length(state.matches))"
    visible_result=terminal_indicator_clip(result,max(0,inner-3))
    result_text=isempty(visible_result) ? "" : " "*visible_result*" "
    input_width=max(0,inner-menu_search_width(result_text))
    input=terminal_search_input_lines(state,input_width;hardware)
    push!(input,terminal_search_span(repeat(" ",max(0,input_width-terminal_search_width(input)))))
    push!(input,Tachikoma.Span(result_text,Tachikoma.Style(;dim=true)))
    previous=string("↑ ",previous_key)::String;next=string("↓ ",next_key)::String;separator=" · "
    available=max(0,inner-3);controls=menu_search_width(previous*separator*next)
    if controls>available
        previous="↑";next="↓";separator=" ";controls=3
    end
    buttons=controls<=available
    right=buttons && inner>controls+2 ? 1 : 0
    left=max(0,inner-(buttons ? controls+2 : 0)-right)
    start=1+left+1
    state.previous=buttons ? (start:start+menu_search_width(previous)-1) : (-1:-2)
    next_start=buttons ? last(state.previous)+1+menu_search_width(separator) : -1
    state.next=buttons ? (next_start:next_start+menu_search_width(next)-1) : (-1:-2)
    if columns==1
        [[terminal_search_span("┌")],[terminal_search_span("│")],[terminal_search_span("└")]]
    else
        bottom=Tachikoma.Span[terminal_search_span("└"*repeat("─",left))]
        if buttons
            append!(bottom,[terminal_search_span(" "),Tachikoma.Span(previous,Tachikoma.Style(;underline=decorate && state.hovered==-1)),
                terminal_search_span(separator),Tachikoma.Span(next,Tachikoma.Style(;underline=decorate && state.hovered==1)),terminal_search_span(" ")])
        end
        push!(bottom,terminal_search_span(repeat("─",right)*"┘"))
        [[terminal_search_span("┌"*repeat("─",inner)*"┐")],
            [terminal_search_span("│");input;terminal_search_span("│")],bottom]
    end
end

"""Resolve the original top-right 40-percent overlay with its minimum width and one-cell margins."""
function terminal_search_bounds!(state::TerminalTranscriptSearch,area::Tachikoma.Rect)
    width=max(1,min(max(fld(2*area.width,5),32),max(1,area.width-2)))
    x=area.x+max(1,min(1+max(1,area.width-2)-width,area.width-1-width))
    y=area.y+max(1,min(1,area.height-1-3))
    state.bounds=Tachikoma.Rect(x,y,width,3)
end

"""Preserve native character styles while overlaying the exact search match palette and attributes."""
function terminal_search_style(style::Tachikoma.Style,theme::NativeTheme,current::Bool)
    foreground=theme_token_style(theme,"searchMatchText").fg
    background=theme_token_style(theme,"searchMatchBg").bg
    result=Tachikoma.Style(;fg=foreground,bg=background,bold=current && theme.bold || style.bold,
        dim=style.dim,italic=style.italic,underline=(!current && theme.bold) || style.underline,strikethrough=style.strikethrough,hyperlink=style.hyperlink)
    current && theme.bold ? selection_inverse(result) : result
end
terminal_search_style(style::Tachikoma.Style,theme::ThemeRuntime,current::Bool)=terminal_search_style(style,theme.active,current)

"""Highlight only visible primary-document matches, excluding the actual visible scrollbar and image anchors."""
function terminal_search_highlight!(state::TerminalTranscriptSearch,buffer::Tachikoma.Buffer,view::TerminalScrollViewport;
        theme::Union{NativeTheme,ThemeRuntime},scrollbar_column::Union{Nothing,Int}=nothing,image_rows::AbstractSet{Int}=Set{Int}())
    if state.active && view.fullscreen && state.selected>=0
        clip=view.clip;left=max(buffer.area.x,view.rect.x,clip.x)
        right=min(buffer.area.x+buffer.area.width,view.rect.x+view.rect.width,clip.x+clip.width,something(scrollbar_column,typemax(Int)))
        for (index,matched) in enumerate(state.matches),segment in matched.segments
            row=view.rect.y+segment.row-view.top
            if max(buffer.area.y,view.rect.y,clip.y)<=row<min(buffer.area.y+buffer.area.height,view.rect.y+view.rect.height,clip.y+clip.height) && !(row in image_rows)
                start=max(left,view.rect.x+segment.first);stop=min(right,view.rect.x+segment.last)
                for column in start:stop-1
                    cell=buffer.content[Tachikoma.buf_index(buffer,column,row)]
                    Tachikoma.set!(buffer,column,row,Tachikoma.Cell(cell.char,terminal_search_style(cell.style,theme,index-1==state.selected),cell.suffix))
                end
            end
        end
    end
    nothing
end

"""Composite one real styled overlay row with the source's whole-wide-glyph boundary removal."""
function terminal_search_overlay_cells(cells::Vector{Tachikoma.Cell},overlay::Vector{Tachikoma.Cell},start::Int,width::Int)
    before,after=terminal_indicator_segments(cells,start,start+length(overlay))
    before_style=isempty(before) ? Tachikoma.Style() : last(before).style
    append!(before,[Tachikoma.Cell(' ',before_style) for _ in 1:max(0,start-length(before))])
    result=[before;overlay;after]
    after_style=isempty(after) ? Tachikoma.Style() : last(after).style
    append!(result,[Tachikoma.Cell(' ',after_style) for _ in 1:max(0,width-length(result))])
    result[1:min(width,length(result))]
end

"""Paint the real overlay after the jump indicator and before selection, including tiny-height clipping."""
function terminal_search_overlay_draw!(state::TerminalTranscriptSearch,buffer::Tachikoma.Buffer;
        area::Tachikoma.Rect=buffer.area,previous_key::AbstractString="Shift+Enter",next_key::AbstractString="Enter",decorate::Bool=true,hardware::Bool=false)
    if state.active && area.width>0 && area.height>0
        bounds=terminal_search_bounds!(state,area)
        lines=terminal_search_lines(state,bounds.width;previous_key,next_key,decorate,hardware)
        overlay=Tachikoma.Buffer(Tachikoma.Rect(1,1,bounds.width,3))
        startup_document_draw!(overlay,1,1,bounds.width,lines)
        working=max(area.height,bounds.y-area.y+3);shift=working-area.height
        blank=[Tachikoma.Cell(' ',Tachikoma.Style()) for _ in 1:area.width]
        rows=[[buffer.content[Tachikoma.buf_index(buffer,x,y)] for x in area.x:area.x+area.width-1] for y in area.y:area.y+area.height-1]
        append!(rows,[copy(blank) for _ in 1:shift])
        for local_row in 0:2
            target=shift+bounds.y-area.y+local_row+1
            if 1<=target<=length(rows)
                cells=[overlay.content[Tachikoma.buf_index(overlay,x,local_row+1)] for x in 1:bounds.width]
                rows[target]=terminal_search_overlay_cells(rows[target],cells,bounds.x-area.x,area.width)
            end
        end
        for (index,row) in enumerate(rows[shift+1:end]),(column,cell) in enumerate(row)
            Tachikoma.set!(buffer,area.x+column-1,area.y+index-1,cell)
        end
    end
    nothing
end

"""Expose the overlay-local cursor cell without synthesizing terminal control sequences."""
function terminal_search_cursor(state::TerminalTranscriptSearch)
    column=state.cursor_column
    terminal_search_focused(state) && !isnothing(column) ? (row=1,column=1+column) : nothing
end
