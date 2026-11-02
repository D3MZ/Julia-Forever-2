# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
"""Rank, place and route graph cells without invoking external programs or unbounded canvas allocation."""
function mermaid_layout_canvas(graph::MermaidGraph,extras::Vector{MermaidExtra})
    n=length(graph.nodes);n==0&&return nothing
    ranks=mermaid_ranks(graph);rows=[Int[] for _ in 0:maximum(ranks)]
    for i in eachindex(ranks)
        push!(rows[ranks[i]+1],i)
    end
    mermaid_order_ranks!(rows,graph.edges,ranks)
    wrapped=[mermaid_wrap_label(node.label) for node in graph.nodes]
    widest(lines)=max(1,maximum((mermaid_width(line) for line in lines);init=0))
    widths=Int[];heights=Int[]
    for (i,extra) in enumerate(extras)
        if extra.kind==:frame
            sub=extra.canvas::MermaidCanvas
            push!(widths,max(sub.width+2,mermaid_width(mermaid_fit_label(graph.nodes[i].label,24))+4));push!(heights,sub.height+2)
        elseif extra.kind==:compartments
            push!(widths,widest(Iterators.flatten(extra.sections))+4)
            push!(heights,sum(length,extra.sections)+max(0,count(!isempty,extra.sections)-1)+2)
        else
            push!(widths,widest(wrapped[i])+4);push!(heights,length(wrapped[i])+2)
        end
    end
    extra_heights=zeros(Int,n);self_widths=zeros(Int,n)
    for e in graph.edges
        e.from==e.to||continue
        extra_heights[e.from]=2
        isnothing(e.label)||(self_widths[e.from]=max(self_widths[e.from],min(mermaid_width(e.label),28)))
    end
    for i in 1:n
        extra_heights[i]>0&&(widths[i]=max(widths[i],7))
    end
    sizes=MermaidSizes(widths,heights,[widths[i]+(self_widths[i]>0 ? 2*(self_widths[i]+3) : 0) for i in 1:n],heights.+extra_heights,extra_heights,self_widths)
    placed=Vector{MermaidPlaced}(undef,n);vertical=graph.direction in (:down,:up)
    plan=vertical ? mermaid_place_vertical!(graph,ranks,rows,sizes,placed) : mermaid_place_horizontal!(graph,ranks,rows,sizes,placed)
    plan.height>0&&plan.width<=MERMAID_MAX_CELLS÷plan.height||return nothing
    canvas=MermaidCanvas(plan.width,plan.height)
    for (i,extra) in enumerate(extras)
        if extra.kind==:frame
            mermaid_draw_frame!(canvas,placed[i],graph.nodes[i].label,extra.canvas::MermaidCanvas)
        elseif extra.kind==:compartments
            mermaid_draw_class!(canvas,placed[i],extra.sections)
        else
            mermaid_draw_box!(canvas,placed[i],wrapped[i],graph.nodes[i].shape)
        end
    end
    orientation=vertical ? Val(:vertical) : Val(:horizontal)
    for (i,e) in enumerate(graph.edges)
        canvas.current_stroke=e.line==:dotted ? UInt8(1) : e.line==:thick ? UInt8(2) : UInt8(4)
        if e.from==e.to
            mermaid_route_self!(canvas,placed[e.from],e)
        else
            from=placed[e.from];to=placed[e.to]
            if to.rank==from.rank+1
                mermaid_route_forward!(canvas,from,to,e,plan.band_end[from.rank+1]+plan.edge_bus[i],orientation)
            else
                mermaid_route_back!(canvas,from,to,e,plan.lane_base+plan.edge_lane[i],orientation)
            end
        end
    end
    mermaid_finalize!(canvas)
end
function mermaid_layout_flow(graph::MermaidGraph)
    canvas=mermaid_layout_canvas(graph,[MermaidExtra() for _ in graph.nodes])
    isnothing(canvas) ? nothing : mermaid_orient!(canvas,graph.direction)
end
function mermaid_layout_class(graph::MermaidGraph,infos::Vector{MermaidClass})
    extras=MermaidExtra[]
    for (i,node) in enumerate(graph.nodes)
        title=String[];info=infos[i]
        isnothing(info.annotation)||push!(title,"«$(info.annotation)»")
        push!(title,mermaid_generics(node.label))
        push!(extras,MermaidExtra(;kind=:compartments,sections=[title,info.attrs,info.methods]))
    end
    canvas=mermaid_layout_canvas(graph,extras)
    isnothing(canvas) ? nothing : mermaid_orient!(canvas,graph.direction)
end
function mermaid_group_chain(graph::MermaidGraph,group::Int)
    chain=Int[]
    while group>0
        push!(chain,group);group=graph.groups[group].parent
    end
    reverse(chain)
end
function mermaid_layout_grouped(graph::MermaidGraph)
    proxies=Dict{Int,Int}()
    for (i,g) in enumerate(graph.groups)
        node=get(graph.index,g.id,0);node>0&&(proxies[node]=i)
    end
    endpoint(n)=haskey(proxies,n) ? ((:group,proxies[n]),mermaid_group_chain(graph,graph.groups[proxies[n]].parent)) : ((:node,n),mermaid_group_chain(graph,graph.node_group[n]))
    scope_edges=Dict{Int,Vector{Tuple{Tuple{Symbol,Int},Tuple{Symbol,Int},Int}}}();referenced=falses(length(graph.groups))
    for (i,e) in enumerate(graph.edges)
        fk,fc=endpoint(e.from);tk,tc=endpoint(e.to);k=0
        while k<length(fc)&&k<length(tc)&&fc[k+1]==tc[k+1]
            k+=1
        end
        scope=k==0 ? 0 : fc[k];from=length(fc)>k ? (:group,fc[k+1]) : fk;to=length(tc)>k ? (:group,tc[k+1]) : tk
        for key in (from,to)
            key[1]==:group&&(referenced[key[2]]=true)
        end
        push!(get!(scope_edges,scope,Tuple{Tuple{Symbol,Int},Tuple{Symbol,Int},Int}[]),(from,to,i))
    end
    direct=Dict{Int,Vector{Int}}()
    for (i,g) in enumerate(graph.node_group)
        haskey(proxies,i)||push!(get!(direct,g,Int[]),i)
    end
    keep=falses(length(graph.groups))
    for i in length(graph.groups):-1:1
        keep[i]=!isempty(get(direct,i,Int[]))||any(j->graph.groups[j].parent==i&&keep[j],eachindex(graph.groups))||referenced[i]
    end
    canvas=mermaid_build_scope(graph,0,scope_edges,direct,keep)
    isnothing(canvas) ? nothing : mermaid_orient!(canvas,graph.direction)
end
function mermaid_build_scope(graph::MermaidGraph,scope::Int,scope_edges,direct::Dict{Int,Vector{Int}},keep::BitVector)
    items=Tuple{Symbol,Int}[(:node,i) for i in get(direct,scope,Int[])]
    append!(items,[(:group,i) for i in eachindex(graph.groups) if graph.groups[i].parent==scope&&keep[i]])
    isempty(items)&&return MermaidCanvas(1,1)
    indexes=Dict{Tuple{Symbol,Int},Int}();nodes=MermaidNode[];extras=MermaidExtra[]
    for item in items
        kind,i=item;indexes[item]=length(nodes)+1
        if kind==:node
            push!(nodes,graph.nodes[i]);push!(extras,MermaidExtra())
        else
            sub=mermaid_build_scope(graph,i,scope_edges,direct,keep);isnothing(sub)&&return nothing
            push!(nodes,MermaidNode(;label=graph.groups[i].label));push!(extras,MermaidExtra(;kind=:frame,canvas=sub))
        end
    end
    edges=MermaidEdge[]
    for (fk,tk,index) in get(scope_edges,scope,Tuple{Tuple{Symbol,Int},Tuple{Symbol,Int},Int}[])
        from=get(indexes,fk,0);to=get(indexes,tk,0);(from==0||to==0)&&continue
        e=graph.edges[index];push!(edges,MermaidEdge(;from,to,label=e.label,head_to=e.head_to,head_from=e.head_from,line=e.line))
    end
    mermaid_layout_canvas(MermaidGraph(;nodes,edges,direction=graph.direction),extras)
end
