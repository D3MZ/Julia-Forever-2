const ANTHROPIC_EXTRA_USAGE_NOTICE="An Anthropic subscription-style credential is configured. Third-party use may draw from separately billed usage credits, not your Claude plan limits. This warning does not verify access or billing. Check https://claude.ai/settings/usage. Disable this warning in /settings."

"""Run bounded optional notice reads without propagating lookup exceptions or private values into UI errors."""
function notice_attempt(operation)
    task=Task(operation);schedule(task);wait(task;throw=false)
    if istaskfailed(task)
        errors=Base.current_exceptions(task)
        (ok=false,value=nothing,reason=isempty(errors) ? "Notice state unavailable" : sprint(showerror,last(errors).exception))
    else
        (ok=true,value=fetch(task),reason="")
    end
end

"""Warn once for the selected Anthropic subscription fact only; all unrelated safety/error notices remain untouched."""
function maybe_warn_anthropic_subscription!(app::App)
    controls=app.menus.startup
    if !isnothing(controls) && !controls.anthropic_warning_shown && menu_preference(app,"anthropic-extra-usage","true")!="false" && !app.operations.closing[]
        outcome=notice_attempt() do
            with_component(app.session.kernel,:provider;fallback=false) do provider
                facts=JuliaForever2.provider_warning_facts(provider)
                get(facts,:anthropic_subscription,false)===true
            end
        end
        if outcome.ok && outcome.value===true
            frontend_notice!(app,ANTHROPIC_EXTRA_USAGE_NOTICE;kind=:warning)
            controls.anthropic_warning_shown=true
        end
    end
    nothing
end

"""Load genuine local update notes only; never fetch releases or send install telemetry during startup."""
function initialize_notice_settings!(app::App;installed::VersionNumber=pkgversion(JuliaForever2))
    controls=app.menus.startup
    if !isnothing(controls)
        if isempty(JuliaForever2.history_snapshot(app.session).messages)
            outcome=notice_attempt() do
                path=joinpath(app.settings.directory,"startup-release.json")
                previous=JuliaForever2.startup_release_state(path)
                notice=StartupUpdateNotice(;acknowledgement_path=path,expected=previous.digest,installed)
                if isnothing(previous.version)
                    notice.pending=true
                elseif previous.version<installed
                    snapshot=JuliaForever2.read_release_changelog(joinpath(app.settings.directory,"release-changelog.json"))
                    notes=JuliaForever2.startup_release_notes(snapshot,previous.version,installed)
                    if !isempty(notes)
                        notice.markdown=join(["## "*note.tag*"\n\n"*note.body for note in notes],"\n\n")
                        notice.version=string(JuliaForever2.startup_release_version(first(notes).tag))
                        notice.collapsed=menu_preference(app,"collapse-changelog","false")=="true"
                        notice.pending=true
                    end
                end
                notice
            end
            if outcome.ok
                controls.document.update=outcome.value
            else
                startup_status!(controls.document,"Local release notes unavailable: "*outcome.reason;kind=:warning)
            end
        end
    end
    nothing
end

"""Acknowledge only after an actual attached-terminal frame, with CAS and separate readback; failures stay visible."""
function acknowledge_notice_frame!(app::App)
    controls=app.menus.startup
    terminal=app.settings.terminal
    if !isnothing(controls) && !isnothing(terminal) && !app.operations.closing[] && !app.settings.presentation.leased
        notice=controls.document.update
        if !isnothing(notice) && notice.pending
            notice.pending=false
            outcome=notice_attempt(()->JuliaForever2.acknowledge_startup_release!(notice.acknowledgement_path,notice.installed,notice.expected))
            if !outcome.ok
                startup_status!(controls.document,"Could not acknowledge local release notes: "*outcome.reason;kind=:warning)
            end
        end
    end
    nothing
end

"""Render source-faithful condensed/full startup notices; explicit /changelog is a separate full-document action."""
startup_update_rows(::Nothing,runtime,width::Int)=SessionDisplayRows()
function startup_update_rows(notice::StartupUpdateNotice,runtime,width::Int)
    rows=SessionDisplayRows()
    if !isempty(notice.markdown)
        border=[Tachikoma.Span(repeat("─",width),startup_style(runtime,:border))]
        push!(rows,border)
        if notice.collapsed
            spans=[Tachikoma.Span("Updated to v"*notice.version*". Use ",Tachikoma.Style()),Tachikoma.Span("/changelog",Tachikoma.Style(;bold=true)),Tachikoma.Span(" to view full changelog.",Tachikoma.Style())]
            append!(rows,session_display_wrap(spans,width,1))
        else
            append!(rows,session_display_text_rows("What's New",width,1;style=theme_notice_heading(runtime)))
            push!(rows,session_display_blank(width))
            append!(rows,session_display_markdown(strip(notice.markdown),width,1))
            push!(rows,session_display_blank(width))
        end
        push!(rows,border)
    end
    rows
end
theme_notice_heading(::Nothing)=session_display_style(:accent;bold=true)
theme_notice_heading(runtime)=theme_token_style(runtime,"accent";bold=true)
# These settings govern future source-defined notice triggers, not retroactive removal of displayed warnings.
apply_setting_effect!(app::App,::Val{Symbol("collapse-changelog")},value::AbstractString)=nothing
apply_setting_effect!(app::App,::Val{Symbol("anthropic-extra-usage")},value::AbstractString)=nothing
