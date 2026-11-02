# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
function mermaid_draw_box!(canvas::MermaidCanvas,p::MermaidPlaced,lines::Vector{String},shape::Symbol)
    x=p.x;y=p.y;right=x+p.width-1;bottom=y+p.height-1;rounded=shape in (:round,:diamond)
    mermaid_set!(canvas,x,y,rounded ? "╭" : "┌",:border);mermaid_set!(canvas,right,y,rounded ? "╮" : "┐",:border)
    mermaid_set!(canvas,x,bottom,rounded ? "╰" : "└",:border);mermaid_set!(canvas,right,bottom,rounded ? "╯" : "┘",:border)
    for cx in x+1:right-1
        mermaid_bits!(canvas,cx,y,MERMAID_L|MERMAID_R,:border);mermaid_bits!(canvas,cx,bottom,MERMAID_L|MERMAID_R,:border)
    end
    for cy in y+1:bottom-1
        mermaid_bits!(canvas,x,cy,MERMAID_U|MERMAID_D,:border);mermaid_bits!(canvas,right,cy,MERMAID_U|MERMAID_D,:border)
    end
    for cy in y:bottom,cx in x:right
        mermaid_inside(canvas,cx,cy)&&(canvas.occupied[mermaid_index(canvas,cx,cy)]=true)
    end
    inner=max(1,p.width-4)
    for (i,line) in enumerate(lines)
        text=mermaid_fit_label(line,inner);tx=x+2+fld(mermaid_sat(inner,mermaid_width(text)),2)
        mermaid_text!(canvas,text,tx,y+i,:text)
    end
    nothing
end
function mermaid_draw_class!(canvas::MermaidCanvas,p::MermaidPlaced,sections::Vector{Vector{String}})
    mermaid_draw_box!(canvas,p,String[],:rect);inner=max(1,p.width-4);row=p.y+1;first=true
    for (section_index,section) in enumerate(sections)
        isempty(section)&&continue
        if !first
            mermaid_set!(canvas,p.x,row,"├",:border)
            for x in p.x+1:p.x+p.width-2
                mermaid_set!(canvas,x,row,"─",:border)
            end
            mermaid_set!(canvas,p.x+p.width-1,row,"┤",:border);row+=1
        end
        first=false
        for line in section
            text=mermaid_fit_label(line,inner);x=p.x+2+(section_index==1 ? fld(mermaid_sat(inner,mermaid_width(text)),2) : 0)
            mermaid_text!(canvas,text,x,row,:text;overwrite=true);row+=1
        end
    end
    nothing
end
function mermaid_draw_frame!(canvas::MermaidCanvas,p::MermaidPlaced,title::String,sub::MermaidCanvas)
    mermaid_draw_box!(canvas,p,String[],:rect)
    mermaid_text!(canvas," "*mermaid_fit_label(title,max(0,p.width-4))*" ",p.x+1,p.y,:text;overwrite=true)
    mermaid_blit!(canvas,sub,p.x+1+fld(p.width-2-sub.width,2),p.y+1+fld(p.height-2-sub.height,2))
    nothing
end
mermaid_head(head::Symbol,arrow::String)=head==:circle ? "o" : head==:cross ? "×" : head==:diamondFill ? "◆" :
    head==:diamondOpen ? "◇" : head==:triangle ? get(Dict("▼"=>"▽","▲"=>"△","◄"=>"◁","▶"=>"▷"),arrow,arrow) : arrow
function mermaid_edge_label!(canvas::MermaidCanvas,label::String,row::Int,x::Int)
    row>=canvas.height&&return nothing
    for (glyph,width) in mermaid_measured(mermaid_fit_label(label,MERMAID_MAX_LABEL))
        width==0&&continue
        x+width>canvas.width&&break
        blocked=any(k->begin
            i=mermaid_index(canvas,x+k,row)
            canvas.chars[i]!=" "||canvas.mask[i]!=0||canvas.occupied[i]
        end,0:width-1)
        blocked&&break
        mermaid_set!(canvas,x,row,glyph,:edgeLabel)
        for k in 1:width-1
            mermaid_set!(canvas,x+k,row,MERMAID_CONT,:edgeLabel)
        end
        x+=width
    end
    nothing
end
function mermaid_route_forward!(c::MermaidCanvas,from::MermaidPlaced,to::MermaidPlaced,e::MermaidEdge,bus::Int,::Val{:vertical})
    tx=to.cx;bx=abs(from.cx-tx)<=1 ? tx : from.cx;by=from.y+from.height-1;headrow=to.y-1
    mermaid_junction!(c,bx,by,MERMAID_D);mermaid_vertical!(c,bx,by,bus)
    if bx==tx
        mermaid_vertical!(c,bx,bus,headrow)
    else
        mermaid_horizontal!(c,bus,bx,tx);mermaid_vertical!(c,tx,bus,headrow)
    end
    e.head_to==:none ? mermaid_bits!(c,tx,headrow,MERMAID_U) : mermaid_set!(c,tx,headrow,mermaid_head(e.head_to,"▼"),:edge)
    e.head_from==:none||mermaid_set!(c,bx,by,mermaid_head(e.head_from,"▲"),:edge)
    isnothing(e.label)||mermaid_edge_label!(c,e.label,headrow,tx+1)
    nothing
end
function mermaid_route_forward!(c::MermaidCanvas,from::MermaidPlaced,to::MermaidPlaced,e::MermaidEdge,bus::Int,::Val{:horizontal})
    rx=from.x+from.width-1;ry=from.cy;ly=to.cy;headcol=to.x-1
    mermaid_junction!(c,rx,ry,MERMAID_R);mermaid_horizontal!(c,ry,rx,bus)
    if ry==ly
        mermaid_horizontal!(c,ry,bus,headcol)
    else
        mermaid_vertical!(c,bus,ry,ly);mermaid_horizontal!(c,ly,bus,headcol)
    end
    e.head_to==:none ? mermaid_bits!(c,headcol,ly,MERMAID_R) : mermaid_set!(c,headcol,ly,mermaid_head(e.head_to,"▶"),:edge)
    e.head_from==:none||mermaid_set!(c,rx,ry,mermaid_head(e.head_from,"◄"),:edge)
    isnothing(e.label)||mermaid_edge_label!(c,e.label,max(0,ly-1),bus+1)
    nothing
end
function mermaid_route_back!(c::MermaidCanvas,from::MermaidPlaced,to::MermaidPlaced,e::MermaidEdge,lane::Int,::Val{:vertical})
    sx=from.x+from.width-1;sy=from.cy;tx=to.x+to.width-1;ty=to.cy
    mermaid_junction!(c,sx,sy,MERMAID_R);mermaid_horizontal!(c,sy,sx,lane);mermaid_vertical!(c,lane,sy,ty);mermaid_horizontal!(c,ty,tx+1,lane)
    e.head_to==:none ? mermaid_bits!(c,tx+1,ty,MERMAID_R) : mermaid_set!(c,tx+1,ty,mermaid_head(e.head_to,"◄"),:edge)
    e.head_from==:none||mermaid_set!(c,sx,sy,mermaid_head(e.head_from,"◄"),:edge)
    isnothing(e.label)||mermaid_edge_label!(c,e.label,max(0,ty-1),max(0,lane-mermaid_width(e.label)-1))
    nothing
end
function mermaid_route_back!(c::MermaidCanvas,from::MermaidPlaced,to::MermaidPlaced,e::MermaidEdge,lane::Int,::Val{:horizontal})
    sx=from.cx;sy=from.y+from.height-1;tx=to.cx;ty=to.y+to.height-1
    mermaid_junction!(c,sx,sy,MERMAID_D);mermaid_vertical!(c,sx,sy,lane);mermaid_horizontal!(c,lane,sx,tx);mermaid_vertical!(c,tx,lane,ty+1)
    e.head_to==:none ? mermaid_bits!(c,tx,ty+1,MERMAID_D) : mermaid_set!(c,tx,ty+1,mermaid_head(e.head_to,"▲"),:edge)
    e.head_from==:none||mermaid_set!(c,sx,sy,mermaid_head(e.head_from,"▲"),:edge)
    isnothing(e.label)||mermaid_edge_label!(c,e.label,max(0,lane-1),fld(sx+tx,2))
    nothing
end
function mermaid_route_self!(c::MermaidCanvas,p::MermaidPlaced,e::MermaidEdge)
    bottom=p.y+p.height-1;exit=p.cx+1;ret=p.x+p.width-2
    ret<=exit||bottom+2>=c.height ? (return nothing) : nothing
    vertical,horizontal,bl,br=e.line==:dotted ? ("╎","╌","╰","╯") : e.line==:thick ? ("┃","━","┗","┛") : ("│","─","╰","╯")
    mermaid_junction!(c,exit,bottom,MERMAID_D);mermaid_set!(c,exit,bottom+1,vertical,:edge);mermaid_set!(c,exit,bottom+2,bl,:edge)
    for x in exit+1:ret-1
        mermaid_set!(c,x,bottom+2,horizontal,:edge)
    end
    mermaid_set!(c,ret,bottom+2,br,:edge);mermaid_set!(c,ret,bottom+1,mermaid_head(e.head_to,"▲"),:edge)
    isnothing(e.label)||mermaid_edge_label!(c,e.label,bottom+1,p.x+p.width+1)
    nothing
end
