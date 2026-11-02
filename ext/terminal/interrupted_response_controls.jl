const INTERRUPTED_RESPONSE_TYPE="jf2.interrupted-response"
const INTERRUPTED_RESPONSE_FORMAT="JuliaForever2.interrupted-response.v1"

function preview_ownership(app::App,operation::UInt64)
    timeline=app.archive.timeline
    if isnothing(timeline) || app.operations.active_kind!=:turn
        nothing
    else
        lock(timeline.lock) do
            PreviewOwnership(string(app.session.runtime.id),timeline.identity.id,timeline.leaf,operation)
        end
    end
end

function preview_owned(app::App,owner::PreviewOwnership)
    timeline=app.archive.timeline
    handle=app.operations.active
    !isnothing(timeline) && !isnothing(handle) && owner.runtime==string(app.session.runtime.id) &&
        owner.timeline==timeline.identity.id && owner.operation==operation_id(handle.context)
end
preview_owned(app::App,::Nothing)=false

function remember_preview_ownership!(app::App,operation::UInt64)
    owner=app.transcript.preview_owner
    if isnothing(owner) || owner.operation!=operation
        app.transcript.preview_owner=preview_ownership(app,operation)
    end
    nothing
end

"""Retain only decoded answer text; partial JSON and executable code never enter this display record."""
function capture_interrupted_preview!(app::App,stop::Symbol)
    preview=app.transcript.preview
    owner=app.transcript.preview_owner
    if !isnothing(preview) && preview.kind==:answer && !isempty(strip(preview.text)) &&
            owner isa PreviewOwnership && preview_owned(app,owner) && stop in (:aborted,:error)
        rows=app.transcript.interrupted_responses
        exists=any(row->row.owner==owner,rows)
        exists || push!(rows,InterruptedResponseView(;owner,text=preview.text,stop))
        app.transcript.display_key=nothing
    end
    nothing
end

function capture_cancelled_preview!(app::App)
    handle=app.operations.active
    if !isnothing(handle) && cancelled(handle.context)
        capture_interrupted_preview!(app,:aborted)
    end
    nothing
end

interrupted_error(::Val{:aborted})="Operation aborted"
interrupted_error(::Val)="Response interrupted before completion"
function interrupted_message(text::String,stop::Symbol)
    Dict{String,Any}("role"=>"assistant","content"=>[Dict("type"=>"text","text"=>text)],
        "stopReason"=>String(stop),"errorMessage"=>interrupted_error(Val(stop)))
end
function interrupted_response_data(record::InterruptedResponseView)
    owner=record.owner
    Dict{String,Any}("format"=>INTERRUPTED_RESPONSE_FORMAT,"kind"=>"answer","text"=>record.text,
        "stopReason"=>String(record.stop),"runtimeId"=>owner.runtime,"timelineId"=>owner.timeline,
        "afterEntryId"=>owner.anchor,"operationId"=>string(owner.operation),"previewId"=>owner.token)
end
function interrupted_entry_data(entry)
    data=entry isa AbstractDict && isequal(get(entry,"type",nothing),"custom") &&
        isequal(get(entry,"customType",nothing),INTERRUPTED_RESPONSE_TYPE) ? get(entry,"data",nothing) : nothing
    valid=data isa AbstractDict && isequal(get(data,"format",nothing),INTERRUPTED_RESPONSE_FORMAT) &&
        isequal(get(data,"kind",nothing),"answer") && get(data,"text",nothing) isa String &&
        sizeof(data["text"])<=32*1024*1024 && get(data,"stopReason",nothing) isa String && get(data,"stopReason",nothing) in ("aborted","error")
    valid ? data : nothing
end
is_interrupted_response_entry(entry)=!isnothing(interrupted_entry_data(entry))
function interrupted_display_message(entry)
    data=interrupted_entry_data(entry)
    isnothing(data) ? nothing : interrupted_message(data["text"]::String,Symbol(data["stopReason"]::String))
end
function interrupted_response_rows(entry,width::Int,state::SessionDisplayState)
    message=interrupted_display_message(entry)
    isnothing(message) ? SessionDisplayRows() : session_display_assistant(message,width,state)
end

function interrupted_record_matches(entry,record::InterruptedResponseView)
    data=interrupted_entry_data(entry)
    owner=record.owner
    !isnothing(data) && isequal(get(data,"runtimeId",nothing),owner.runtime) && isequal(get(data,"timelineId",nothing),owner.timeline) &&
        isequal(get(data,"afterEntryId",nothing),owner.anchor) && isequal(get(data,"operationId",nothing),string(owner.operation)) && isequal(get(data,"previewId",nothing),owner.token)
end

"""Append through the existing durable journal only after ownership and branch checks under its lock."""
function archive_interrupted_response!(timeline::JuliaForever2.SessionTimeline,record::InterruptedResponseView)
    lock(timeline.lock) do
        path=JuliaForever2.timeline_branch(timeline)
        anchor=findfirst(entry->isequal(get(entry,"id",nothing),record.owner.anchor),path)
        duplicate=any(entry->interrupted_record_matches(entry,record),timeline.entries)
        later_message=!isnothing(anchor) && any(entry->isequal(get(entry,"type",nothing),"message"),path[anchor+1:end])
        if duplicate
            :saved
        elseif isnothing(timeline.path) || timeline.identity.id!=record.owner.timeline || isnothing(anchor) || later_message
            :stale
        else
            JuliaForever2.timeline_append_custom!(timeline,INTERRUPTED_RESPONSE_TYPE,interrupted_response_data(record))
            :saved
        end
    end
end

"""Persist finalized failures exactly once without changing runtime messages or claiming a successful answer."""
function finalize_interrupted_responses!(app::App,handle::TaskHandle)
    failed=false
    timeline=app.archive.timeline
    if !isnothing(timeline) && app.operations.active===handle && istaskdone(handle.task)
        for record in app.transcript.interrupted_responses
            if !record.attempted && preview_owned(app,record.owner)
                record.attempted=true
                task=Task(()->archive_interrupted_response!(timeline,record))
                schedule(task);wait(task;throw=false)
                result=istaskfailed(task) ? :failed : fetch(task)::Symbol
                record.saved=result==:saved
                record.discarded=result==:stale
                failed|=result==:failed
            end
        end
        filter!(record->!record.saved && !record.discarded,app.transcript.interrupted_responses)
        app.transcript.display_key=nothing
    end
    failed
end

"""Use the rendered archive snapshot, not a racing live read or a same-text heuristic."""
function interrupted_anchor_current(projection::JuliaForever2.TimelineDisplayProjection,owner::PreviewOwnership)
    path=projection.entries
    anchor=findfirst(entry->isequal(get(entry,"id",nothing),owner.anchor),path)
    !isnothing(anchor) && !any(entry->isequal(get(entry,"type",nothing),"message"),path[anchor+1:end])
end
interrupted_anchor_current(::Nothing,owner::PreviewOwnership)=false
interrupted_fallback_projection(app::App)=interrupted_fallback_projection(app.archive.timeline)
interrupted_fallback_projection(::Nothing)=nothing
interrupted_fallback_projection(timeline::JuliaForever2.SessionTimeline)=JuliaForever2.timeline_display_projection(timeline)

function interrupted_fallback_rows(app::App,id::String,anchor,width::Int;projection=interrupted_fallback_projection(app),on_component=nothing)
    rows=SessionDisplayRows()
    runtime=string(app.session.runtime.id)
    for record in app.transcript.interrupted_responses
        owner=record.owner
        if !record.saved && owner.timeline==id && owner.runtime==runtime && isequal(owner.anchor,anchor) && interrupted_anchor_current(projection,owner)
            message=interrupted_message(record.text,record.stop)
            rendered=session_display_assistant(message,width,app.transcript.display)
            isnothing(on_component) || on_component(:assistant,message,length(rows),length(rendered))
            append!(rows,rendered)
        end
    end
    rows
end
