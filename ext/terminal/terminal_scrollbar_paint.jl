# Tachikoma.set_char! owns cell-background preservation and wide-glyph cleanup.
# Keep Pi-specific overlay visibility and image-row exclusion in this adapter.

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
                        Tachikoma.set_char!(buffer,column,row,glyph,style(token))
                    end
                end
            end
        end
    end
    nothing
end
