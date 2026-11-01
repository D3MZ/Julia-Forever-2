"""Render the public text history of a Julia session without exporting internal runtime state."""
session_markdown(session::Session; kwargs...) = session_markdown(history_snapshot(session).messages; kwargs...)

"""Render a caller-owned message snapshot as a portable Markdown transcript."""
function session_markdown(messages::AbstractVector{<:Message}; title=nothing, source_path=nothing)
    heading = isnothing(title) ? "" : strip(replace(String(title), r"\r\n?|\n" => " "))
    sections = String["# " * (isempty(heading) ? "Untitled Session" : heading)]
    if !isnothing(source_path) && !isempty(source_path)
        push!(sections, "Session file:\n\n" * markdown_source_path(String(source_path)))
    end
    for message in messages
        section = session_markdown_entry(Val(message.role), message.content)
        isnothing(section) || isempty(section) || push!(sections, section)
    end
    return rstrip(join(sections, "\n\n")) * "\n"
end

"""Project one message role; other packages can define additional role-specific formats."""
session_markdown_entry(::Val, content::AbstractString) = nothing

function session_markdown_entry(::Val{:user}, content::AbstractString)
    isempty(content) && return nothing
    lines = split(replace(content, r"\r\n?" => "\n"), '\n'; keepempty=true)
    while !isempty(lines) && isempty(last(lines))
        pop!(lines)
    end
    return join((isempty(line) ? ">" : "> " * line for line in lines), "\n")
end

function session_markdown_entry(::Val{:assistant}, content::AbstractString)
    lines = split(replace(content, r"\r\n?" => "\n"), '\n'; keepempty=true)
    first_content = findfirst(line -> !isempty(strip(line)), lines)
    isnothing(first_content) && return nothing
    last_content = findlast(line -> !isempty(strip(line)), lines)
    return join(lines[first_content:last_content], "\n")
end

function markdown_source_path(path::AbstractString)
    longest = maximum((length(matched.match) for matched in eachmatch(r"`+", path)); init=0)
    fence = repeat("`", max(3, longest + 1))
    return fence * "text\n" * path * "\n" * fence
end
