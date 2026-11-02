# Native math layout adapted from pinned Pi latex.ts (MIT; licenses/pi-LICENSE).
abstract type SessionMathNode end
struct SessionMathFraction <: SessionMathNode
    numerator::String
    denominator::String
end
struct SessionMathOperator <: SessionMathNode
    operator::String
    lower::Union{Nothing,String}
    upper::Union{Nothing,String}
end
struct SessionMathScript <: SessionMathNode
    lower::Union{Nothing,String}
    upper::Union{Nothing,String}
end
struct SessionMathMatrix <: SessionMathNode
    lines::Vector{String}
    baseline::Int
end
struct SessionMathLayout
    lines::Vector{String}
    width::Int
    baseline::Int
end
const SESSION_MATH_OPERATOR_START="\U000f0004"
const SESSION_MATH_OPERATOR_END="\U000f0005"
const SESSION_MATH_MARKER_START="\U000f0000"
const SESSION_MATH_MARKER_END="\U000f0001"
const SESSION_MATH_PROTECTED_SPACE="\U000f0002"
const SESSION_MATH_MARKERS=Regex(SESSION_MATH_MARKER_START*raw"(\d+)"*SESSION_MATH_MARKER_END)
const SESSION_MATH_TRAILING_MARKER=Regex(SESSION_MATH_MARKER_START*raw"(\d+)"*SESSION_MATH_MARKER_END*raw"$")

session_math_width(text::AbstractString)=sum(menu_search_grapheme_width(String(glyph)) for glyph in Base.Unicode.graphemes(text);init=0)
session_math_pad(line::AbstractString,width::Int,centered::Bool=false)=begin
    text=String(line);padding=max(0,width-session_math_width(text));left=centered ? fld(padding,2) : 0
    repeat(" ",left)*text*repeat(" ",padding-left)
end
session_math_plain_layout(text::AbstractString)=SessionMathLayout([String(text)],session_math_width(text),0)

function session_math_join(layouts::Vector{SessionMathLayout})
    if isempty(layouts)
        SessionMathLayout([""],0,0)
    else
        baseline=maximum(layout.baseline for layout in layouts)
        below=maximum(length(layout.lines)-layout.baseline-1 for layout in layouts)
        lines=String[]
        for row in 0:baseline+below
            parts=String[]
            for layout in layouts
                source=row-baseline+layout.baseline+1
                push!(parts,1<=source<=length(layout.lines) ? session_math_pad(layout.lines[source],layout.width) : repeat(" ",layout.width))
            end
            push!(lines,String(rstrip(join(parts))))
        end
        SessionMathLayout(lines,sum(layout.width for layout in layouts),baseline)
    end
end

function session_math_node_layout(node::SessionMathFraction,nodes::Vector{SessionMathNode})
    numerator=session_math_layout(node.numerator,nodes);denominator=session_math_layout(node.denominator,nodes)
    content=max(numerator.width,denominator.width,1);width=content+2
    lines=vcat([session_math_pad(line,width,true) for line in numerator.lines],[" "*repeat("─",content)*" "],[session_math_pad(line,width,true) for line in denominator.lines])
    SessionMathLayout(lines,width,length(numerator.lines))
end

function session_math_node_layout(node::SessionMathOperator,nodes::Vector{SessionMathNode})
    width=max(session_math_width(node.operator),isnothing(node.lower) ? 0 : session_math_width(node.lower),isnothing(node.upper) ? 0 : session_math_width(node.upper))
    lines=String[]
    !isnothing(node.upper)&&push!(lines,session_math_pad(node.upper,width,true)*" ")
    push!(lines,session_math_pad(node.operator,width,true)*" ")
    !isnothing(node.lower)&&push!(lines,session_math_pad(node.lower,width,true)*" ")
    SessionMathLayout(lines,width+1,isnothing(node.upper) ? 0 : 1)
end

function session_math_node_layout(node::SessionMathScript,nodes::Vector{SessionMathNode})
    upper=isnothing(node.upper) ? nothing : session_math_layout(node.upper,nodes)
    lower=isnothing(node.lower) ? nothing : session_math_layout(node.lower,nodes)
    width=max(isnothing(upper) ? 0 : upper.width,isnothing(lower) ? 0 : lower.width)
    lines=vcat(isnothing(upper) ? String[] : [session_math_pad(line,width) for line in upper.lines],[repeat(" ",width)],isnothing(lower) ? String[] : [session_math_pad(line,width) for line in lower.lines])
    SessionMathLayout(lines,width,isnothing(upper) ? 0 : length(upper.lines))
end

function session_math_node_layout(node::SessionMathMatrix,nodes::Vector{SessionMathNode})
    width=maximum(session_math_width,node.lines;init=0)
    SessionMathLayout([session_math_pad(line,width) for line in node.lines],width,node.baseline)
end

function session_math_layout(source::String,nodes::Vector{SessionMathNode})
    rendered=String[];baseline=0
    for line in split(source,'\n';keepempty=true)
        layouts=SessionMathLayout[];position=firstindex(line);previous=nothing
        for found in eachmatch(SESSION_MATH_MARKERS,line)
            capture=only(found.captures);index=isnothing(capture) ? nothing : tryparse(Int,capture)
            node=isnothing(index)||!(0<=index<length(nodes)) ? nothing : nodes[index+1]
            if !isnothing(node)
                if found.offset>position
                    sliced=String(SubString(line,position,prevind(line,found.offset)))
                    trimmed=String(rstrip(isnothing(previous) ? sliced : lstrip(sliced)))
                    leading=previous isa SessionMathMatrix&&occursin(r"^\s",sliced)
                    trailing=node isa SessionMathMatrix&&occursin(r"\s$",sliced)
                    text=isempty(trimmed) ? (leading||trailing ? " " : "") : (leading ? " " : "")*trimmed*(trailing ? " " : "")
                    push!(layouts,session_math_plain_layout(text))
                end
                push!(layouts,session_math_node_layout(node,nodes))
                position=found.offset+ncodeunits(found.match);previous=node
            end
        end
        if position<=lastindex(line)
            sliced=String(SubString(line,position));trimmed=isnothing(previous) ? sliced : String(lstrip(sliced))
            text=previous isa SessionMathMatrix&&occursin(r"^\s",sliced) ? " "*trimmed : trimmed
            push!(layouts,session_math_plain_layout(text))
        end
        layout=session_math_join(layouts)
        isempty(rendered)&&(baseline=layout.baseline)
        append!(rendered,layout.lines)
    end
    SessionMathLayout(rendered,maximum(session_math_width,rendered;init=0),baseline)
end
