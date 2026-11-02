"""Prepare session-owned setting consumers before publishing a replacement runtime or discarding the old one."""
function prepare_terminal_session_preferences(app::App,session::Session)
    transcript=TranscriptState()
    previous=app.transcript.display
    transcript.display.expand_all=previous.expand_all
    transcript.display.show_usage=previous.show_usage
    transcript.display.hidden_thinking_label=previous.hidden_thinking_label
    steering=menu_preference(app,"steering-mode","one-at-a-time")
    follow_up=menu_preference(app,"follow-up-mode","one-at-a-time")
    hide_thinking=menu_preference(app,"hide-thinking","false")
    block_images=menu_preference(app,"block-images","false")
    mermaid=menu_preference(app,"mermaid-rendering","streaming")
    valid=steering in ("one-at-a-time","all") && follow_up in ("one-at-a-time","all") && hide_thinking in ("false","true") && block_images in ("false","true") && mermaid in ("off","final","streaming")
    result=if !valid
        (ok=false,reason="Session preference values are invalid")
    elseif !isopen(session)
        (ok=false,reason="Replacement session is closed")
    else
        inputs=session.runtime.pending_inputs
        lock(inputs.lock) do
            if inputs.closed
                (ok=false,reason="Replacement session input queues are closed")
            else
                first=JuliaForever2.set_input_queue_mode!(inputs,:steering,steering)
                second=JuliaForever2.set_input_queue_mode!(inputs,:follow_up,follow_up)
                (ok=first.ok && second.ok,reason=first.ok ? second.reason : first.reason)
            end
        end
    end
    if result.ok
        install!(session.kernel,ComponentSpec(:block_images,block_images=="true"))
    end
    transcript.display.mermaid_mode=mermaid in ("off","final","streaming") ? Symbol(mermaid) : :off
    session_display_transition!(transcript.display,hide_thinking=="true" ? :hide_thinking : :show_thinking)
    footer = result.ok ? prepare_footer_controls(app, session) : nothing
    isnothing(footer) || (transcript.footer = footer.state)
    (ok=result.ok,reason=result.reason,transcript,directory=isnothing(footer) ? app.directory : footer.directory)
end
