"""Render the public text history of a Julia session without exporting internal runtime state."""
session_markdown(session::Session; kwargs...) = session_markdown(history_snapshot(session).messages; kwargs...)

"""Render a caller-owned message snapshot as a portable Markdown transcript."""
function session_markdown(messages::AbstractVector; title=nothing, source_path=nothing)
    heading = isnothing(title) ? "" : strip(replace(String(title), r"\r\n?|\n" => " "))
    sections = String["# " * (isempty(heading) ? "Untitled Session" : heading)]
    if !isnothing(source_path) && !isempty(source_path)
        push!(sections, "Session file:\n\n" * markdown_source_path(String(source_path)))
    end
    for message in messages
        section = session_markdown_entry(message)
        isnothing(section) || isempty(section) || push!(sections, section)
    end
    return rstrip(join(sections, "\n\n")) * "\n"
end

"""Filter message kinds before delegating public text to the replaceable role formatter."""
session_markdown_entry(message::Message) = session_markdown_entry(Val(message.role), Val(message.kind), message.content)
session_markdown_entry(::Val, ::Val, content::AbstractString) = nothing
session_markdown_entry(role::Val, ::Val{:text}, content::AbstractString) = session_markdown_entry(role, content)
session_markdown_entry(role::Val{:assistant}, ::Val{:answer}, content::AbstractString) = session_markdown_entry(role, content)

"""Project one message role; other packages can define additional role-specific formats."""
session_markdown_entry(::Val, content::AbstractString) = nothing

"""Quote user Markdown lines directly from UTF-8 bytes without temporary line arrays."""
function session_markdown_entry(::Val{:user}, content::AbstractString)
    bytes = codeunits(String(content))
    output = IOBuffer()
    pending_empty = 0
    written = false
    line_start = 1
    index = 1
    last = length(bytes)
    while index <= last + 1
        if index > last || bytes[index] == 0x0a || bytes[index] == 0x0d
            if index == line_start
                pending_empty += 1
            else
                for _ in 1:pending_empty
                    written && print(output, '\n')
                    print(output, '>')
                    written = true
                end
                pending_empty = 0
                written && print(output, '\n')
                print(output, "> ")
                write(output, @view bytes[line_start:index-1])
                written = true
            end
            if index < last && bytes[index] == 0x0d && bytes[index + 1] == 0x0a
                index += 1
            end
            line_start = index + 1
        end
        index += 1
    end
    written ? String(take!(output)) : nothing
end

function session_markdown_entry(::Val{:assistant}, content::AbstractString)
    lines = split(replace(content, r"\r\n?" => "\n"), '\n'; keepempty=true)
    first_content = findfirst(line -> !isempty(strip(line)), lines)
    return markdown_assistant_lines(lines, first_content)
end

markdown_assistant_lines(lines::AbstractVector{<:AbstractString}, ::Nothing) = nothing

function markdown_assistant_lines(lines::AbstractVector{<:AbstractString}, first_content::Integer)
    last_content = something(findlast(line -> !isempty(strip(line)), lines), first_content)
    return join(lines[first_content:last_content], "\n")
end

function markdown_source_path(path::AbstractString)
    longest = maximum((length(matched.match) for matched in eachmatch(r"`+", path)); init=0)
    fence = repeat("`", max(3, longest + 1))
    return fence * "text\n" * path * "\n" * fence
end
