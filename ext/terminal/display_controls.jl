"""Apply the persisted thinking visibility to the actual transcript projection, not just its menu label."""
function apply_setting_effect!(app::App, ::Val{Symbol("hide-thinking")}, value::AbstractString)
    session_display_transition!(app.transcript.display, value == "true" ? :hide_thinking : :show_thinking)
    app.transcript.display_key = nothing
    nothing
end

"""Use the same verified private preference transaction for the keyboard and settings action."""
function toggle_thinking_visibility!(app::App)
    hidden = !app.transcript.display.hide_thinking
    value = hidden ? "true" : "false"
    set_setting_value!(app, "hide-thinking", value)
    if app.transcript.display.hide_thinking == hidden && menu_preference(app, "hide-thinking", "false") == value
        app.status = "Thinking blocks: " * (hidden ? "hidden" : "visible")
    end
    nothing
end

"""Rerender current and archived Mermaid blocks when a real persisted display mode changes."""
function apply_setting_effect!(app::App,::Val{Symbol("mermaid-rendering")},value::AbstractString)
    if value in ("off","final","streaming")
        app.transcript.display.mermaid_mode=Symbol(value)
        app.transcript.display_key=nothing
        app.transcript.preview_dirty=true
        app.transcript.width=0
        (ok=true,reason="")
    else
        (ok=false,reason="Mermaid rendering mode is invalid")
    end
end
