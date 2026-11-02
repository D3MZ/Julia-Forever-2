const BUG_REPORT_PRIVACY="This report is prepared locally for the Julia Forever 2 developers. Nothing is uploaded or published automatically. It contains application/Julia versions, operating system and selected model identifiers. It does not automatically collect credential or settings files."
const BUG_REPORT_TRANSCRIPT="The transcript contains your messages, model output, tool calls and their results, including file contents and command output read during this session. It may contain secrets or other sensitive information and is not automatically sanitized. Review it before sharing."

function bug_report_command!(app::App,arguments::AbstractString)
    timeline=app.archive.timeline
    if isnothing(timeline)
        app.status="No active session archive"
    elseif app.busy || app.operations.closing[]
        app.status="Finish or cancel the active operation first."
    else
        identity=with_component(app.session.kernel,:provider;fallback=nothing) do provider
            JuliaForever2.provider_model_identity(provider)
        end
        provider=isnothing(identity) ? nothing : string(identity.provider_id)
        model=isnothing(identity) || isempty(identity.model_id) ? nothing : identity.model_id
        editor=ChatEditorState(TextInput(;label=""))
        chat_set_text!(editor,String(arguments));editor.focused=true
        app.menus.bug_report=BugReportControl(;owner=timeline.identity.id,editor,provider,model,model_name=something(model,"the current model"))
        app.page=:bug_report
        app.menu=false
        app.status=""
    end
    nothing
end

function bug_report_close!(app::App,status::String="Bug report cancelled")
    app.menus.bug_report=nothing
    app.page=:chat
    app.menu=false
    app.status=status
    nothing
end

function bug_report_choices(control::BugReportControl)
    if control.stage==:transcript
        (title="Include the session transcript?",description=BUG_REPORT_TRANSCRIPT,choices=["Yes, include the transcript","No"])
    elseif control.stage==:summary
        (title="Attach a summary written by "*control.model_name*" instead?",
            description="The transcript is sent to "*something(control.provider,"your provider")*" with your configured credentials and tokens. Only the generated summary is attached; no report is published.",choices=["Yes, generate a summary","No"])
    elseif control.stage==:delivery
        description="Description: "*(isempty(control.description) ? "none" : control.description)*"\nTranscript: "*(control.transcript ? "included" : "not included")*"\nSummary: "*(control.summary ? "written by "*control.model_name : "none")*"\n\nExport writes a private ZIP in the current directory. A GitHub issue draft is a private ZIP containing issue.md and selected attachments; it must be reviewed and submitted manually at "*JuliaForever2.JF2_ISSUE_PAGE*"."
        (title="Bug report",description,choices=["Export as Zip","Prepare GitHub issue draft","Cancel"])
    else
        (title="Bug report",description="",choices=String[])
    end
end

function bug_report_view(control::BugReportControl,width::Int,height::Int;runtime=nothing)
    rows=SessionDisplayRows()
    cursor_row=nothing
    cursor_col=nothing
    border=[Tachikoma.Span(repeat("─",width),session_display_style(:border))]
    push!(rows,border,session_display_blank(width))
    if control.stage==:description
        append!(rows,session_display_text_rows("Report a bug",width,1;style=session_display_style(:accent)))
        push!(rows,session_display_blank(width))
        append!(rows,session_display_text_rows(BUG_REPORT_PRIVACY*"\n\nWhat went wrong? (optional)",width,1;style=session_display_style(:text)))
        push!(rows,session_display_blank(width))
        editor=chat_editor_lines(control.editor,width,max(5,height-length(rows)-4);runtime,padding=0)
        cursor_row=isnothing(editor.cursor_row) ? nothing : length(rows)+editor.cursor_row
        cursor_col=editor.cursor_col
        append!(rows,editor.lines)
        push!(rows,session_display_blank(width))
        append!(rows,session_display_text_rows("enter submit  shift+enter/ctrl+j newline  escape/ctrl+c cancel",width,1;style=session_display_style(:muted)))
    elseif control.stage==:working
        append!(rows,session_display_text_rows("Preparing local bug report…",width,1;style=session_display_style(:accent)))
        append!(rows,session_display_text_rows("Escape cancels the active operation. No upload is performed.",width,1;style=session_display_style(:muted)))
    else
        page=bug_report_choices(control)
        append!(rows,session_display_text_rows(page.title,width,1;style=session_display_style(:accent;bold=true)))
        if !isempty(page.description)
            push!(rows,session_display_blank(width))
            append!(rows,session_display_text_rows(page.description,width,1;style=session_display_style(:text)))
        end
        push!(rows,session_display_blank(width))
        for (index,choice) in enumerate(page.choices)
            append!(rows,session_display_text_rows((index==control.selected ? "→ " : "  ")*choice,width,1;style=session_display_style(index==control.selected ? :accent : :text)))
        end
        push!(rows,session_display_blank(width))
        append!(rows,session_display_text_rows("↑↓ navigate  enter select  escape/ctrl+c cancel",width,1;style=session_display_style(:muted)))
    end
    push!(rows,session_display_blank(width),border)
    (;lines=rows,cursor_row,cursor_col)
end
bug_report_rows(control::BugReportControl,width::Int,height::Int;kwargs...)=bug_report_view(control,width,height;kwargs...).lines

struct BugReportExportResult
    owner::String
    control::BugReportControl
    path::String
    sha256::String
    report_id::String
    issue_draft::Bool
end

function bug_report_export!(app::App,control::BugReportControl;issue_draft=false)
    timeline=app.archive.timeline
    if isnothing(timeline)
        bug_report_close!(app,"No active session archive")
    elseif control.owner!=timeline.identity.id
        bug_report_close!(app,"Bug report belongs to a different session")
    else
        bug_report_export_captured!(app,control,timeline;issue_draft)
    end
    nothing
end

function bug_report_export_captured!(app::App,control::BugReportControl,timeline::JuliaForever2.SessionTimeline;issue_draft=false)
    session=app.session
    store=app.archive.store
    transcript=control.transcript ? JuliaForever2.timeline_export_jsonl(timeline) : nothing
    messages=control.summary ? copy(history_snapshot(app.session).messages) : Message[]
    control.stage=:working
    directory=working_directory(app.session)
    handle=JuliaForever2.submit_managed!(app.session,app.session,ui_context(app)) do context
        summary=if control.summary
            result=JuliaForever2.model_summary!(session,nothing,messages,context,"Describe a reproducible software bug only. Include expected/actual behavior and relevant errors. User description: "*control.description)
            isempty(strip(result)) && error("The configured provider returned no bug summary")
            result
        else
            nothing
        end
        cancelled(context) && error("Bug report cancelled before export")
        report=JuliaForever2.local_bug_report(control.description;provider=control.provider,model=control.model,transcript,summary)
        path=joinpath(directory,"julia-forever-bug-"*report.id*(issue_draft ? "-issue.zip" : ".zip"))
        if issue_draft
            text="# Julia Forever 2 issue draft\n\n"*control.description*"\n\n"*(isnothing(summary) ? "" : "## Generated summary\n\n"*summary*"\n\n")*"Review and submit manually: "*JuliaForever2.JF2_ISSUE_PAGE*"\n\nNo report has been uploaded. Review every attachment before posting; the optional transcript remains inside this private ZIP.\n"
            files=[report.files;["issue.md"=>JuliaForever2.bug_report_bytes(text)]]
            report=JuliaForever2.LocalBugReport(report.id,report.created_at,files,report.transcript_included,report.summary_included)
        end
        exported=JuliaForever2.export_bug_report!(report,path)
        receipt=Task() do
            lock(session.runtime.execution_lock) do
                JuliaForever2.timeline_append_custom!(timeline,"JuliaForever2.bug-report",Dict("id"=>report.id,"createdAt"=>report.created_at,
                    "path"=>path,"sha256"=>exported.sha256,"transcriptIncluded"=>report.transcript_included,"summaryIncluded"=>report.summary_included,
                    "delivery"=>(issue_draft ? "local-issue-draft" : "local-zip"),"published"=>false))
                JuliaForever2.save_timeline!(store,timeline)
            end
        end
        schedule(receipt);wait(receipt;throw=false)
        receipt_status=istaskfailed(receipt) ? " (export verified, but session receipt was not saved)" : ""
        status="Bug report "*(issue_draft ? "draft saved locally" : "exported")*": "*path*(cancelled(context) ? " (completed before cancellation took effect)" : "")*receipt_status
        JuliaForever2.ExecutionResult(true,status,BugReportExportResult(control.owner,control,path,exported.sha256,report.id,issue_draft))
    end
    track_operation!(app,handle,:bug_report_done,control.summary ? "Generating explicitly requested bug summary…" : "Exporting local bug report…")
    nothing
end

function bug_report_choose!(app::App,control::BugReportControl)
    if control.stage==:transcript
        control.transcript=control.selected==1
        control.stage=control.transcript ? :delivery : :summary
        control.selected=1
    elseif control.stage==:summary
        control.summary=control.selected==1
        control.stage=:delivery
        control.selected=1
    elseif control.stage==:delivery
        if control.selected==3
            bug_report_close!(app)
        else
            bug_report_export!(app,control;issue_draft=control.selected==2)
        end
    end
    nothing
end

function bug_report_input!(app::App,packet::AbstractString)
    control=app.menus.bug_report
    if isnothing(control)
        app.page=:chat
    elseif packet in ("\e","\x03")
        if control.stage==:working
            active=app.operations.active
            isnothing(active) || cancel!(active)
        else
            bug_report_close!(app)
        end
    elseif control.stage==:description
        result=chat_editor_input!(control.editor,packet)
        if result.action==:submit
            control.description=String(strip(result.text))
            control.stage=:transcript
            control.selected=1
        end
    elseif control.stage!=:working
        choices=bug_report_choices(control).choices
        if packet in ("\e[A","k")
            control.selected=max(1,control.selected-1)
        elseif packet in ("\e[B","j")
            control.selected=min(length(choices),control.selected+1)
        elseif packet in ("\r","\n")
            bug_report_choose!(app,control)
        end
    end
    nothing
end

function bug_report_finished!(app::App,handle::TaskHandle)
    if app.operations.active===handle
        app.operations.active=nothing;app.operations.active_kind=:none;app.busy=false
        result=session_action_result(handle)
        exported=result.value
        timeline=app.archive.timeline
        if result.ok && exported isa BugReportExportResult && app.menus.bug_report===exported.control &&
                !isnothing(timeline) && timeline.identity.id==exported.owner && !app.operations.closing[]
            bug_report_close!(app,result.text)
            append_command_document!(app,"Bug report exported","Saved locally: `"*exported.path*"`\n\nSHA-256: `"*exported.sha256*"`\n\nNothing has been uploaded or submitted. Review before sharing at "*JuliaForever2.JF2_ISSUE_PAGE)
            app.status=result.text
        else
            bug_report_close!(app,result.ok ? "Bug report result belongs to a different session" : result.text)
        end
    end
    nothing
end

page_input!(app::App,::Val{:bug_report},event::KeyEvent,raw::AbstractVector{UInt8})=bug_report_input!(app,menu_packet(event,raw))
function page_view!(app::App,::Val{:bug_report},frame::Frame)
    control=app.menus.bug_report
    if !isnothing(control)
        editor=bug_report_view(control,frame.area.width,frame.area.height;runtime=app.menus.theme_runtime)
        startup_host_view!(app,frame;editor)
    end
    nothing
end
