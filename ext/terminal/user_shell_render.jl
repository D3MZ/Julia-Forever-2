"""Render real running/deferred command state without mutating the archive or executing content."""
function user_shell_run_lines(run::UserShellRun,width::Int,state::SessionDisplayState)
    stored=run.message
    message=isnothing(stored) ? Dict{String,Any}("command"=>run.command,"output"=>run.visible,"excludeFromContext"=>run.excluded) : JuliaForever2.user_shell_record(stored)
    running=isnothing(run.result)
    frame=1+Int(mod(div(time_ns()-run.started_ns,80_000_000),10))
    view=SessionDisplayState(;expand_all=run.expanded,output_padding=state.output_padding,expand_key=state.expand_key)
    rows=session_display_bash(message,string(run.id),width,view;running,frame)
    if !isempty(run.reason)
        append!(rows,session_display_text_rows(run.reason,width,state.output_padding;style=session_display_style(:error)))
    end
    rows
end
function user_shell_lines(app::App,width::Int;pending::Bool=false)
    state=app.operations.shell;rows=SessionDisplayRows()
    runs=[state.failures;state.pending]
    isnothing(state.active) || push!(runs,state.active)
    for run in runs
        if run.deferred==pending
            append!(rows,user_shell_run_lines(run,width,app.transcript.display))
        end
    end
    rows
end

"""Match Ctrl+O on existing chat components only; deferred components retain their own expansion state."""
function user_shell_expand!(app::App,expanded::Bool)
    state=app.operations.shell;runs=[state.pending;state.failures]
    isnothing(state.active) || push!(runs,state.active)
    for run in runs
        run.deferred || (run.expanded=expanded)
    end
    nothing
end

user_shell_border(::Nothing)=session_display_style(:bash)
user_shell_border(runtime::ThemeRuntime)=theme_style(runtime,:bashMode)
