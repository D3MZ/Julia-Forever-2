"""Update physical terminal controls only after the actual frame has been drawn."""
function terminal_output_frame!(app::App; now::Real=time_ns()/1e9)
    terminal=app.settings.terminal
    if !isnothing(terminal)
        output=app.settings.output
        running=app.busy && app.operations.active_kind in (:turn,:evaluation,:compaction_done)
        terminal_progress!(output,terminal.io,running && menu_preference(app,"terminal-progress","false")=="true";now)
        if terminal_presentation_mode(app)==:fullscreen && !app.settings.presentation.leased
            terminal_cursor!(output,terminal.io,menu_preference(app,"show-hardware-cursor","false")=="true",output.cursor;
                width=terminal.size.width,height=terminal.size.height)
        end
        flush(terminal.io)
    end
    nothing
end
Tachikoma.post_render!(app::App)=terminal_output_frame!(app)

"""Publish the exact composed scene cursor after clipping; no terminal escape is emitted in view."""
function terminal_output_cursor!(app::App,cursor::Union{Nothing,Tuple{Int,Int}})
    app.settings.output.cursor=cursor
    nothing
end

function close_terminal_output!(app::App)
    terminal=app.settings.terminal
    if !isnothing(terminal)
        terminal_output_close!(app.settings.output,terminal.io)
    end
    nothing
end

# Both effects are consumed from persisted preferences in post_render!, never reported as completed I/O here.
apply_setting_effect!(app::App,::Val{Symbol("terminal-progress")},value::AbstractString)=nothing
apply_setting_effect!(app::App,::Val{Symbol("show-hardware-cursor")},value::AbstractString)=nothing
