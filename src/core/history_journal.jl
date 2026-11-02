"""Keep pure-memory observer references live by reachability; this service owns no external resources."""
Base.@kwdef mutable struct HistoryJournals
    lock::ReentrantLock = ReentrantLock()
    observers::Dict{UUID,Any} = Dict{UUID,Any}()
end

function journal_history!(journal::HistoryJournals, session::Session, operation::Symbol, arguments...)
    Base.invokelatest(journal, session, operation, arguments...)
    nothing
end

function (journals::HistoryJournals)(session::Session, operation::Symbol, arguments...)
    observer = lock(journals.lock) do
        get(journals.observers, session.runtime.id, nothing)
    end
    notify_history_journal(observer, session, operation, arguments...)
end

notify_history_journal(::Nothing, session, operation, arguments...) = nothing
notify_history_journal(observer, session, operation, arguments...) =
    Base.invokelatest(observer, session, operation, arguments...)

"""Attach one archive to one session identity while preserving other sessions on its kernel."""
function bind_history_journal!(session::Session, observer)
    journals = component(session.kernel, :history_journals)
    if isnothing(journals)
        candidate = HistoryJournals()
        install!(session.kernel, ComponentSpec(:history_journals, candidate); expected_entry=nothing)
        journals = component(session.kernel, :history_journals)
    end
    if !(journals isa HistoryJournals)
        error("The history journal service has an incompatible implementation")
    end
    lock(journals.lock) do
        if haskey(journals.observers, session.runtime.id)
            error("This session already has a history journal")
        end
        journals.observers[session.runtime.id] = observer
    end
    observer
end

"""Remove only the retiring session's archive binding."""
unbind_history_journal!(::Any, ::UUID) = nothing
function unbind_history_journal!(journals::HistoryJournals, id::UUID)
    lock(journals.lock) do
        delete!(journals.observers, id)
    end
    nothing
end
unbind_history_journal!(session::Session) = unbind_history_journal!(component(session.kernel, :history_journals), session.runtime.id)

"""Optionally supply an archive-owned model context without changing legacy session history."""
history_journal_context(observer, session::Session) = nothing
function history_journal_context(journals::HistoryJournals, session::Session)
    observer = lock(journals.lock) do
        get(journals.observers, session.runtime.id, nothing)
    end
    Base.invokelatest(history_journal_context, observer, session)
end
