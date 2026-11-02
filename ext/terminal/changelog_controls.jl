struct ChangelogCommandResult
    owner::String
    markdown::String
    status::String
end

function release_changelog_markdown(snapshot::JuliaForever2.ReleaseChangelog)
    content=if isempty(snapshot.entries)
        "No changelog entries found."
    else
        join(["## "*replace(session_display_safe(note.title),'\n'=>" ")*"\n\n"*session_display_safe(note.body)*"\n\n"*"Published: "*session_display_safe(note.published_at)*"\n\n"*note.url for note in reverse(snapshot.entries)],"\n\n")
    end
    content*"\n\nSource: "*snapshot.source*"\nChecked: "*snapshot.checked_at*"\n\nUse `/changelog refresh` to explicitly refresh public GitHub releases."
end

"""Read cached public notes, or fetch only when the user explicitly invokes /changelog refresh."""
function changelog_command!(app::App,arguments::AbstractString;transport=JuliaForever2.public_release_transport)
    option=strip(arguments)
    if !(option in ("","refresh"))
        app.status="Use /changelog or /changelog refresh"
    elseif app.busy || app.operations.closing[]
        app.status="Finish or cancel the active operation first."
    else
        owner=app.archive.timeline.identity.id
        path=joinpath(app.settings.directory,"release-changelog.json")
        handle=JuliaForever2.submit_managed!(app.session,app.session,ui_context(app)) do context
            cache=JuliaForever2.read_release_changelog_state(path)
            existing=cache.snapshot
            expected=cache.digest
            if option=="refresh"
                snapshot=JuliaForever2.fetch_release_changelog(context;policy=JuliaForever2.ReleaseFetchPolicy(;allow_network=true),transport)
                cancelled(context) && error("Release retrieval cancelled before saving")
                mkpath(dirname(path))
                JuliaForever2.save_release_changelog!(path,snapshot;expected)
                saved=JuliaForever2.read_release_changelog(path)
                isnothing(saved) && error("Release cache readback failed")
                status=cancelled(context) ? "Public release cache saved before cancellation took effect" : "Public release cache refreshed"
                JuliaForever2.ExecutionResult(true,status,ChangelogCommandResult(owner,release_changelog_markdown(saved),status))
            else
                markdown=isnothing(existing) ? "No bundled changelog or cached public release notes are available.\n\nUse `/changelog refresh` to fetch public releases from "*JuliaForever2.JF2_RELEASES_PAGE*". This sends no credentials or session data." : release_changelog_markdown(existing)
                JuliaForever2.ExecutionResult(true,"",ChangelogCommandResult(owner,markdown,""))
            end
        end
        track_operation!(app,handle,:changelog_done,option=="refresh" ? "Fetching public release notes…" : "Reading release notes…")
    end
    nothing
end

function changelog_finished!(app::App,handle::TaskHandle)
    if app.operations.active===handle
        previous_ids=app.operations.pending_start_ids
        was_continuation=app.operations.pending_continuation
        app.operations.pending_start_ids=UInt64[]
        app.operations.pending_continuation=false
        app.operations.active=nothing
        app.operations.active_kind=:none
        app.busy=false
        result=session_action_result(handle)
        if result.ok && result.value isa ChangelogCommandResult && !app.operations.closing[] &&
                !isnothing(app.archive.timeline) && result.value.owner==app.archive.timeline.identity.id
            append_command_document!(app,"What's New",result.value.markdown)
            app.status=result.value.status
            continue_terminal_pending!(app,result,:changelog_done,previous_ids,was_continuation)
        else
            app.status=result.ok ? "Release notes belong to a different session" : result.text
        end
    end
    nothing
end
