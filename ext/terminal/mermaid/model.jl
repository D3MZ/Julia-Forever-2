# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0, see licenses/grok-mermaid-LICENSE.
const MERMAID_MAX_NODES=128
const MERMAID_MAX_EDGES=512
const MERMAID_MAX_GROUPS=24
const MERMAID_MAX_DEPTH=6
const MERMAID_MAX_MEMBERS=8
const MERMAID_MAX_CELLS=1<<21
const MERMAID_MAX_SOURCE=262_144
const MERMAID_WRAP_WIDTH=24
const MERMAID_MAX_LINES=4
const MERMAID_MAX_LABEL=28

Base.@kwdef mutable struct MermaidNode
    label::String
    shape::Symbol=:rect
end
Base.@kwdef struct MermaidEdge
    from::Int
    to::Int
    label::Union{Nothing,String}=nothing
    head_to::Symbol=:arrow
    head_from::Symbol=:none
    line::Symbol=:solid
end
Base.@kwdef struct MermaidGroup
    id::String
    label::String
    parent::Int=0
end
Base.@kwdef mutable struct MermaidClass
    annotation::Union{Nothing,String}=nothing
    attrs::Vector{String}=String[]
    methods::Vector{String}=String[]
end
Base.@kwdef mutable struct MermaidGraph
    nodes::Vector{MermaidNode}=MermaidNode[]
    edges::Vector{MermaidEdge}=MermaidEdge[]
    index::Dict{String,Int}=Dict{String,Int}()
    groups::Vector{MermaidGroup}=MermaidGroup[]
    node_group::Vector{Int}=Int[]
    current_group::Int=0
    over_cap::Bool=false
    warnings::Vector{String}=String[]
    direction::Symbol=:down
end
Base.@kwdef struct MermaidSequenceItem
    kind::Symbol
    from::Int=0
    to::Int=0
    text::Union{Nothing,String}=nothing
    dashed::Bool=false
    head::Symbol=:arrow
    anchor::Symbol=:over
end
Base.@kwdef mutable struct MermaidSequence
    labels::Vector{String}=String[]
    index::Dict{String,Int}=Dict{String,Int}()
    items::Vector{MermaidSequenceItem}=MermaidSequenceItem[]
end
struct MermaidSpan
    text::String
    kind::Symbol
end
struct MermaidArt
    plain::Vector{String}
    styled::Vector{Vector{MermaidSpan}}
    width::Int
    warnings::Vector{String}
end
mermaid_lower(s::AbstractString)=replace(String(s),r"[A-Z]"=>m->lowercase(m))
mermaid_words(s::AbstractString)=String.(split(s,mermaid_space;keepempty=false))
mermaid_firstword(s::AbstractString)=isempty(mermaid_trim(s)) ? "" : first(mermaid_words(s))
mermaid_nonempty(s::AbstractString)=isempty(s) ? nothing : String(s)
mermaid_direction(s::AbstractString)=get(Dict("lr"=>:right,"rl"=>:left,"bt"=>:up),mermaid_lower(s),:down)
mermaid_char(chars::Vector{Char},i::Int)=1<=i<=length(chars) ? chars[i] : '\0'
mermaid_slice(chars::Vector{Char},a::Int,b::Int=length(chars))=a>b ? "" : String(chars[a:b])
mermaid_id(c::Char)=c=='_'||mermaid_alphanumeric(c)
mermaid_splitonce(s::AbstractString,delimiter::AbstractString)=occursin(delimiter,s) ? Tuple(String.(split(s,delimiter;limit=2))) : nothing

"""Retain declaration order while replacing only explicit node labels and shapes."""
function mermaid_node!(graph::MermaidGraph,id::AbstractString,label::Union{Nothing,AbstractString}=nothing,shape::Symbol=:rect)
    key=String(id);index=get(graph.index,key,0)
    if index>0
        if !isnothing(label)
            graph.nodes[index].label=String(label);graph.nodes[index].shape=shape
        end
    elseif length(graph.nodes)>=MERMAID_MAX_NODES
        graph.over_cap=true
    else
        push!(graph.nodes,MermaidNode(;label=isnothing(label) ? key : String(label),shape))
        push!(graph.node_group,graph.current_group)
        index=length(graph.nodes);graph.index[key]=index
    end
    index
end
function mermaid_node_label!(graph::MermaidGraph,id::AbstractString,label::AbstractString)
    index=get(graph.index,String(id),0)
    if index>0
        graph.nodes[index].label=String(label)
    else
        index=mermaid_node!(graph,id,label,:round)
    end
    index
end
function mermaid_edge!(graph::MermaidGraph,edge::MermaidEdge)
    if length(graph.edges)>=MERMAID_MAX_EDGES
        graph.over_cap=true
        false
    else
        push!(graph.edges,edge)
        true
    end
end
function mermaid_participant!(sequence::MermaidSequence,id::AbstractString,label::Union{Nothing,AbstractString}=nothing)
    key=String(id);index=get(sequence.index,key,0)
    if index>0
        isnothing(label)||(sequence.labels[index]=String(label))
    elseif length(sequence.labels)<MERMAID_MAX_NODES
        push!(sequence.labels,isnothing(label) ? key : String(label))
        index=length(sequence.labels);sequence.index[key]=index
    end
    index
end

mermaid_space(c::Char)=c in ('\t','\n','\v','\f','\r',' ','\u00a0','\u1680','\u2028','\u2029','\u202f','\u205f','\u3000','\ufeff')||'\u2000'<=c<='\u200a'
mermaid_trim(s::AbstractString)=String(strip(mermaid_space,s))
mermaid_ltrim(s::AbstractString)=String(lstrip(mermaid_space,s))
mermaid_rtrim(s::AbstractString)=String(rstrip(mermaid_space,s))
function mermaid_alphanumeric(c::Char)
    point=UInt32(c);lo=1;hi=length(MERMAID_IDENTIFIER_RUNS)
    while lo<=hi
        mid=(lo+hi)÷2;a,b=MERMAID_IDENTIFIER_RUNS[mid]
        if point<a
            hi=mid-1
        elseif point>b
            lo=mid+1
        else
            return true
        end
    end
    false
end
