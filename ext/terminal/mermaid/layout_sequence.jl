# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
mermaid_sequence_height(item::MermaidSequenceItem)=item.kind==:note ? 4 : item.kind==:divider ? 2 : item.from==item.to ? 4 : isnothing(item.text) ? 2 : 3
function mermaid_note_geometry(xs::Vector{Int},item::MermaidSequenceItem,textwidth::Int)
    if item.anchor==:over
        center=fld(xs[item.from]+xs[item.to],2);width=max(xs[item.to]-xs[item.from]+5,textwidth+4)
        (x=max(0,center-fld(width,2)),width)
    else
        width=textwidth+4
        (x=item.anchor==:left ? max(0,xs[item.from]-(2+width-1)) : xs[item.from]+2,width)
    end
end
function mermaid_sequence_requirements(sequence::MermaidSequence,widths::Vector{Int})
    n=length(widths);requirements=NTuple{3,Int}[]
    for item in sequence.items
        tw=isnothing(item.text) ? 0 : mermaid_width(item.text)
        if item.kind==:message
            if item.from!=item.to
                push!(requirements,(min(item.from,item.to),max(item.from,item.to),max(tw+2,4)))
            elseif item.from<n
                push!(requirements,(item.from,item.from+1,7+tw))
            end
        elseif item.kind==:note
            a=item.from;b=item.to
            if item.anchor==:over&&a<b
                push!(requirements,(a,b,max(0,tw-1)))
            elseif item.anchor==:over
                need=cld(tw+4,2)+2
                a>1&&push!(requirements,(a-1,a,need));a<n&&push!(requirements,(a,a+1,need))
            elseif item.anchor==:left&&a>1
                push!(requirements,(a-1,a,tw+7))
            elseif item.anchor==:right&&a<n
                push!(requirements,(a,a+1,tw+7))
            end
        end
    end
    requirements
end
function mermaid_sequence_message!(canvas::MermaidCanvas,item::MermaidSequenceItem,xs::Vector{Int},row::Int)
    line=item.dashed ? "╌" : "─"
    if item.from==item.to
        x=xs[item.from];mermaid_junction!(canvas,x,row,MERMAID_R)
        mermaid_set!(canvas,x+1,row,line,:edge);mermaid_set!(canvas,x+2,row,line,:edge);mermaid_set!(canvas,x+3,row,"╮",:edge)
        mermaid_set!(canvas,x+3,row+1,"│",:edge);mermaid_set!(canvas,x+1,row+2,item.head==:cross ? "×" : "◄",:edge)
        mermaid_set!(canvas,x+2,row+2,line,:edge);mermaid_set!(canvas,x+3,row+2,"╯",:edge)
        isnothing(item.text)||mermaid_text!(canvas,item.text,x+5,row+1,:text;overwrite=true)
    else
        x0=xs[item.from];x1=xs[item.to];right=x1>x0;arrowrow=isnothing(item.text) ? row : row+1;lo,hi=minmax(x0,x1)
        mermaid_junction!(canvas,x0,arrowrow,right ? MERMAID_R : MERMAID_L)
        for x in lo+1:hi-1
            mermaid_set!(canvas,x,arrowrow,line,:edge)
        end
        head=item.head==:cross ? "×" : right ? "▶" : "◄"
        mermaid_set!(canvas,right ? x1-1 : x1+1,arrowrow,head,:edge)
        if !isnothing(item.text)
            span=hi-lo-1;text=mermaid_fit_label(item.text,max(1,span))
            mermaid_text!(canvas,text,lo+1+fld(max(0,span-mermaid_width(text)),2),row,:text;overwrite=true)
        end
    end
    nothing
end
function mermaid_layout_sequence(sequence::MermaidSequence)
    n=length(sequence.labels);labels=[mermaid_fit_label(label,24) for label in sequence.labels]
    widths=[max(1,mermaid_width(label))+4 for label in labels]
    gaps=[max(5,cld(widths[i],2)+cld(widths[i+1],2)+1) for i in 1:n-1]
    requirements=mermaid_sequence_requirements(sequence,widths)
    sort!(requirements;by=item->item[2]-item[1],alg=Base.Sort.MergeSort)
    for (left,right,need) in requirements
        current=sum(gaps[left:right-1])
        current<need&&(gaps[right-1]+=need-current)
    end
    xs=zeros(Int,n);xs[1]=fld(widths[1],2)
    for i in 2:n
        xs[i]=xs[i-1]+gaps[i-1]
    end
    width=last(xs)+cld(last(widths),2)+1
    for item in sequence.items
        if item.kind==:message&&item.from==item.to
            width=max(width,xs[item.from]+6+(isnothing(item.text) ? 0 : mermaid_width(item.text)))
        elseif item.kind==:note
            geometry=mermaid_note_geometry(xs,item,mermaid_width(something(item.text,"")))
            width=max(width,geometry.x+geometry.width+1)
        elseif item.kind==:divider
            width=max(width,mermaid_width(something(item.text,""))+4)
        end
    end
    rows=Int[];y=4
    for item in sequence.items
        push!(rows,y);y+=mermaid_sequence_height(item)
    end
    bottom=y;height=bottom+3
    width<=MERMAID_MAX_CELLS÷height||return nothing
    canvas=MermaidCanvas(width,height)
    for i in 1:n,by in (0,bottom)
        p=MermaidPlaced(;x=max(0,xs[i]-fld(widths[i],2)),y=by,width=widths[i],height=3)
        mermaid_draw_box!(canvas,p,[labels[i]],:rect)
    end
    for (index,item) in enumerate(sequence.items)
        if item.kind==:note
            text=something(item.text,"");geometry=mermaid_note_geometry(xs,item,mermaid_width(text))
            p=MermaidPlaced(;x=geometry.x,y=rows[index],width=geometry.width,height=3)
            mermaid_draw_box!(canvas,p,[text],:rect)
        end
    end
    for x in xs
        mermaid_junction!(canvas,x,2,MERMAID_D);mermaid_vertical!(canvas,x,3,bottom-1);mermaid_junction!(canvas,x,bottom,MERMAID_U)
    end
    for (index,item) in enumerate(sequence.items)
        row=rows[index]
        if item.kind==:message
            mermaid_sequence_message!(canvas,item,xs,row)
        elseif item.kind==:divider
            for x in 0:width-1
                mermaid_set!(canvas,x,row,"─",:edge)
            end
            mermaid_text!(canvas," "*mermaid_fit_label(something(item.text,""),max(0,width-4))*" ",2,row,:edgeLabel;overwrite=true)
        end
    end
    mermaid_finalize!(canvas)
end
