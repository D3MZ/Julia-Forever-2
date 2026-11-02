# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
include("width_data.jl")
include("identifier_data.jl")
include("model.jl")
include("labels.jl")
include("canvas.jl")
include("parse_flow.jl")
include("parse_structured.jl")
include("parse_sequence.jl")
include("layout_rank.jl")
include("layout_draw.jl")
include("layout_graph.jl")
include("layout_sequence.jl")

"""Render the five pinned reference families without evaluating Mermaid callbacks, HTML or URLs."""
function mermaid_draw(source::String)
    statements=mermaid_statements(source);kind=mermaid_kind(statements)
    if kind==:flowchart
        graph=mermaid_parse_flow(statements);isnothing(graph)&&return nothing
        canvas=isempty(graph.groups) ? mermaid_layout_flow(graph) : mermaid_layout_grouped(graph)
        isnothing(canvas) ? nothing : (;canvas,warnings=graph.warnings)
    elseif kind==:state
        graph=mermaid_parse_state(statements);isnothing(graph)&&return nothing
        canvas=mermaid_layout_flow(graph)
        isnothing(canvas) ? nothing : (;canvas,warnings=String[])
    elseif kind in (:class,:er)
        parsed=kind==:class ? mermaid_parse_class(statements) : mermaid_parse_er(statements)
        isnothing(parsed)&&return nothing
        canvas=mermaid_layout_class(parsed.graph,parsed.infos)
        isnothing(canvas) ? nothing : (;canvas,warnings=String[])
    elseif kind==:sequence
        sequence=mermaid_parse_sequence(statements);isnothing(sequence)&&return nothing
        canvas=mermaid_layout_sequence(sequence)
        isnothing(canvas) ? nothing : (;canvas,warnings=String[])
    else
        nothing
    end
end
function mermaid_render_content(raw::String)
    ncodeunits(raw)<=MERMAID_MAX_SOURCE||return nothing
    source=mermaid_strip_controls(raw);isempty(mermaid_trim(source))&&return nothing
    drawn=mermaid_draw(source)
    if isnothing(drawn)
        body=mermaid_rtrim(source);cut=findlast('\n',body)
        isnothing(cut)&&return nothing
        drawn=mermaid_draw(String(SubString(body,1,prevind(body,cut))))
        isnothing(drawn)&&return nothing
        dropped=mermaid_trim(SubString(body,nextind(body,cut)))
        push!(drawn.warnings,"dropped, unreadable final line: \"$dropped\"")
    end
    mermaid_art(drawn.canvas,drawn.warnings)
end

mermaid_render_unchecked(raw::String)=Base.ScopedValues.with(()->mermaid_render_content(raw),MERMAID_CELL_BUDGET=>Ref(2MERMAID_MAX_CELLS))

"""A supervised native rendering boundary returns source fallback on malformed or oversized input."""
function mermaid_render(raw::AbstractString)::Union{Nothing,MermaidArt}
    ncodeunits(raw)<=MERMAID_MAX_SOURCE||return nothing
    operation=Task(()->mermaid_render_unchecked(String(raw)))
    schedule(operation);wait(operation;throw=false)
    istaskfailed(operation) ? nothing : fetch(operation)
end
