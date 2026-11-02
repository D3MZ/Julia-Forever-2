import JSON

"""A title revision that never enters model-visible conversation history."""
struct SessionTitleRecord
    text::String
    source::Symbol
end

"""An independently replaceable Julia service for human-readable session names."""
mutable struct SessionTitleService{S}
    store::S
    lock::ReentrantLock
    records::Dict{UUID,SessionTitleRecord}
    max_words::Int
    fallback_max_bytes::Int
    max_bytes::Int
    closed::Bool
end

title_positive(name, value::Integer) = value isa Bool || value < 1 || value > typemax(Int) ?
    error("$name must be a positive integer") : Int(value)

function SessionTitleService(; store=nothing, max_words::Integer=8,
        fallback_max_bytes::Integer=96, max_bytes::Integer=120)
    words = title_positive("max_words", max_words)
    fallback = title_positive("fallback_max_bytes", fallback_max_bytes)
    maximum = title_positive("max_bytes", max_bytes)
    fallback <= maximum || error("fallback_max_bytes cannot exceed max_bytes")
    SessionTitleService(store, ReentrantLock(), Dict{UUID,SessionTitleRecord}(),
        words, fallback, maximum, false)
end

"""Skip a terminal control sequence without rendering its hidden contents."""
function skip_title_csi(characters, index)
    while index <= length(characters) && 0x20 <= Int(characters[index]) <= 0x3f
        index += 1
    end
    index <= length(characters) && 0x40 <= Int(characters[index]) <= 0x7e ?
        index + 1 : index
end

function skip_title_osc(characters, index)
    finished = false
    while index <= length(characters) && !finished
        if characters[index] == '\a'
            index += 1
            finished = true
        elseif characters[index] == '\e' && index < length(characters) &&
                characters[index + 1] == '\\'
            index += 2
            finished = true
        else
            index += 1
        end
    end
    index
end

function skip_title_escape(characters, index)
    if index == length(characters)
        length(characters) + 1
    elseif characters[index + 1] == '['
        skip_title_csi(characters, index + 2)
    elseif characters[index + 1] == ']'
        skip_title_osc(characters, index + 2)
    elseif 0x40 <= Int(characters[index + 1]) <= 0x5f
        index + 2
    else
        index + 1
    end
end

"""Do not allow nonprinting, invisible or directional controls in browser titles."""
function title_hidden(character::Char)
    code = Int(character)
    code <= 0x08 || 0x0b <= code <= 0x0c || 0x0e <= code <= 0x1f ||
        0x7f <= code <= 0x9f || code in (0x200b, 0x200e, 0x200f, 0xfeff) ||
        0x202a <= code <= 0x202e || 0x2060 <= code <= 0x2064 ||
        0x2066 <= code <= 0x206f
end

function clean_session_title(input::AbstractString)
    characters = collect(String(input))
    output = IOBuffer()
    pending_space = false
    index = 1
    while index <= length(characters)
        character = characters[index]
        code = Int(character)
        if code == 0x1b
            index = skip_title_escape(characters, index)
        elseif code == 0x9b
            index = skip_title_csi(characters, index + 1)
        elseif code == 0x9d
            index = skip_title_osc(characters, index + 1)
        else
            if isspace(character) && !title_hidden(character)
                pending_space = position(output) > 0
            elseif !title_hidden(character)
                pending_space && print(output, ' ')
                pending_space = false
                print(output, character)
            end
            index += 1
        end
    end
    String(take!(output))
end

"""Return a Unicode-codepoint prefix within an encoded byte budget."""
function title_prefix(input::AbstractString, max_bytes::Integer)
    remaining = title_positive("max_bytes", max_bytes)
    output = IOBuffer()
    state = iterate(input)
    finished = false
    while !isnothing(state) && !finished
        character, position = state
        bytes = ncodeunits(string(character))
        if bytes > remaining
            finished = true
        else
            print(output, character)
            remaining -= bytes
            state = iterate(input, position)
        end
    end
    String(rstrip(String(take!(output))))
end

"""Produce a terminal-safe, whitespace-normalized title within a UTF-8 byte bound."""
normalize_session_title(input::AbstractString; max_bytes::Integer=120) =
    title_prefix(clean_session_title(input), max_bytes)

"""Derive a deterministic title from the first eligible human text, without model calls."""
function fallback_session_title(input::AbstractString; max_words::Integer=8,
        max_bytes::Integer=96)
    words = title_positive("max_words", max_words)
    text = clean_session_title(input)
    title_prefix(join(Iterators.take(split(text, ' '; keepempty=false), words), " "), max_bytes)
end

title_record_path(::Nothing, identity::UUID) = nothing
title_record_path(store::SessionStore, identity::UUID) =
    joinpath(store.directory, ".session-titles", string(identity) * ".json")

load_title_record(::Nothing, identity::UUID) = nothing

"""Read title-only metadata without restoring an agent or modifying its model input."""
function load_title_record(store::SessionStore, identity::UUID)
    path = title_record_path(store, identity)
    if !is_saved_profile_file(path)
        nothing
    else
        data = JSON.parsefile(path)
        if get(data, "format", nothing) != "JuliaForever2.title" ||
                get(data, "version", nothing) != 1 ||
                get(data, "session_id", nothing) != string(identity)
            error("Invalid session title record")
        end
        source = Symbol(data["source"])
        source in (:user, :fallback) || error("Unsupported session title source")
        SessionTitleRecord(String(data["title"]), source)
    end
end

save_title_record!(::Nothing, identity::UUID, record::SessionTitleRecord) = nothing

"""Atomically persist title metadata separately from the session transcript."""
function save_title_record!(store::SessionStore, identity::UUID, record::SessionTitleRecord)
    path = title_record_path(store, identity)
    directory = dirname(path)
    data = Dict("format" => "JuliaForever2.title", "version" => 1,
        "session_id" => string(identity), "title" => record.text,
        "source" => String(record.source))
    mkpath(directory; mode=0o700)
    mktemp(directory) do temporary, output
        chmod(temporary, 0o600)
        write(output, JSON.json(data) * "\n")
        close(output)
        Base.Filesystem.rename(temporary, path)
    end
    nothing
end

delete_title_record!(::Nothing, identity::UUID) = nothing

function delete_title_record!(store::SessionStore, identity::UUID)
    path = title_record_path(store, identity)
    is_saved_profile_file(path) && rm(path)
    nothing
end

function first_session_title(service::SessionTitleService, session::Session)
    title = nothing
    for message in history_snapshot(session).messages
        if isnothing(title) && message.role === :user && message.kind === :text
            proposed = fallback_session_title(message.content;
                max_words=service.max_words, max_bytes=service.fallback_max_bytes)
            !isempty(proposed) && (title = proposed)
        end
    end
    title
end

function remember_title!(service::SessionTitleService, identity::UUID,
        record::SessionTitleRecord)
    save_title_record!(service.store, identity, record)
    service.records[identity] = record
    record.text
end

"""Read the saved explicit title or materialize the first eligible user-text fallback."""
function session_title(service::SessionTitleService, session::Session)
    identity = session_lineage(session).id
    lock(service.lock) do
        if service.closed
            nothing
        else
            record = get(service.records, identity, nothing)
            if isnothing(record)
                record = load_title_record(service.store, identity)
            end
            if isnothing(record)
                title = first_session_title(service, session)
                if !isnothing(title)
                    record = SessionTitleRecord(title, :fallback)
                    remember_title!(service, identity, record)
                end
            else
                service.records[identity] = record
            end
            isnothing(record) ? nothing : record.text
        end
    end
end

"""Accept a user title without adding a transcript entry; invalid names return nothing."""
function rename_session_title!(service::SessionTitleService, session::Session,
        input::AbstractString)
    title = normalize_session_title(input; max_bytes=service.max_bytes)
    if isempty(title) || !isopen(session)
        nothing
    else
        lock(service.lock) do
            service.closed ? nothing :
                remember_title!(service, session_lineage(session).id,
                    SessionTitleRecord(title, :user))
        end
    end
end

"""Unpin a title and return to the deterministic current-session fallback."""
function refresh_session_title!(service::SessionTitleService, session::Session)
    if !isopen(session)
        nothing
    else
        lock(service.lock) do
            if service.closed
                nothing
            else
                identity = session_lineage(session).id
                title = first_session_title(service, session)
                if isnothing(title)
                    delete_title_record!(service.store, identity)
                    delete!(service.records, identity)
                    nothing
                else
                    remember_title!(service, identity, SessionTitleRecord(title, :fallback))
                end
            end
        end
    end
end

"""Preserve the title provenance when a native Julia session is independently forked."""
function inherit_session_title!(service::SessionTitleService, source::Session, child::Session)
    session_title(service, source)
    lock(service.lock) do
        record = get(service.records, session_lineage(source).id, nothing)
        service.closed || isnothing(record) ? nothing :
            remember_title!(service, session_lineage(child).id, record)
    end
end

inherit_session_title!(service, source::Session, child::Session) = nothing

Base.close(service::SessionTitleService) = lock(service.lock) do
    service.closed = true
    empty!(service.records)
    nothing
end

"""Install an optional, entirely native session-title service through profile composition."""
function session_title_plugin(; name=:session_titles, service_name=:session_titles,
        store_service=nothing, max_words=8, fallback_max_bytes=96, max_bytes=120)
    dependency = isnothing(store_service) ? Symbol[] : [Symbol(store_service)]
    contract = Symbol(service_name)
    setup = context -> begin
        store = isnothing(store_service) ? nothing : service(context, Symbol(store_service))
        provide!(context, contract, SessionTitleService(;
            store, max_words, fallback_max_bytes, max_bytes);
            requires=dependency, cleanup=close)
    end
    PluginSpec(name, setup; requires=dependency, provides=[contract])
end
