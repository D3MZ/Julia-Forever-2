"""Publish semantic metadata only for the same actual session and composed viewport document."""
function terminal_prompt_document!(app::App,prefix_rows::Int,archive_rows::Int,preview_rows::Int)
    progress=app.transcript.preview
    kind=isnothing(progress) ? nothing : progress.kind
    terminal_prompt_publish!(app.transcript.prompts,string(app.session.runtime.id),prefix_rows,archive_rows,preview_rows;preview_kind=kind)
end

"""Route semantic navigation through the current snapshot, preserving real menu/editor capture policy."""
function terminal_prompt_key!(app::App,packet::AbstractString)
    viewport=app.menus.viewport
    handled=false
    if terminal_presentation_mode(app)==:fullscreen && !isnothing(viewport) && !terminal_viewport_defers(app)
        prompts=app.transcript.prompts
        if prompts.owner==string(app.session.runtime.id)==viewport.scroll.control.snapshot.owner
            result=terminal_prompt_input!(viewport.scroll.control,prompts.document,packet)
            handled=result.handled
            handled && terminal_scroll_host_publish!(viewport.scroll,app)
        end
    end
    handled
end
