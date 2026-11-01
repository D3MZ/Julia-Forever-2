"""A composable query service over live or durable Julia session history."""
struct SessionQuery{S}
    source::S
end

"""Publish session history queries through a replaceable, plugin-owned service."""
function session_query_plugin(; name=:session_query, store_service=:session_store,
        service_name=:session_query, factory=SessionQuery)
    dependency = Symbol(store_service)
    contract = Symbol(service_name)
    setup = context -> provide!(context, contract,
        Base.invokelatest(factory, service(context, dependency)))
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
