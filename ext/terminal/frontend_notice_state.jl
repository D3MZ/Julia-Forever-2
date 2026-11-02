# Pi status presentation interoperability: MIT, licenses/pi-LICENSE.
# Notices are frontend-owned and never enter conversation context or the journal.
Base.@kwdef struct FrontendNotice
    anchor::Union{Nothing,String} = nothing
    message::String
    preceding_documents::Int = 0
    operation::UInt64 = UInt64(0)
    kind::Symbol = :notice
end
FrontendNotice(anchor,message,preceding_documents,operation)=FrontendNotice(anchor,message,preceding_documents,operation,:notice)
Base.@kwdef mutable struct FrontendNoticeState
    owner::Union{Nothing,String} = nothing
    notices::Vector{FrontendNotice} = FrontendNotice[]
    revision::UInt = UInt(0)
end

function frontend_notice_owner!(state::FrontendNoticeState,id::String)
    if state.owner!=id
        state.owner=id
        empty!(state.notices)
        state.revision+=UInt(1)
    end
    state
end

"""Coalesce only the last display component, never across a new message or command document."""
function frontend_notice!(state::FrontendNoticeState,id::String,anchor,message::AbstractString;documents::Int=0,operation::UInt64=UInt64(0),kind::Symbol=:notice)
    frontend_notice_owner!(state,id)
    notice=FrontendNotice(;anchor,message=String(message),preceding_documents=documents,operation,kind)
    previous=isempty(state.notices) ? nothing : last(state.notices)
    if kind==:notice && !isnothing(previous) && previous.kind==:notice && previous.anchor==anchor && previous.preceding_documents==documents && previous.operation==operation
        state.notices[end]=notice
    else
        push!(state.notices,notice)
    end
    state.revision+=UInt(1)
    nothing
end
