# Test-only source-derived xterm cells, compared directly to native Buffer cells offline.
module TerminalCellFixture
using JSON,SHA,Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
color(::Tachikoma.NoColor)=(0,-1)
color(value::Tachikoma.ColorRGB)=(50331648,(Int(value.r)<<16)+(Int(value.g)<<8)+Int(value.b))
color(value::Tachikoma.Color256)=(33554432,Int(value.code))
color(::Owner.MenuSearchInverseColor)=(0,-1)
function canonical(cell)
    style=cell.style
    text=cell.char=='\0' ? " " : string(cell.char)*cell.suffix
    columns=cell.char=='\0' ? 0 : Owner.menu_search_width(text)
    foreground=color(style.fg);background=color(style.bg)
    Any[text,columns,foreground...,background...,style.bold,style.dim,style.italic,
        style.underline || !isempty(style.hyperlink),style.fg isa Owner.MenuSearchInverseColor,style.strikethrough,false]
end
"""Join only same-style graphemes, preserving their physical width and all style boundaries."""
function grapheme_cells(cells)
    result=Any[]
    groups=Vector{Any}[]
    for cell in cells
        if isempty(groups) || last(last(groups))[3:end]!=cell[3:end]
            push!(groups,Any[])
        end
        push!(last(groups),cell)
    end
    for group in groups
        text=Char[];widths=Int[]
        for cell in group
            if cell[2]>0
                characters=collect(cell[1])
                append!(text,characters)
                append!(widths,[cell[2];zeros(Int,length(characters)-1)])
            end
        end
        if isempty(text)
            append!(result,group)
        else
            offset=1
            for glyph in Base.Unicode.graphemes(join(text))
                count=length(glyph);columns=sum(widths[offset:offset+count-1]);style=first(group)[3:end]
                push!(result,Any[String(glyph),columns,style...])
                append!(result,[Any[" ",0,style...] for _ in 1:columns-1])
                offset+=count
            end
        end
    end
    result
end
function differences(buffer,fixture,id,width;first_row=1)
    frame=only(filter(frame->frame["id"]==id&&frame["width"]==width,fixture["snapshots"]))
    mismatches=Any[]
    for (row,runs) in enumerate(frame["rows"])
        expected=grapheme_cells([fixture["cells"][run[1]] for run in runs for _ in 1:run[2]])
        y=first_row+row-1
        present=Tachikoma.in_bounds(buffer,1,y) && Tachikoma.in_bounds(buffer,width,y)
        actual=present ? grapheme_cells([canonical(buffer.content[Tachikoma.buf_index(buffer,column,y)]) for column in 1:width]) : nothing
        if actual!=expected && length(mismatches)<20
            push!(mismatches,(;y,actual,expected))
        end
    end
    mismatches
end
end
