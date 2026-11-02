# Native cell painter follows Pi layout.ts at 2c8d1feb; MIT, see licenses/pi-LICENSE.
"""Combine a source scrollbar foreground with only the original cell background, not its text attributes."""
function terminal_scrollbar_cell_style(style::Tachikoma.Style,background::Tachikoma.AbstractColor)
    Tachikoma.Style(;fg=style.fg,bg=style.bg isa Tachikoma.NoColor ? background : style.bg,
        bold=style.bold,dim=style.dim,italic=style.italic,underline=style.underline,strikethrough=style.strikethrough)
end

"""Replace an entire intersected wide glyph without leaving an orphan continuation cell."""
function terminal_scrollbar_replace!(buffer::Tachikoma.Buffer,column::Int,row::Int,glyph::Char,
        style::Tachikoma.Style,preserve::Bool)
    if Tachikoma.in_bounds(buffer,column,row)
        first=column;last=column
        while first>buffer.area.x && buffer.content[Tachikoma.buf_index(buffer,first,row)].char=='\0'
            first-=1
        end
        while last+1<buffer.area.x+buffer.area.width && buffer.content[Tachikoma.buf_index(buffer,last+1,row)].char=='\0'
            last+=1
        end
        target=buffer.content[Tachikoma.buf_index(buffer,first,row)]
        background=preserve ? target.style.bg : Tachikoma.NoColor()
        for x in first:last
            Tachikoma.set!(buffer,x,row,Tachikoma.Cell(' ',Tachikoma.Style(;bg=background)))
        end
        Tachikoma.set!(buffer,column,row,Tachikoma.Cell(glyph,terminal_scrollbar_cell_style(style,background)))
    end
    nothing
end

"""Paint only document cells, retaining auto-overlay backgrounds and excluding native image-line owners."""
function terminal_scroll_control_draw!(control::TerminalScrollControl,buffer::Tachikoma.Buffer;
        style,
        image_rows::AbstractSet{Int}=Set{Int}(),now::Real=time_ns()/1e9)
    viewport=control.snapshot
    if !control.closed && viewport.fullscreen
        geometry=terminal_scroll_geometry(control.scroll,viewport.rect.width;now)
        if !isnothing(geometry)
            column=viewport.rect.x+geometry.column-1
            clip=viewport.clip
            if clip.x<=column<clip.x+clip.width
                for offset in 0:geometry.height-1
                    row=viewport.rect.y+offset
                    source=control.scroll.top+offset+1
                    if clip.y<=row<clip.y+clip.height && !(source in image_rows)
                        thumb=geometry.thumb_top<=offset+1<geometry.thumb_top+geometry.thumb_height
                        glyph=thumb ? (control.scroll.active ? '█' : '┃') : '│'
                        token=thumb ? :scrollbarThumb : :scrollbarTrack
                        terminal_scrollbar_replace!(buffer,column,row,glyph,style(token),control.scroll.mode!=:always)
                    end
                end
            end
        end
    end
    nothing
end
