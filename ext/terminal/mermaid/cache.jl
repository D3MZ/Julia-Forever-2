"""Bound source-keyed diagram reuse to one transcript, never to provider or global process state."""
Base.@kwdef mutable struct MermaidRenderCache
    lock::ReentrantLock = ReentrantLock()
    entries::Dict{String,Union{Nothing,MermaidArt}} = Dict{String,Union{Nothing,MermaidArt}}()
    order::Vector{String} = String[]
    bytes::Int = 0
end
mermaid_cache_bytes(source::String,::Nothing)=ncodeunits(source)
mermaid_cache_bytes(source::String,art::MermaidArt)=ncodeunits(source)+sum(ncodeunits,art.plain;init=0)+sum(ncodeunits(span.text)+32 for row in art.styled for span in row;init=0)+sum(ncodeunits,art.warnings;init=0)
mermaid_cached(::Nothing,source::String)=mermaid_render(source)

"""Evict old pure renderings before retaining at most eight entries and one MiB of source and art."""
function mermaid_cached(cache::MermaidRenderCache,source::String)::Union{Nothing,MermaidArt}
    lock(cache.lock) do
        if haskey(cache.entries,source)
            cache.entries[source]
        else
            art=mermaid_render(source);cost=mermaid_cache_bytes(source,art)
            if cost<=1_048_576
                while !isempty(cache.order)&&(length(cache.order)>=8||cache.bytes+cost>1_048_576)
                    old=popfirst!(cache.order)
                    cache.bytes-=mermaid_cache_bytes(old,pop!(cache.entries,old))
                end
                cache.entries[source]=art;push!(cache.order,source);cache.bytes+=cost
            end
            art
        end
    end
end
