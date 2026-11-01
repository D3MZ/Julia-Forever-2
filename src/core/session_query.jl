"""A composable query service over live or durable Julia session history."""
struct SessionQuery{S}
    source::S
end

"""Publish session history queries through a replaceable, plugin-owned service."""
function session_query_plugin(; name=:session_query, store_service=:session_store,
        service_name=:session_query, factory=SessionQuery, indexed=true)
    dependency = Symbol(store_service)
    contract = Symbol(service_name)
    setup = context -> provide!(context, contract,
        Base.invokelatest(factory, indexed ? SessionSearchIndex(service(context, dependency)) :
            service(context, dependency)))
    return PluginSpec(name, setup; requires=[dependency], provides=[contract])
end

"""Enumerate saved session identifiers without restoring or executing sessions."""
function session_names(store::SessionStore)
    files = isdir(store.directory) ? readdir(store.directory) : String[]
    names = String[chop(file; tail=5) for file in files if endswith(file, ".json")]
    sort!(filter(name -> is_saved_profile_file(session_file(store, name)), names))
end
const SessionSearchHit = NamedTuple{(:session, :index, :role, :kind, :content),
    Tuple{Union{Nothing,String},Int,Symbol,Symbol,String}}

struct SearchWindow{F,T}
    first::F
    last::T

    function SearchWindow(first::F, last::T) where {F,T}
        if !(validindex(first) && validindex(last))
            error("Session query indices must be positive integers")
        elseif !isnothing(first) && !isnothing(last) && first > last
            error("Session query lower index exceeds upper index")
        else
            new{F,T}(first, last)
        end
    end
end

validindex(::Nothing) = true
validindex(value) = false
validindex(value::Integer) = value >= 1
validindex(::Bool) = false
selected(index, window::SearchWindow) = (isnothing(window.first) || index >= window.first) && (isnothing(window.last) || index <= window.last)
session_index_selected(index, first, last) = selected(index, SearchWindow(first, last))
session_search_window(first, last) = (SearchWindow(first, last); nothing)
session_name_selection(names) = isnothing(names) ? nothing : Set(String.(names))

struct HistoryQuery{R,L<:Integer,S,W}
    pattern::Regex
    text::String
    roles::R
    limit::L
    sessions::S
    window::W

    function HistoryQuery(text::String, roles::R, limit::L, sessions::S, window::W) where {R,L<:Integer,S,W<:SearchWindow}
        validate(HistoryQuery, text, limit)
        new{R,L,S,W}(pattern(text), text, roles, limit, sessions, window)
    end
end

HistoryQuery(text::AbstractString; roles=nothing, limit::Integer=typemax(Int), sessions=nothing, from_index=nothing, to_index=nothing) = HistoryQuery(String(text), isnothing(roles) ? nothing : Set(Symbol.(roles)), limit, session_name_selection(sessions), SearchWindow(from_index, to_index))
HistoryQuery(text::String, roles, limit::Integer) = HistoryQuery(text, roles, limit, nothing, SearchWindow(nothing, nothing))
session_query_pattern(text::AbstractString) = HistoryQuery(text).pattern
selected(name, query::HistoryQuery) = isnothing(query.sessions) || name in query.sessions

function validate(::Type{HistoryQuery}, text, limit)
    if limit < 0
        error("Session query limit must be nonnegative")
    elseif isempty(strip(text))
        error("Session query must contain non-whitespace text")
    end
    nothing
end

validate(::Type{HistoryQuery}, text, ::Bool) = error("Session query limit must be a non-Boolean integer")

function pattern(text::String)
    stripped = strip(String(text))
    pattern = IOBuffer()
    for (index, token) in enumerate(split(stripped, r"\s+"))
        index == 1 || print(pattern, "\\s+")
        for character in token
            if character in ('\\', '.', '*', '+', '?', '^', '$', '{', '}', '(', ')', '|', '[', ']')
                print(pattern, '\\')
            end
            print(pattern, character)
        end
    end
    return Regex(String(take!(pattern)), "i")
end

function append_session_matches!(hits::Vector{SessionSearchHit}, messages, identity, pattern::Regex, allowed_roles, limit::Integer, from_index=nothing, to_index=nothing)
    window = SearchWindow(from_index, to_index)
    candidates = Iterators.takewhile(item -> length(hits) < limit, enumerate(messages))
    for (index, message) in candidates
        if selected(index, window) && matches(message, pattern, allowed_roles)
            push!(hits, SessionSearchHit((identity, index, message.role, message.kind, message.content)))
        end
    end
    hits
end

matches(message, pattern::Regex, roles) = (isnothing(roles) || message.role in roles) && occursin(pattern, message.content)
matches(hit, query::HistoryQuery) = selected(hit.session, query) && selected(hit.index, query.window) && matches(hit, query.pattern, query.roles)
appendmatches!(hits, ::Nothing, identity, query::HistoryQuery) = hits
appendmatches!(hits, record, identity, query::HistoryQuery) = append_session_matches!(hits, record.messages, identity, query.pattern, query.roles, query.limit, query.window.first, query.window.last)
"""Search a detached snapshot of a live session without changing its conversation."""
search_history(session::Session, text::AbstractString; roles=nothing, limit::Integer=typemax(Int), from_index=nothing, to_index=nothing) = search(session, HistoryQuery(text; roles, limit, from_index, to_index))
search(session::Session, query::HistoryQuery) = appendmatches!(SessionSearchHit[], history_snapshot(session), nothing, query)

"""Search stored sessions in deterministic name/message order without activating agents."""
search_history(store::SessionStore, text::AbstractString; roles=nothing, limit::Integer=typemax(Int), sessions=nothing, from_index=nothing, to_index=nothing) = search(store, HistoryQuery(text; roles, limit, sessions, from_index, to_index))

function search(store::SessionStore, query::HistoryQuery)
    hits = SessionSearchHit[]
    for name in Iterators.takewhile(name -> length(hits) < query.limit, Iterators.filter(name -> selected(name, query), session_names(store)))
        appendmatches!(hits, saved_session_record(store, name), name, query)
    end
    hits
end

search_history(query::SessionQuery, text::AbstractString; kwargs...) = search_history(query.source, text; kwargs...)


"""A revision-aware in-memory trigram index over durable Julia session messages."""
mutable struct SessionSearchIndex
    store::SessionStore
    lock::ReentrantLock
    revision::UInt64
    documents::Vector{SessionSearchHit}
    postings::Dict{String,BitSet}
    unicode_documents::BitSet
end

"""Form Unicode-character trigrams; indexed pruning applies only to ASCII documents."""
function session_trigrams(text::AbstractString)
    characters = collect(lowercase(String(text)))
    return [string(characters[index], characters[index + 1], characters[index + 2])
        for index in 1:max(0, length(characters) - 2)]
end

"""Index ASCII trigrams without per-gram copied strings and a transient deduplication Set."""
function append_ascii_session_postings!(postings::Dict{String,BitSet}, text::String, document_id::Int)
    lowercase_text = lowercase(text)
    for offset in 1:max(0, ncodeunits(lowercase_text) - 2)
        gram = SubString(lowercase_text, offset, offset + 2)
        push!(get!(BitSet, postings, gram), document_id)
    end
    return nothing
end

function SessionSearchIndex(store::SessionStore)
    index = SessionSearchIndex(store, ReentrantLock(), typemax(UInt64),
        SessionSearchHit[], Dict{String,BitSet}(), BitSet())
    refresh_index!(index)
    return index
end

"""Rebuild index snapshots explicitly after changes made outside this SessionStore instance."""
function refresh_index!(index::SessionSearchIndex)
    lock(index.lock) do
        lock(index.store.lock) do
            documents = SessionSearchHit[]
            postings = Dict{String,BitSet}()
            unicode = BitSet()
            for name in session_names(index.store)
                index!(documents, postings, unicode, saved_session_record(index.store, name), name)
            end
            index.documents = documents
            index.postings = postings
            index.unicode_documents = unicode
            index.revision = index.store.revision
        end
        index
    end
end

index!(documents, postings, unicode, ::Nothing, name) = documents

function index!(documents, postings, unicode, record, name)
    for (position, message) in enumerate(record.messages)
        push!(documents, SessionSearchHit((name, position, message.role, message.kind, message.content)))
        if isascii(message.content)
            append_ascii_session_postings!(postings, message.content, length(documents))
        else
            push!(unicode, length(documents))
        end
    end
    documents
end
"""Narrow candidates conservatively, then verify all text predicates using the exact matcher."""
function indexed_session_candidates(index::SessionSearchIndex, text::AbstractString)
    grams = String[]
    for term in Iterators.filter(isascii, split(strip(String(text)), r"\s+"))
        append!(grams, session_trigrams(term))
    end
    unique!(grams)
    isempty(grams) ? (1:length(index.documents)) : candidates(index, grams, smallest(index.postings, grams))
end

function smallest(postings, grams)
    seed = get(postings, first(grams), nothing)
    index = 2
    while index <= length(grams) && !isnothing(seed)
        posting = get(postings, grams[index], nothing)
        if isnothing(posting) || length(posting) < length(seed)
            seed = posting
        end
        index += 1
    end
    seed
end

candidates(index::SessionSearchIndex, grams, ::Nothing) = copy(index.unicode_documents)

function candidates(index::SessionSearchIndex, grams, seed::BitSet)
    result = copy(seed)
    position = 1
    while position <= length(grams) && !isempty(result)
        posting = index.postings[grams[position]]
        if posting !== seed
            intersect!(result, posting)
        end
        position += 1
    end
    union!(result, index.unicode_documents)
end
"""Search a cached inverted index; SessionStore writes invalidate it automatically."""
search_history(index::SessionSearchIndex, text::AbstractString; roles=nothing, limit::Integer=typemax(Int), sessions=nothing, from_index=nothing, to_index=nothing) = search(index, HistoryQuery(text; roles, limit, sessions, from_index, to_index))

function search(index::SessionSearchIndex, query::HistoryQuery)
    lock(index.lock) do
        revision = lock(() -> index.store.revision, index.store.lock)
        if revision != index.revision
            refresh_index!(index)
        end
        hits = SessionSearchHit[]
        candidates = Iterators.takewhile(id -> length(hits) < query.limit, indexed_session_candidates(index, query.text))
        for id in candidates
            hit = index.documents[id]
            if matches(hit, query)
                push!(hits, hit)
            end
        end
        hits
    end
end
