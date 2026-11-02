"""Render dim, padded notices with safe native text and one preceding spacer."""
function frontend_notice_rows(notice::FrontendNotice,width::Int)
    rows=SessionDisplayRows([session_display_blank(width)])
    text=(notice.kind==:warning ? "Warning: " : "")*notice.message
    rich=startup_rich(join(startup_safe_text.(split(text,'\n';keepempty=true)),"\n"),session_display_style(notice.kind==:warning ? :warning : :dim))
    append!(rows,startup_text_lines(rich,width;padding=1))
    rows
end

function frontend_command_count(app::App)
    timeline=app.archive.timeline
    if hasproperty(app.transcript,:documents) && !isnothing(timeline) && app.transcript.documents.owner==timeline.identity.id
        length(app.transcript.documents.documents)
    else
        0
    end
end

"""Snapshot only the visible archive anchor; no provider history is mutated."""
function frontend_notice_snapshot(app::App)
    timeline=app.archive.timeline
    if isnothing(timeline)
        nothing
    else
        lock(timeline.lock) do
            projection=JuliaForever2.timeline_display_projection(timeline)
            anchor=isempty(projection.items) ? nothing : last(projection.items).source_entry_id
            (;id=timeline.identity.id,anchor)
        end
    end
end

function frontend_notice!(app::App,message::AbstractString;kind::Symbol=:notice)
    snapshot=frontend_notice_snapshot(app)
    if !isnothing(snapshot)
        operation=isnothing(app.transcript.preview) ? UInt64(0) : app.transcript.preview_operation_id
        frontend_notice!(app.transcript.notices,snapshot.id,snapshot.anchor,message;documents=frontend_command_count(app),operation,kind)
        app.transcript.display_key=nothing
        app.scroll=0
    end
    nothing
end

"""Interleave ephemeral notices with existing command documents using their real insertion order."""
function frontend_after_record_rows(app::App,id::String,anchor,width::Int;projection=interrupted_fallback_projection(app),on_component=nothing)
    state=app.transcript.notices
    documents=hasproperty(app.transcript,:documents) ? app.transcript.documents : nothing
    count=isnothing(documents) || documents.owner!=id ? 0 : length(documents.documents)
    rows=interrupted_fallback_rows(app,id,anchor,width;projection,on_component)
    for index in 0:count
        if index>0 && !isnothing(documents)
            document=documents.documents[index]
            isequal(document.anchor,anchor) && append!(rows,command_document_rows(document,width))
        end
        if state.owner==id
            for notice in state.notices
                if notice.operation==0 && isequal(notice.anchor,anchor) && notice.preceding_documents==index
                    append!(rows,frontend_notice_rows(notice,width))
                end
            end
        end
    end
    rows
end

"""Keep notices emitted after a live assistant below that component until it is archived."""
function frontend_preview_notice_rows(app::App,width::Int)
    state=app.transcript.notices
    rows=SessionDisplayRows()
    timeline=app.archive.timeline
    if !isnothing(timeline) && state.owner==timeline.identity.id
        for notice in state.notices
            if notice.operation!=0 && notice.operation==app.transcript.preview_operation_id
                append!(rows,frontend_notice_rows(notice,width))
            end
        end
    end
    rows
end

function frontend_notice_commit_preview!(app::App)
    snapshot=frontend_notice_snapshot(app)
    state=app.transcript.notices
    if !isnothing(snapshot) && state.owner==snapshot.id
        changed=false
        for (index,notice) in enumerate(state.notices)
            if notice.operation!=0 && notice.operation==app.transcript.preview_operation_id
                state.notices[index]=FrontendNotice(;anchor=snapshot.anchor,message=notice.message,preceding_documents=notice.preceding_documents,kind=notice.kind)
                changed=true
            end
        end
        if changed
            state.revision+=UInt(1)
            app.transcript.display_key=nothing
        end
    end
    nothing
end

function clear_frontend_notices!(app::App)
    empty!(app.transcript.notices.notices)
    app.transcript.notices.revision+=UInt(1)
    app.transcript.display_key=nothing
    nothing
end
