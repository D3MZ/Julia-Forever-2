"""A minimal Julia service for editable, presentation-safe session titles."""
mutable struct SessionTitles
    lock::ReentrantLock
    values::Dict{String,String}
    max_bytes::Int
end

function positive_title_limit(value::Integer, name::AbstractString)
    if value isa Bool || value <= 0
        error("$name must be a positive integer")
    end
    Int(value)
end

SessionTitles(; max_bytes::Integer=120) =
    SessionTitles(ReentrantLock(), Dict{String,String}(), positive_title_limit(max_bytes, "max_bytes"))

"""Consume an OSC terminal control, stopping at BEL, ESC-backslash or the input end."""
function title_osc_end(characters, position)
    while position <= length(characters)
        if characters[position] == '\a'
            return position + 1
        elseif characters[position] == '\e' && position < length(characters) &&
                characters[position + 1] == '\\'
            return position + 2
        end
        position += 1
    end
    position
end

"""Locate the final byte of a complete CSI command or report an incomplete command."""
function title_csi_end(characters, position)
    while position <= length(characters) && 0x30 <= Int(characters[position]) <= 0x3f
        position += 1
    end
    while position <= length(characters) && 0x20 <= Int(characters[position]) <= 0x2f
        position += 1
    end
    position <= length(characters) && 0x40 <= Int(characters[position]) <= 0x7e ?
        position + 1 : nothing
end

function title_visible(character::Char)
    point = Int(character)
    (point >= 0x20 || character in ('\t', '\n', '\r')) &&
        !(0x7f <= point <= 0x9f) &&
        !(point in (0x200b, 0x200e, 0x200f, 0xfeff)) &&
        !(0x202a <= point <= 0x202e) &&
        !(0x2060 <= point <= 0x2064) &&
        !(0x2066 <= point <= 0x206f)
end

"""Recognize spacing and line breaks that a browser would collapse in title text."""
function title_whitespace(character::Char)
    codepoint = Int(character)
    character in (' ', '\t', '\n', '\v', '\f', '\r') ||
        codepoint in (0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000) ||
        (0x2000 <= codepoint <= 0x200a)
end

"""Collapse Unicode spacing into one ASCII space without losing visible glyphs."""
function collapse_title_whitespace(value::AbstractString)
    output = IOBuffer()
    separator = false
    for character in value
        if title_whitespace(character)
            separator = position(output) > 0
        else
            separator && print(output, ' ')
            print(output, character)
            separator = false
        end
    end
    String(take!(output))
end

"""Convert untrusted terminal text into one ordinary display line without copying upstream code."""
function clean_session_title(value::AbstractString)
    characters = collect(value)
    output = IOBuffer()
    position = 1
    while position <= length(characters)
        character = characters[position]
        next = position < length(characters) ? characters[position + 1] : nothing
        if character == '\e' && next == ']'
            position = title_osc_end(characters, position + 2)
        elseif character == '\u009d'
            position = title_osc_end(characters, position + 1)
        elseif character == '\e' && next == '['
            ending = title_csi_end(characters, position + 2)
            position = isnothing(ending) ? position + 2 : ending
        elseif character == '\u009b'
            ending = title_csi_end(characters, position + 1)
            position = isnothing(ending) ? position + 1 : ending
        elseif character == '\e' && !isnothing(next) && 0x40 <= Int(next) <= 0x5f
            position += 2
        else
            title_visible(character) && print(output, character)
            position += 1
        end
    end
    collapse_title_whitespace(String(take!(output)))
end

"""Take the longest Unicode-codepoint prefix fitting a UTF-8 byte limit."""
function truncate_session_title(value::AbstractString, max_bytes::Integer)
    budget = positive_title_limit(max_bytes, "max_bytes")
    output = IOBuffer()
    used = 0
    for character in value
        width = ncodeunits(string(character))
        used + width > budget && break
        print(output, character)
        used += width
    end
    String(take!(output))
end

"""Produce a single-line display title from untrusted input, bounded by encoded bytes."""
normalize_session_title(value::AbstractString; max_bytes::Integer=120) =
    rstrip(truncate_session_title(clean_session_title(value), max_bytes))

"""Construct a deterministic no-model first-prompt title from leading visible words."""
function fallback_session_title(value::AbstractString; max_words::Integer=8, max_bytes::Integer=120)
    count = positive_title_limit(max_words, "max_words")
    words = Iterators.take(split(clean_session_title(value)), count)
    rstrip(truncate_session_title(join(words, " "), max_bytes))
end

"""Read an explicit title by stable session name; service implementations may replace this method."""
session_title(titles::SessionTitles, name::AbstractString) =
    lock(() -> get(titles.values, String(name), nothing), titles.lock)

"""Accept a normalized title or reject blank/deceptive display text."""
function rename_session_title!(titles::SessionTitles, name::AbstractString, proposed::AbstractString)
    accepted = normalize_session_title(proposed; max_bytes=titles.max_bytes)
    if isempty(accepted)
        (ok=false, title=nothing, reason="Session title must contain visible characters")
    else
        lock(titles.lock) do
            titles.values[String(name)] = accepted
        end
        (ok=true, title=accepted, reason="")
    end
end

"""Release an API-owned name binding when its live session is closed."""
forget_session_title!(titles::SessionTitles, name::AbstractString) =
    lock(() -> pop!(titles.values, String(name), nothing), titles.lock)

"""Restore the saved explicit title when a session is resumed."""
restore_session_title!(titles, name, title::AbstractString) =
    rename_session_title!(titles, name, title)
restore_session_title!(titles, name, ::Nothing) = forget_session_title!(titles, name)

"""Suggest a title from the first nonblank human message when no explicit title exists."""
session_title_fallback(titles, session::Session) = session_title_fallback(session)
session_title_fallback(titles::SessionTitles, session::Session) =
    session_title_fallback(session; max_bytes=titles.max_bytes)

"""Read only the first useful human message under its lock; avoid full history snapshots."""
function session_title_fallback(session::Session; max_bytes::Integer=120)
    lock(session.conversation.lock) do
        for message in session.conversation.messages
            if message.role == :user
                suggestion = fallback_session_title(message.content; max_bytes)
                isempty(suggestion) || return suggestion
            end
        end
        nothing
    end
end

"""Register a replaceable title service in an ordinary Julia plugin composition."""
function session_titles_plugin(; name=:session_titles, service_name=:session_titles,
        factory=SessionTitles)
    contract = Symbol(service_name)
    PluginSpec(name, context -> provide!(context, contract, Base.invokelatest(factory));
        provides=[contract])
end
