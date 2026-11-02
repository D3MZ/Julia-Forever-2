# Native archive rendering over owner-supplied rows and lifecycle state.
function resume_hint(menu::ResumeMenu,key::AbstractString,label::AbstractString)
    [session_span(menu,key,:dim),session_span(menu," "*label,:muted)]
end
function resume_header(menu::ResumeMenu,width::Int;selectors::NativeSelectorBindings=NativeSelectorBindings())
    title=menu.header_scope==:current ? "Resume Session (Current Folder)" : "Resume Session (All)"
    right=Tachikoma.Span[]
    if menu.loading
        progress=isnothing(menu.progress) ? "..." : "$(first(menu.progress))/$(last(menu.progress))"
        append!(right,[session_span(menu,"○ Current Folder | ",:muted),session_span(menu,"Loading "*progress,:accent)])
    elseif menu.header_scope==:current
        append!(right,[session_span(menu,"◉ Current Folder",:accent),session_span(menu," | ○ All",:muted)])
    else
        append!(right,[session_span(menu,"○ Current Folder | ",:muted),session_span(menu,"◉ All",:accent)])
    end
    append!(right,[session_span(menu,"  "),session_span(menu,"Name: ",:muted),session_span(menu,menu.names==:all ? "All" : "Named",:accent),
        session_span(menu,"  "),session_span(menu,"Sort: ",:muted),session_span(menu,menu.sort==:threaded ? "Threaded" : menu.sort==:recent ? "Recent" : "Fuzzy",:accent)])
    right=session_clip(right,width;marker="")
    left=session_clip(session_line(menu,title;bold=true),max(0,width-tree_width(right)-1);marker="")
    firstline=[left;session_span(menu,repeat(" ",max(0,width-tree_width(left)-tree_width(right))));right]
    second,third=Tachikoma.Span[],Tachikoma.Span[]
    if !isnothing(menu.confirming_delete)
        second=[session_span(menu,"Delete session? ",:error);resume_hint(menu,native_selector_text(selectors,:confirm),"confirm");
            session_span(menu," · ");resume_hint(menu,native_selector_text(selectors,:cancel),"cancel")]
        second=session_clip(second,width;marker="…")
    elseif !isnothing(menu.status)
        kind,message=menu.status
        second=session_clip(session_line(menu,message,kind==:error ? :error : :accent),width;marker="…")
    else
        sep=session_span(menu," · ",:muted)
        second=session_clip([resume_hint(menu,"tab","scope");sep;session_span(menu,"re:<pattern> regex · \"phrase\" exact",:muted)],width;marker="…")
        third=[resume_hint(menu,"ctrl+s","sort");sep;resume_hint(menu,"ctrl+n","named");sep;
            resume_hint(menu,"ctrl+d","delete");sep;resume_hint(menu,"ctrl+p",menu.show_path ? "path (on)" : "path (off)")]
        menu.show_rename && append!(third,[sep;resume_hint(menu,"ctrl+r","rename")])
        third=session_clip(third,width;marker="…")
    end
    [firstline,second,third]
end

function resume_age(menu::ResumeMenu,modified::Real)
    seconds=menu.now()-modified
    minutes,hours,days=floor(Int,seconds/60),floor(Int,seconds/3600),floor(Int,seconds/86400)
    minutes<1 ? "now" : minutes<60 ? "$(minutes)m" : hours<24 ? "$(hours)h" : days<7 ? "$(days)d" :
        days<30 ? "$(fld(days,7))w" : days<365 ? "$(fld(days,30))mo" : "$(fld(days,365))y"
end
function resume_shorten(menu::ResumeMenu,path::AbstractString)
    !isempty(menu.home) && (path==menu.home || startswith(path,menu.home*"/")) ? "~"*chop(path;head=length(menu.home),tail=0) : String(path)
end
function resume_row(menu::ResumeMenu,row::ResumeRow,selected::Bool,width::Int)
    entry=row.entry
    confirm=entry.path==menu.confirming_delete
    prefix=row.depth==0 ? "" : join(value ? "│  " : "   " for value in row.ancestors)*(row.last ? "└─ " : "├─ ")
    text=String(strip(replace(something(entry.name,entry.first_message),r"[\x00-\x1f\x7f]"=>" ")))
    right="$(entry.messages) "*resume_age(menu,entry.modified)
    if menu.show_cwd && !isempty(entry.cwd)
        right=resume_shorten(menu,entry.cwd)*" "*right
    end
    if menu.show_path
        right=resume_shorten(menu,entry.path)*" "*right
    end
    room=max(10,width-2-menu_search_width(prefix)-menu_search_width(right)-2)
    cut=menu_search_width(text)>room
    clipped=session_clip(session_line(menu,text),room;marker="…")
    color=confirm ? :error : resume_current(menu,entry.path) ? :accent : !isempty(something(entry.name,"")) ? :warning : :default
    body=[session_span(menu,span.content,color;selected,bold=selected) for span in clipped]
    if cut
        body[end]=session_span(menu,body[end].content)
    end
    left=[[session_span(menu,selected ? "› " : "  ",selected ? :accent : :default;selected),session_span(menu,prefix,:dim;selected)];body]
    spacing=repeat(" ",max(1,width-tree_width(left)-menu_search_width(right)))
    tail_selected=selected && !cut
    session_clip([left;session_span(menu,spacing;selected=tail_selected);session_span(menu,right,confirm ? :error : :dim;selected=tail_selected)],width)
end

function resume_list_lines(menu::ResumeMenu,width::Int)
    lines=[menu_search_spans(menu.search,width),session_line(menu)]
    count=length(menu.rows)
    if count==0
        message=if menu.names==:named
            menu.show_cwd ? "  No named sessions found. Press ctrl+n to show all." : "  No named sessions in current folder. Press ctrl+n to show all, or Tab to view all."
        else
            menu.show_cwd ? "  No sessions found" : "  No sessions in current folder. Press Tab to view all."
        end
        push!(lines,session_clip(session_line(menu,message,:muted),width;marker="…"))
    else
        start=max(1,min(menu.cursor-fld(menu.maximum_rows,2),count-menu.maximum_rows+1))
        stop=min(start+menu.maximum_rows-1,count)
        for index in start:stop
            push!(lines,resume_row(menu,menu.rows[index],index==menu.cursor,width))
        end
        if start>1 || stop<count
            push!(lines,session_clip(session_line(menu,"  ($(menu.cursor)/$count)",:muted),width;marker=""))
        end
    end
    lines
end

function resume_lines(menu::ResumeMenu,width::Integer;selectors::NativeSelectorBindings=NativeSelectorBindings())
    columns=Int(width)
    menu.width=columns
    border=session_line(menu,repeat("─",max(0,columns)),:accent)
    lines=[session_line(menu),border,session_line(menu)]
    if menu.mode==:rename
        append!(lines,session_text(menu,"Rename Session",columns;bold=true))
        push!(lines,session_line(menu))
        menu.input_row=length(lines)
        push!(lines,menu_search_spans(menu.rename_input,columns),session_line(menu))
        append!(lines,session_text(menu,"enter to save · "*native_selector_text(selectors,:cancel)*" to cancel",columns;token=:muted))
    else
        append!(lines,resume_header(menu,columns;selectors))
        push!(lines,session_line(menu))
        menu.input_row=length(lines)
        append!(lines,resume_list_lines(menu,columns))
    end
    push!(lines,session_line(menu),border)
    lines
end
function resume_hardware_cursor(menu::ResumeMenu)
    focused=menu.mode==:rename ? menu.rename_focused : menu.focused
    if focused && menu.width>2
        input=menu.mode==:rename ? menu.rename_input : menu.search
        runs=menu_search_render!(input,menu.width)
        (row=menu.input_row,col=menu_search_width(first(runs).text))
    else
        nothing
    end
end
function resume_mouse!(menu::ResumeMenu,x::Integer,y::Integer;action::Symbol=:press,button::Symbol=:left)
    result=nothing
    if menu.mode==:rename && y==menu.input_row && action==:press && button==:left
        menu_search_click!(menu.rename_input,Int(x))
        result=(handled=true,focus=true,capture=false,render=nothing,target="rename",focusTarget="selector")
    end
    result
end
resume_draw!(buffer::Tachikoma.Buffer,x::Int,y::Int,width::Int,menu::ResumeMenu)=session_draw_lines!(buffer,x,y,width,resume_lines(menu,width))
