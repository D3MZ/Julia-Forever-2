"""Allocate bounded table columns from natural widths and indivisible words."""
function command_table_widths(cells,capacity::Int)
    count=length(first(cells))
    available=capacity-3count-1
    if available<count
        nothing
    else
        text=[[join(span.content for span in cell) for cell in row] for row in cells]
        natural=[maximum(textwidth(row[col]) for row in text) for col in 1:count]
        words=[max(1,maximum(min(30,textwidth(word)) for row in text for word in split(row[col]);init=0)) for col in 1:count]
        minimums=copy(words)
        if sum(minimums)>available
            weights=max.(0,words.-1)
            total=sum(weights)
            growth=total>0 ? floor.(Int,weights./total.*(available-count)) : zeros(Int,count)
            minimums=ones(Int,count)+growth
            leftover=available-sum(minimums)
            for col in 1:leftover
                minimums[col]+=1
            end
        end
        if sum(natural)<=available
            max.(natural,minimums)
        else
            weights=max.(0,natural.-minimums)
            total=sum(weights)
            growth=total>0 ? floor.(Int,weights./total.*max(0,available-sum(minimums))) : zeros(Int,count)
            widths=minimums+growth
            remaining=available-sum(widths)
            while remaining>0 && any(widths.<natural)
                for col in 1:count
                    if remaining>0 && widths[col]<natural[col]
                        widths[col]+=1
                        remaining-=1
                    end
                end
            end
            widths
        end
    end
end

function command_inline_keys(text::AbstractString)
    parts=split(text,'`';keepempty=true)
    [Tachikoma.Span(replace(String(part),"\\|"=>"|"),isodd(index) ? Tachikoma.Style() : session_display_style(:code)) for (index,part) in enumerate(parts)]
end

function command_table_rows(cells,width::Int)
    widths=command_table_widths(cells,width)
    if isnothing(widths)
        rows=SessionDisplayRows()
        for row in cells
            text="| "*join((join(span.content for span in cell) for cell in row)," | ")*" |"
            append!(rows,session_display_text_rows(text,width,0))
        end
        rows
    else
        rows=SessionDisplayRows()
        border=(left,middle,right)->[Tachikoma.Span(left*join(repeat.("─",widths),middle)*right,Tachikoma.Style())]
        push!(rows,border("┌─","─┬─","─┐"))
        for (index,row) in enumerate(cells)
            wrapped=[session_display_wrap(cell,widths[col],0) for (col,cell) in enumerate(row)]
            height=maximum(length,wrapped)
            for line in 1:height
                spans=[Tachikoma.Span("│ ",Tachikoma.Style())]
                for col in eachindex(widths)
                    content=line<=length(wrapped[col]) ? wrapped[col][line] : session_display_blank(widths[col])
                    for span in content
                        old=span.style
                        style=index==1 ? Tachikoma.Style(;fg=old.fg,bg=old.bg,bold=true,dim=old.dim,italic=old.italic,underline=old.underline,strikethrough=old.strikethrough) : old
                        push!(spans,Tachikoma.Span(span.content,style))
                    end
                    push!(spans,Tachikoma.Span(col==length(widths) ? " │" : " │ ",Tachikoma.Style()))
                end
                push!(rows,spans)
            end
            index<length(cells) && push!(rows,border("├─","─┼─","─┤"))
        end
        push!(rows,border("└─","─┴─","─┘"))
        rows
    end
end

"""Render the generated shortcut document with native styled cells and source-equivalent table wrapping."""
function command_hotkeys_rows(markdown::AbstractString,width::Int)
    rows=SessionDisplayRows()
    capacity=max(1,width-2)
    for (group_index,group) in enumerate(split(markdown,"\n\n"))
        lines=split(group,'\n')
        heading=replace(String(first(lines)),"**"=>"")
        group_index>1 && push!(rows,session_display_blank(width))
        append!(rows,session_display_text_rows(heading,width,1;style=session_display_style(:default;bold=true)))
        push!(rows,session_display_blank(width))
        cells=Vector{Vector{Tachikoma.Span}}[]
        for (index,line) in enumerate(lines[2:end])
            if index!=2
                values=strip.(split(strip(line,'|'),r"(?<!\\)\|"))
                push!(cells,command_inline_keys.(values))
            end
        end
        for row in command_table_rows(cells,capacity)
            push!(rows,[Tachikoma.Span(" ",Tachikoma.Style());row;Tachikoma.Span(repeat(" ",max(1,width-1-sum(span->textwidth(span.content),row))),Tachikoma.Style())])
        end
    end
    rows
end
