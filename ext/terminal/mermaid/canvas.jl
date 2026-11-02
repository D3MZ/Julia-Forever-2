# Native Julia adaptation of grok-mermaid 0.2.3; Apache-2.0.
const MERMAID_CONT="\0"
const MERMAID_CELL_BUDGET=Base.ScopedValues.ScopedValue{Union{Nothing,Base.RefValue{Int}}}(nothing)
const MERMAID_U=UInt8(1)
const MERMAID_D=UInt8(2)
const MERMAID_L=UInt8(4)
const MERMAID_R=UInt8(8)
const MERMAID_DOTTED=Dict("─"=>"╌","│"=>"╎")
const MERMAID_THICK=Dict(a=>b for (a,b) in zip(string.(collect("─│┌┐└┘├┤┬┴┼")),string.(collect("━┃┏┓┗┛┣┫┳┻╋"))))
const MERMAID_FLIP_V=Dict(a=>b for (a,b) in zip(string.(collect("┌└┐┘┏┗┓┛╭╰╮╯┬┴┳┻▼▲▽△")),string.(collect("└┌┘┐┗┏┛┓╰╭╯╮┴┬┻┳▲▼△▽"))))
const MERMAID_FLIP_H=Dict(a=>b for (a,b) in zip(string.(collect("┌┐└┘┏┓┗┛╭╮╰╯├┤┣┫▶◄▷◁")),string.(collect("┐┌┘└┓┏┛┗╮╭╯╰┤├┫┣◄▶◁▷"))))
const MERMAID_MASK_GLYPHS=string.(collect(" │││─┘┐┤─└┌├─┴┬┼"))

"""Bounded semantic cells use zero-based coordinates, with wide continuations never emitted."""
mutable struct MermaidCanvas
    width::Int
    height::Int
    chars::Vector{String}
    classes::Vector{Symbol}
    mask::Vector{UInt8}
    strokes::Vector{UInt8}
    occupied::BitVector
    current_stroke::UInt8
end
function MermaidCanvas(width::Int,height::Int)
    0<width&&0<height&&width<=MERMAID_MAX_CELLS÷height||error("Mermaid canvas exceeds its cell bound")
    count=width*height
    budget=MERMAID_CELL_BUDGET[]
    if !isnothing(budget)
        count<=budget[]||error("Mermaid nested canvases exceed the total cell bound")
        budget[]-=count
    end
    MermaidCanvas(width,height,fill(" ",count),fill(:none,count),zeros(UInt8,count),zeros(UInt8,count),falses(count),UInt8(4))
end
mermaid_inside(c::MermaidCanvas,x::Int,y::Int)=0<=x<c.width&&0<=y<c.height
mermaid_index(c::MermaidCanvas,x::Int,y::Int)=y*c.width+x+1
function mermaid_set!(c::MermaidCanvas,x::Int,y::Int,text::AbstractString,kind::Symbol)
    if mermaid_inside(c,x,y)
        i=mermaid_index(c,x,y);c.chars[i]=String(text);c.classes[i]=kind
    end
    nothing
end
function mermaid_bits!(c::MermaidCanvas,x::Int,y::Int,bits::UInt8,kind::Symbol=:edge;force::Bool=false)
    if mermaid_inside(c,x,y)
        i=mermaid_index(c,x,y)
        if force||!c.occupied[i]
            c.mask[i]|=bits
            force||(c.strokes[i]|=c.current_stroke)
            c.classes[i]==:border||(c.classes[i]=kind)
        end
    end
    nothing
end
mermaid_junction!(c,x,y,bits)=mermaid_bits!(c,x,y,bits;force=true)
function mermaid_vertical!(c::MermaidCanvas,x::Int,a::Int,b::Int)
    low,high=minmax(a,b)
    for y in low:high
        mermaid_bits!(c,x,y,(y>low ? MERMAID_U : UInt8(0))|(y<high ? MERMAID_D : UInt8(0)))
    end
    nothing
end
function mermaid_horizontal!(c::MermaidCanvas,y::Int,a::Int,b::Int)
    low,high=minmax(a,b)
    for x in low:high
        mermaid_bits!(c,x,y,(x>low ? MERMAID_L : UInt8(0))|(x<high ? MERMAID_R : UInt8(0)))
    end
    nothing
end
function mermaid_finalize!(c::MermaidCanvas)
    for i in eachindex(c.chars)
        if c.mask[i]!=0&&c.chars[i]==" "
            glyph=MERMAID_MASK_GLYPHS[Int(c.mask[i])+1]
            c.chars[i]=c.strokes[i]==1 ? get(MERMAID_DOTTED,glyph,glyph) : c.strokes[i]==2 ? get(MERMAID_THICK,glyph,glyph) : glyph
        end
    end
    c
end
function mermaid_blit!(c::MermaidCanvas,sub::MermaidCanvas,ox::Int,oy::Int)
    for y in 0:sub.height-1,x in 0:sub.width-1
        if mermaid_inside(c,x+ox,y+oy)
            src=mermaid_index(sub,x,y);dst=mermaid_index(c,x+ox,y+oy)
            c.chars[dst]=sub.chars[src];c.classes[dst]=sub.classes[src]
            c.strokes[dst]=sub.strokes[src];c.occupied[dst]=true
        end
    end
    nothing
end
function mermaid_text!(c::MermaidCanvas,text::AbstractString,x::Int,y::Int,kind::Symbol;overwrite::Bool=false)
    for (cluster,width) in mermaid_measured(text)
        width==0&&continue
        for k in 0:width-1
            overwrite&&mermaid_inside(c,x+k,y)&&(c.mask[mermaid_index(c,x+k,y)]=0)
            mermaid_set!(c,x+k,y,k==0 ? cluster : MERMAID_CONT,kind)
        end
        x+=width
    end
    nothing
end
function mermaid_orient!(c::MermaidCanvas,direction::Symbol)
    if direction==:up
        for y in 0:fld(c.height,2)-1,x in 0:c.width-1
            a=mermaid_index(c,x,y);b=mermaid_index(c,x,c.height-1-y)
            c.chars[a],c.chars[b]=c.chars[b],c.chars[a]
            c.classes[a],c.classes[b]=c.classes[b],c.classes[a]
        end
        c.chars=map(g->get(MERMAID_FLIP_V,g,g),c.chars)
    elseif direction==:left
        for y in 0:c.height-1,x in 0:fld(c.width,2)-1
            a=mermaid_index(c,x,y);b=mermaid_index(c,c.width-1-x,y)
            c.chars[a],c.chars[b]=c.chars[b],c.chars[a]
            c.classes[a],c.classes[b]=c.classes[b],c.classes[a]
        end
        c.chars=map(g->get(MERMAID_FLIP_H,g,g),c.chars)
        for y in 0:c.height-1
            x=0
            while x<c.width
                kind=c.classes[mermaid_index(c,x,y)]
                if kind in (:text,:edgeLabel)
                    start=x
                    while x<c.width&&c.classes[mermaid_index(c,x,y)]==kind
                        x+=1
                    end
                    reverse!(c.chars,mermaid_index(c,start,y),mermaid_index(c,x-1,y))
                else
                    x+=1
                end
            end
        end
    end
    c
end
function mermaid_art(c::MermaidCanvas,warnings::Vector{String}=String[])
    plain=String[];styled=Vector{MermaidSpan}[];width=0
    for y in 0:c.height-1
        last=0
        for x in c.width-1:-1:0
            if c.chars[mermaid_index(c,x,y)]!=" "
                last=x+1;break
            end
        end
        width=max(width,last);spans=MermaidSpan[];row=IOBuffer();run=IOBuffer();kind=:none
        for x in 0:last-1
            i=mermaid_index(c,x,y);glyph=c.chars[i]
            glyph==MERMAID_CONT&&continue
            print(row,glyph)
            if c.classes[i]!=kind&&position(run)>0
                push!(spans,MermaidSpan(String(take!(run)),kind))
            end
            kind=c.classes[i];print(run,glyph)
        end
        position(run)>0&&push!(spans,MermaidSpan(String(take!(run)),kind))
        push!(styled,spans);push!(plain,rstrip(String(take!(row)),' '))
    end
    first=findfirst(!isempty,plain);last=findlast(!isempty,plain)
    isnothing(first) ? MermaidArt(String[],Vector{MermaidSpan}[],width,warnings) : MermaidArt(plain[first:last],styled[first:last],width,warnings)
end
