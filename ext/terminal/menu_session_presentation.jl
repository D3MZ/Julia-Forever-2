# Shared native presentation for archive and user-message selection.
abstract type SessionSelectionMenu end

function session_style(menu::SessionSelectionMenu,token::Symbol=:default;selected::Bool=false,bold::Bool=false)
    base=menu.style(token)
    Tachikoma.Style(;fg=base.fg,bg=selected ? menu.style(:selectedBg).bg : base.bg,
        bold=base.bold || (menu.bold && bold),dim=base.dim,italic=base.italic,
        underline=base.underline,strikethrough=base.strikethrough,hyperlink=base.hyperlink)
end
session_span(menu::SessionSelectionMenu,value::AbstractString,token::Symbol=:default;kwargs...) = Tachikoma.Span(String(value),session_style(menu,token;kwargs...))
session_line(menu::SessionSelectionMenu,value::AbstractString="",token::Symbol=:default;kwargs...) = [session_span(menu,value,token;kwargs...)]

"""Truncate styled graphemes, with a separately styled terminal-default marker."""
function session_clip(spans::AbstractVector{Tachikoma.Span},width::Int;marker::String="...")
    if tree_width(spans)<=max(0,width)
        spans
    else
        suffix=join(Iterators.take(menu_search_graphemes(marker),max(0,width)))
        [tree_slice(spans,0,max(0,width-menu_search_width(suffix)));Tachikoma.Span(suffix,Tachikoma.Style())]
    end
end

"""Apply Text-component wrapping and horizontal padding to native styled content."""
function session_text(menu::SessionSelectionMenu,text::AbstractString,width::Int;token::Symbol=:default,bold::Bool=false)
    margin=min(1,max(0,fld(width-1,2)))
    available=max(1,width-2margin)
    wrapped=thinking_wrap(text,available)
    map(enumerate(wrapped)) do (index,line)
        padding=repeat(" ",max(0,available-menu_search_width(line)))
        trailing=index==length(wrapped) ? :default : token
        [session_span(menu,repeat(" ",margin),:default),session_span(menu,line,token;bold),
            session_span(menu,padding*repeat(" ",margin),trailing;bold=index<length(wrapped)&&bold)]
    end
end

"""Write real native grapheme cells without splitting joined emoji into codepoint widths."""
function session_draw_lines!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,lines)
    limit=x+max(0,width)-1
    for (row,spans) in enumerate(lines)
        column,previous=x,x-1
        for span in spans
            clean=replace(span.content,MENU_SEARCH_ANSI=>"")
            clean=join(iscntrl(character) && character!='\t' ? ' ' : character for character in clean)
            for grapheme in Base.Unicode.graphemes(clean)
                glyph=String(grapheme)
                columns=menu_search_grapheme_width(glyph)
                if glyph=="\t"
                    column=min(limit,column+8-mod(column-1,8))
                elseif columns==0 && previous>=x && Tachikoma.in_bounds(buffer,previous,y+row-1)
                    cell=buffer.content[Tachikoma.buf_index(buffer,previous,y+row-1)]
                    Tachikoma.set!(buffer,previous,y+row-1,Tachikoma.Cell(cell.char,cell.style,cell.suffix*glyph))
                elseif columns>0 && column+columns-1<=limit
                    characters=collect(glyph)
                    Tachikoma.set!(buffer,column,y+row-1,Tachikoma.Cell(first(characters),span.style,join(characters[2:end])))
                    for offset in 1:columns-1
                        Tachikoma.set!(buffer,column+offset,y+row-1,Tachikoma.Cell('\0',span.style))
                    end
                    previous=column
                    column+=columns
                end
            end
        end
    end
    nothing
end
session_cancel_timer(timer::Nothing)=nothing
session_cancel_timer(timer::Timer)=close(timer)
