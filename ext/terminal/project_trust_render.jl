"""Render only trusted local metadata through the existing control-safe terminal text path."""
function project_trust_text_lines(text::AbstractString,width::Int,style::Symbol=:muted)
    startup_text_lines(startup_rich(startup_safe_text(text),pi_style(style)),width;padding=1)
end

"""Render source-equivalent saved/current decisions and explicit choices, with native scope disclosed at admission."""
project_trust_lines(app::App,width::Int) = project_trust_lines(app.menus.project_trust,width;selectors=native_selector_context(app))
project_trust_lines(::Nothing,width::Int;kwargs...) = Vector{Tachikoma.Span}[]
function project_trust_lines(state::ProjectTrustState,width::Int;selectors::NativeSelectorBindings=NativeSelectorBindings())
    lines=Vector{Tachikoma.Span}[menu_line(repeat("─",max(0,width)),:menu_border),menu_line()]
    heading=state.startup_prompt ? "Trust project folder?" : "Project trust"
    push!(lines,[menu_span(" "),Tachikoma.Span(heading,Tachikoma.Style(;fg=pi_style(:accent).fg,bold=true))])
    append!(lines,project_trust_text_lines(state.directory,width))
    push!(lines,menu_line())
    if state.startup_prompt
        explanation="This allows Julia Forever 2 to load this project's .pi skills and prompts. It does not install packages, execute extensions, or grant host permissions."
        append!(lines,project_trust_text_lines(explanation,width))
        push!(lines,menu_line())
    else
        saved=state.saved_decision
        decision=isnothing(saved) ? "none" : (saved ? "trusted" : "untrusted")*
            (state.saved_path==state.canonical ? " ($(state.saved_path))" : " (inherited from $(state.saved_path))")
        append!(lines,project_trust_text_lines("Saved decision: "*decision,width))
        append!(lines,project_trust_text_lines("Current session: "*(state.trusted ? "trusted" : "untrusted"),width))
        push!(lines,menu_line())
    end
    for (index,option) in enumerate(state.options)
        selected=index==state.cursor
        current=!isnothing(option.saved_path) && option.saved_path==state.saved_path && option.trusted===state.saved_decision
        prefix=selected ? "→ " : "  "
        marker=current ? "✓ " : "  "
        rich=startup_rich(prefix,selected ? pi_style(:accent) : Tachikoma.Style())
        startup_rich!(rich,marker,current ? pi_style(:accent) : Tachikoma.Style())
        startup_rich!(rich,option.label,selected ? pi_style(:accent) : pi_style(:text))
        append!(lines,startup_text_lines(rich,width;padding=1))
    end
    for reason in (state.error,state.store_error)
        isempty(reason) || append!(lines,project_trust_text_lines(reason,width,:warning))
    end
    push!(lines,menu_line())
    hint=startup_rich(native_selector_move_hint(selectors,"↑↓"),pi_style(:text_dim))
    startup_rich!(hint," navigate",pi_style(:muted));startup_rich!(hint,"  ")
    startup_rich!(hint,native_selector_text(selectors,:confirm),pi_style(:text_dim))
    startup_rich!(hint,state.startup_prompt ? " select" : " save",pi_style(:muted));startup_rich!(hint,"  ")
    startup_rich!(hint,native_selector_text(selectors,:cancel),pi_style(:text_dim));startup_rich!(hint," cancel",pi_style(:muted))
    append!(lines,startup_text_lines(hint,width;padding=1))
    push!(lines,menu_line())
    push!(lines,menu_line(repeat("─",max(0,width)),:menu_border))
    lines
end
