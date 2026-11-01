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
    isdir(store.directory) || return String[]
    names = String[]
    for filename in readdir(store.directory)
        endswith(filename, ".json") || continue
        name = chop(filename; tail=5)
        path = session_file(store, name)
        (isnothing(path) || islink(path) || !isfile(path)) && continue
        push!(names, name)
    end
    return sort!(names)
end

const SessionSearchHit = NamedTuple{(:session, :index, :role, :kind, :content),
    Tuple{Union{Nothing,String},Int,Symbol,Symbol,String}}

function session_query_pattern(text::AbstractString)
    stripped = strip(String(text))
    isempty(stripped) && error("Session query must contain non-whitespace text")
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

function append_session_matches!(hits::Vector{SessionSearchHit}, messages, identity,
        pattern::Regex, allowed_roles, limit::Integer)
    for (index, message) in enumerate(messages)
        length(hits) >= limit && break
        if !isnothing(allowed_roles) && !(message.role in allowed_roles)
            continue
        end
        occursin(pattern, message.content) || continue
        push!(hits, SessionSearchHit((identity, index, message.role, message.kind, message.content)))
    end
    return hits
end

"""Search a detached snapshot of a live session without changing its conversation."""
function search_history(session::Session, text::AbstractString; roles=nothing, limit::Integer=typemax(Int))
    limit >= 0 || error("Session query limit must be nonnegative")
    pattern = session_query_pattern(text)
    allowed = isnothing(roles) ? nothing : Set(Symbol.(roles))
    return append_session_matches!(SessionSearchHit[], history_snapshot(session).messages,
        nothing, pattern, allowed, limit)
end

"""Search stored sessions in deterministic name/message order without activating agents."""
function search_history(store::SessionStore, text::AbstractString; roles=nothing, limit::Integer=typemax(Int))
    limit >= 0 || error("Session query limit must be nonnegative")
    pattern = session_query_pattern(text)
    allowed = isnothing(roles) ? nothing : Set(Symbol.(roles))
    hits = SessionSearchHit[]
    for name in session_names(store)
        length(hits) >= limit && break
        record = saved_session_record(store, name)
        isnothing(record) && continue
        append_session_matches!(hits, record.messages, name, pattern, allowed, limit)
    end
    return hits
end

search_history(query::SessionQuery, text::AbstractString; kwargs...) =
    search_history(query.source, text; kwargs...)


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

function SessionSearchIndex(store::SessionStore)
    index = SessionSearchIndex(store, ReentrantLock(), typemax(UInt64),
        SessionSearchHit[], Dict{String,BitSet}(), BitSet())
    refresh_index!(index)
    return index
end

"""Rebuild index snapshots explicitly after changes made outside this SessionStore instance."""
function refresh_index!(index::SessionSearchIndex)
    return lock(index.lock) do
        lock(index.store.lock) do
            documents = SessionSearchHit[]
            postings = Dict{String,BitSet}()
            unicode_documents = BitSet()
            for name in session_names(index.store)
                record = saved_session_record(index.store, name)
                isnothing(record) && continue
                for (position, message) in enumerate(record.messages)
                    push!(documents, SessionSearchHit((name, position, message.role, message.kind, message.content)))
                    document_id = length(documents)
                    if isascii(message.content)
                        for gram in Set(session_trigrams(message.content))
                            push!(get!(BitSet, postings, gram), document_id)
                        end
                    else
                        push!(unicode_documents, document_id)
                    end
                end
            end
            index.documents = documents
            index.postings = postings
            index.unicode_documents = unicode_documents
            index.revision = index.store.revision
        end
        return index
    end
end

"""Narrow candidates conservatively, then verify all text predicates using the exact matcher."""
function indexed_session_candidates(index::SessionSearchIndex, text::AbstractString)
    terms = split(strip(String(text)), r"\s+")
    grams = String[]
    for term in terms
        isascii(term) || continue
        append!(grams, session_trigrams(term))
    end
    unique!(grams)
    isempty(grams) && return 1:length(index.documents)
    candidates = copy(get(index.postings, first(grams), BitSet()))
    for gram in Iterators.drop(grams, 1)
        intersect!(candidates, get(index.postings, gram, BitSet()))
        isempty(candidates) && break
    end
    union!(candidates, index.unicode_documents)
    return candidates
end

"""Search a cached inverted index; SessionStore writes invalidate it automatically."""
function search_history(index::SessionSearchIndex, text::AbstractString; roles=nothing, limit::Integer=typemax(Int))
    limit >= 0 || error("Session query limit must be nonnegative")
    pattern = session_query_pattern(text)
    allowed = isnothing(roles) ? nothing : Set(Symbol.(roles))
    return lock(index.lock) do
        revision = lock(() -> index.store.revision, index.store.lock)
        revision == index.revision || refresh_index!(index)
        hits = SessionSearchHit[]
        for document_id in indexed_session_candidates(index, text)
            length(hits) >= limit && break
            hit = index.documents[document_id]
            !isnothing(allowed) && !(hit.role in allowed) && continue
            occursin(pattern, hit.content) && push!(hits, hit)
        end
        return hits
    end
end
