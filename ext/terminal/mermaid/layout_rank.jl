# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
Base.@kwdef struct MermaidPlaced
    x::Int
    y::Int
    width::Int
    height::Int
    cx::Int=x+fld(width,2)
    cy::Int=y+fld(height,2)
    rank::Int=0
end
Base.@kwdef struct MermaidExtra
    kind::Symbol=:plain
    canvas::Union{Nothing,MermaidCanvas}=nothing
    sections::Vector{Vector{String}}=Vector{String}[]
end
struct MermaidSizes
    widths::Vector{Int}
    heights::Vector{Int}
    layout_widths::Vector{Int}
    layout_heights::Vector{Int}
    extra_heights::Vector{Int}
    self_label_widths::Vector{Int}
end
struct MermaidRoutePlan
    width::Int
    height::Int
    band_end::Vector{Int}
    edge_bus::Vector{Int}
    lane_base::Int
    edge_lane::Vector{Int}
end
mermaid_sat(a::Int,b::Int)=max(0,a-b)

"""Iterative DFS removes only back edges from rank assignment while retaining every edge for routing."""
function mermaid_ranks(graph::MermaidGraph)
    n=length(graph.nodes);children=[Int[] for _ in 1:n];indegree=zeros(Int,n)
    for edge in graph.edges
        edge.from==edge.to&&continue
        push!(children[edge.from],edge.to);indegree[edge.to]+=1
    end
    color=zeros(UInt8,n);dag=[Int[] for _ in 1:n];order=Int[]
    for start in vcat(findall(iszero,indegree),collect(1:n))
        color[start]!=0&&continue
        stack=Tuple{Int,Int}[(start,1)];color[start]=1
        while !isempty(stack)
            node,next=last(stack)
            if next<=length(children[node])
                child=children[node][next];stack[end]=(node,next+1)
                color[child]==1&&continue
                push!(dag[node],child)
                if color[child]==0
                    color[child]=1;push!(stack,(child,1))
                end
            else
                color[node]=2;push!(order,node);pop!(stack)
            end
        end
    end
    rank=zeros(Int,n)
    for node in reverse(order),child in dag[node]
        rank[child]=max(rank[child],rank[node]+1)
    end
    rank
end
function mermaid_neighbors(edges::Vector{MermaidEdge},ranks::Vector{Int})
    parents=[Int[] for _ in ranks];children=[Int[] for _ in ranks]
    for e in edges
        if e.from!=e.to&&ranks[e.to]>ranks[e.from]
            push!(parents[e.to],e.from);push!(children[e.from],e.to)
        end
    end
    parents,children
end
function mermaid_crossings(edges::Vector{MermaidEdge},ranks::Vector{Int},positions::Vector{Int})
    adjacent=[(ranks[e.from],positions[e.from],positions[e.to]) for e in edges if e.from!=e.to&&ranks[e.to]==ranks[e.from]+1]
    crossings=0
    for i in eachindex(adjacent),j in i+1:length(adjacent)
        a=adjacent[i];b=adjacent[j]
        crossings+=a[1]==b[1]&&((a[2]<b[2]&&a[3]>b[3])||(a[2]>b[2]&&a[3]<b[3]))
    end
    crossings
end
function mermaid_order_ranks!(rows::Vector{Vector{Int}},edges::Vector{MermaidEdge},ranks::Vector{Int})
    length(rows)<2||length(ranks)<3 ? (return nothing) : nothing
    parents,children=mermaid_neighbors(edges,ranks);positions=zeros(Int,length(ranks))
    for row in rows,(index,node) in enumerate(row)
        positions[node]=index-1
    end
    best=deepcopy(rows);bestcross=mermaid_crossings(edges,ranks,positions)
    bestcross==0&&return nothing
    for iteration in 0:7
        selected=iseven(iteration) ? rows[2:end] : reverse(rows[1:end-1]);neighbors=iseven(iteration) ? parents : children
        for row in selected
            sort!(row;by=node->isempty(neighbors[node]) ? Float64(positions[node]) : sum(positions[u] for u in neighbors[node])/length(neighbors[node]),alg=Base.Sort.MergeSort)
            for (index,node) in enumerate(row)
                positions[node]=index-1
            end
        end
        crossings=mermaid_crossings(edges,ranks,positions)
        if crossings<bestcross
            bestcross=crossings;best=deepcopy(rows)
        end
        bestcross==0&&break
    end
    for i in eachindex(rows)
        rows[i]=best[i]
    end
    nothing
end
function mermaid_relax_rank!(nodes::Vector{Int},neighbors::Vector{Vector{Int}},positions::Vector{Float64},sizes::Vector{Int},gap::Int)
    n=length(nodes);n==0&&return nothing
    desired=[isempty(neighbors[v]) ? positions[v] : sum(positions[u] for u in neighbors[v])/length(neighbors[v]) for v in nodes]
    half(i)=sizes[nodes[i]]/2
    left=zeros(Float64,n);right=zeros(Float64,n)
    for i in 1:n
        left[i]=i==1 ? desired[i] : max(desired[i],left[i-1]+half(i-1)+gap+half(i))
    end
    for i in n:-1:1
        right[i]=i==n ? desired[i] : min(desired[i],right[i+1]-half(i+1)-gap-half(i))
    end
    for i in 1:n
        positions[nodes[i]]=(left[i]+right[i])/2
    end
    for i in 2:n
        positions[nodes[i]]=max(positions[nodes[i]],positions[nodes[i-1]]+half(i-1)+gap+half(i))
    end
    nothing
end
function mermaid_positions(rows::Vector{Vector{Int}},sizes::Vector{Int},gap::Int,edges::Vector{MermaidEdge},ranks::Vector{Int})
    parents,children=mermaid_neighbors(edges,ranks);positions=zeros(Float64,length(sizes))
    for row in rows
        x=0.0
        for v in row
            x+=sizes[v]/2;positions[v]=x;x+=sizes[v]/2+gap
        end
    end
    for iteration in 0:9
        selected=iseven(iteration) ? rows : reverse(rows);neighbors=iseven(iteration) ? parents : children
        for row in selected
            mermaid_relax_rank!(row,neighbors,positions,sizes,gap)
        end
    end
    left=minimum((positions[v]-sizes[v]/2 for v in eachindex(sizes));init=Inf)
    isfinite(left)||(left=0.0)
    [max(0,floor(Int,positions[v]-left+0.5)) for v in eachindex(sizes)]
end
function mermaid_tracks(spans::Vector{NTuple{5,Int}})
    tracks=Vector{NTuple{4,Int}}[];assigned=Tuple{Int,Int}[]
    for (start,ending,from,to,index) in sort(spans)
        slot=findfirst(members->all(member->member[2]+2<=start||ending+2<=member[1]||member[3]==from||member[4]==to,members),tracks)
        if isnothing(slot)
            push!(tracks,NTuple{4,Int}[]);slot=length(tracks)
        end
        push!(tracks[slot],(start,ending,from,to));push!(assigned,(index,slot-1))
    end
    (;assigned,count=length(tracks))
end
function mermaid_bus_spans(graph::MermaidGraph,ranks::Vector{Int},centers::Vector{Int},rank::Int,exact::Bool)
    spans=NTuple{5,Int}[]
    for (i,e) in enumerate(graph.edges)
        jog=exact ? centers[e.from]!=centers[e.to] : abs(centers[e.from]-centers[e.to])>1
        if e.from!=e.to&&ranks[e.from]==rank&&ranks[e.to]==rank+1&&jog
            push!(spans,(min(centers[e.from],centers[e.to]),max(centers[e.from],centers[e.to]),e.from,e.to,i))
        end
    end
    spans
end
function mermaid_lane_spans(graph::MermaidGraph,ranks::Vector{Int},placed::Vector{MermaidPlaced},vertical::Bool)
    spans=NTuple{5,Int}[]
    for (i,e) in enumerate(graph.edges)
        (e.from==e.to||ranks[e.to]==ranks[e.from]+1)&&continue
        from=placed[e.from];to=placed[e.to]
        a,b=minmax(vertical ? from.cy : from.cx,vertical ? to.cy : to.cx)
        push!(spans,(a,b,e.from,e.to,i))
    end
    spans
end
function mermaid_buses(graph::MermaidGraph,ranks::Vector{Int},centers::Vector{Int},count::Int,exact::Bool)
    bus=zeros(Int,length(graph.edges));tracks=zeros(Int,count)
    for rank in 0:count-2
        spans=mermaid_bus_spans(graph,ranks,centers,rank,exact)
        isempty(spans)&&continue
        assigned=mermaid_tracks(spans)
        for (index,slot) in assigned.assigned
            bus[index]=slot
        end
        tracks[rank+1]=assigned.count
    end
    bus,tracks
end
function mermaid_lanes(graph::MermaidGraph,ranks::Vector{Int},placed::Vector{MermaidPlaced},vertical::Bool,content_size::Int)
    edge_lane=zeros(Int,length(graph.edges));lanes=mermaid_lane_spans(graph,ranks,placed,vertical)
    count=0;base=0
    if !isempty(lanes)
        assigned=mermaid_tracks(lanes)
        for (index,slot) in assigned.assigned
            edge_lane[index]=slot
        end
        count=assigned.count;base=content_size+1
    end
    (;edge_lane,base,size=count==0 ? content_size : content_size+1+count)
end
function mermaid_place_vertical!(graph::MermaidGraph,ranks::Vector{Int},rows::Vector{Vector{Int}},sizes::MermaidSizes,placed::Vector{MermaidPlaced})
    centers=mermaid_positions(rows,sizes.layout_widths,3,graph.edges,ranks)
    bus,tracks=mermaid_buses(graph,ranks,centers,length(rows),false)
    heights=[isempty(row) ? 3 : maximum(sizes.heights[i]+sizes.extra_heights[i] for i in row) for row in rows]
    ys=zeros(Int,length(rows))
    for r in 2:length(rows)
        ys[r]=ys[r-1]+heights[r-1]+max(2,tracks[r-1]+1)
    end
    height=last(ys)+last(heights);bands=ys.+heights;diagram_width=1
    for (r,row) in enumerate(rows),i in row
        w=sizes.widths[i];h=sizes.heights[i];cx=centers[i];x=mermaid_sat(cx,fld(w,2));y=ys[r]+fld(heights[r]-h-sizes.extra_heights[i],2)
        placed[i]=MermaidPlaced(;x,y,width=w,height=h,cx,cy=y+fld(h,2),rank=r-1)
        diagram_width=max(diagram_width,x+w)
        sizes.extra_heights[i]>0&&sizes.self_label_widths[i]>0&&(diagram_width=max(diagram_width,x+w+2+sizes.self_label_widths[i]))
    end
    content_width=diagram_width
    for e in graph.edges
        (e.from==e.to||isnothing(e.label))&&continue
        width=min(mermaid_width(e.label),MERMAID_MAX_LABEL)
        content_width=max(content_width,ranks[e.to]==ranks[e.from]+1 ? placed[e.to].cx+2+width : diagram_width+width+1)
    end
    lanes=mermaid_lanes(graph,ranks,placed,true,content_width)
    MermaidRoutePlan(lanes.size,height,bands,bus,lanes.base,lanes.edge_lane)
end
function mermaid_place_horizontal!(graph::MermaidGraph,ranks::Vector{Int},rows::Vector{Vector{Int}},sizes::MermaidSizes,placed::Vector{MermaidPlaced})
    widths=[maximum((sizes.widths[i] for i in row);init=0) for row in rows]
    labelwidth=maximum((min(mermaid_width(e.label),MERMAID_MAX_LABEL) for e in graph.edges if (e.from==e.to||ranks[e.to]==ranks[e.from]+1)&&!isnothing(e.label));init=0)
    gap=max(4,labelwidth+3);centers=mermaid_positions(rows,sizes.layout_heights,1,graph.edges,ranks)
    bus,tracks=mermaid_buses(graph,ranks,centers,length(rows),true);xs=zeros(Int,length(rows))
    for r in 2:length(rows)
        xs[r]=xs[r-1]+widths[r-1]+max(gap,tracks[r-1]+1)
    end
    tail=maximum((2+sizes.self_label_widths[i] for i in last(rows) if sizes.extra_heights[i]>0&&sizes.self_label_widths[i]>0);init=0)
    width=last(xs)+last(widths)+tail;bands=xs.+widths;diagram_height=1
    for (r,row) in enumerate(rows),i in row
        x=xs[r];w=sizes.widths[i];h=sizes.heights[i];y=mermaid_sat(centers[i],fld(h+sizes.extra_heights[i],2))
        placed[i]=MermaidPlaced(;x,y,width=w,height=h,rank=r-1)
        diagram_height=max(diagram_height,y+h+sizes.extra_heights[i])
    end
    lanes=mermaid_lanes(graph,ranks,placed,false,diagram_height)
    MermaidRoutePlan(width,lanes.size,bands,bus,lanes.base,lanes.edge_lane)
end
