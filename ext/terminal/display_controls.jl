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
