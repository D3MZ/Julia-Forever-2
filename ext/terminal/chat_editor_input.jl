"""Resolve native grapheme and word boundaries without splitting registered paste markers."""
function chat_boundary(editor::ChatEditorState,direction::Int;word::Bool=false)
    text=chat_text(editor);cursor=editor.input.cursor;position=chat_position(editor)
    lines=split(text,'\n';keepempty=true);line=lines[position.line]
    if direction<0 && position.col==0
        max(0,cursor-1)
    elseif direction>0 && position.col==length(line)
        min(length(text),cursor+1)
    else
        part=direction<0 ? chat_prefix(line,position.col) : chat_suffix(line,position.col)
        segments=chat_segments(editor,part)
        direction<0 && reverse!(segments)
        simple=all(char->isascii(char) && (isletter(char) || isnumeric(char) || isspace(char)),part)
        dictionary=word && !simple
        total=dictionary ? chat_dictionary_boundary(editor,part,direction) : 0
        phase=:spaces;finished=dictionary
        for segment in segments
            category=segment.atomic ? :atomic : chat_space(segment.text) ? :space : occursin(r"[\p{L}\p{N}\p{M}_]",segment.text) ? :word : :punctuation
            if !finished
                if !word
                    total=length(segment.text);finished=true
                elseif phase==:spaces && category==:space
                    total+=length(segment.text)
                elseif phase==:spaces
                    total+=length(segment.text);phase=category
                    category==:atomic && (finished=true)
                elseif category==phase
                    total+=length(segment.text)
                else
                    finished=true
                end
            end
        end
        clamp(cursor+direction*total,0,length(text))
    end
end

function chat_line_move!(editor::ChatEditorState,end_of_line::Bool)
    position=chat_position(editor);lines=split(chat_text(editor),'\n';keepempty=true)
    offset=chat_line_offset(lines,position.line)
    editor.last_action=:none
    chat_cursor!(editor,offset+(end_of_line ? length(lines[position.line]) : 0))
    nothing
end
function chat_horizontal!(editor::ChatEditorState,direction::Int;word::Bool=false)
    editor.last_action=:none
    next=chat_boundary(editor,direction;word)
    if next==editor.input.cursor && direction>0
        rows=chat_layout(editor,editor.layout_width)
        index=something(findfirst(row->!isnothing(row.cursor),rows),length(rows))
        editor.preferred=chat_utf16(chat_prefix(rows[index].text,something(rows[index].cursor,0)))
    else
        chat_cursor!(editor,next)
    end
    nothing
end

"""Apply the source editor's sticky UTF-16 column rule while snapping to native grapheme boundaries."""
function chat_vertical!(editor::ChatEditorState,direction::Int;page::Bool=false)
    editor.last_action=:none
    rows=chat_layout(editor,editor.layout_width)
    current=something(findfirst(row->!isnothing(row.cursor),rows),length(rows))
    target=clamp(current+direction*(page ? max(5,floor(Int,editor.terminal_rows*0.3)) : 1),1,length(rows))
    if target!=current
        source=rows[current];destination=rows[target]
        lines=split(chat_text(editor),'\n';keepempty=true)
        position=chat_position(editor)
        currentcol=chat_utf16(chat_slice(lines[source.line],source.start,position.col))
        !isnothing(editor.snapped) && (currentcol=editor.snapped)
        sourcemax=chat_utf16(source.text)-(current<length(rows) && rows[current+1].line==source.line ? 1 : 0)
        targetmax=max(0,chat_utf16(destination.text)-(target<length(rows) && rows[target+1].line==destination.line ? 1 : 0))
        preferred=editor.preferred
        move=if isnothing(preferred) || currentcol<sourcemax
            editor.preferred=targetmax<currentcol ? currentcol : nothing
            min(currentcol,targetmax)
        elseif targetmax<currentcol || targetmax<preferred
            targetmax
        else
            editor.preferred=nothing
            preferred
        end
        absolute=chat_utf16(chat_prefix(lines[destination.line],destination.start))+move
        column=0;units=0
        for char in lines[destination.line]
            units+=Int(char)>0xffff ? 2 : 1
            units<=absolute && (column+=1)
        end
        editor.snapped=nothing
        skipped=nothing
        for segment in chat_segments(editor,lines[destination.line])
            if segment.start<=column<segment.stop && length(segment.text)>1
                if segment.start<destination.start && target>current
                    skipped=findfirst(index->index>target && (rows[index].line!=destination.line || rows[index].start>=segment.stop),eachindex(rows))
                end
                editor.snapped=move;column=segment.start
            end
        end
        if !isnothing(skipped)
            chat_vertical!(editor,skipped-current)
        else
            cursor=chat_line_offset(lines,destination.line)+column
            editor.input.cursor=cursor;editor.observed_cursor=cursor
        end
    end
    nothing
end
function chat_arrow!(editor::ChatEditorState,direction::Int)
    rows=chat_layout(editor,editor.layout_width)
    current=something(findfirst(row->!isnothing(row.cursor),rows),length(rows))
    position=chat_position(editor)
    if direction<0 && current==1
        if isempty(chat_text(editor)) || editor.history_index>=0 || position.col==0
            chat_history!(editor,-1)
        else
            chat_line_move!(editor,false)
        end
    elseif direction>0 && current==length(rows)
        editor.history_index>=0 ? chat_history!(editor,1) : chat_line_move!(editor,true)
    else
        chat_vertical!(editor,direction)
    end
    nothing
end

"""Decode and atomically insert actual bracketed paste contents, retaining reversible large-paste IDs."""
function chat_paste!(editor::ChatEditorState,text::AbstractString)
    chat_push_undo!(editor);chat_exit_history!(editor);editor.last_action=:none
    decoded=replace(text,r"\e\[(\d+);5u"=>packet->begin
        code=chat_parseint(match(r"\d+",packet).match)
        !isnothing(code) && (65<=code<=90 || 97<=code<=122) ? string(Char(code-(code<=90 ? 64 : 96))) : packet
    end)
    clean=join(char for char in chat_normalize(decoded) if char=='\n' || Int(char)>=32)
    before=chat_prefix(chat_text(editor),editor.input.cursor)
    if !isempty(clean) && first(clean) in ('/','~','.') && !isempty(before) && occursin(r"[a-zA-Z0-9_]",string(last(before)))
        clean=" "*clean
    end
    lines=count(==('\n'),clean)+1;units=chat_utf16(clean)
    if lines>10 || units>1000
        editor.paste_counter+=1;editor.pastes[editor.paste_counter]=clean
        suffix=lines>10 ? "+$lines lines" : "$units chars"
        chat_insert!(editor,"[paste #$(editor.paste_counter) $suffix]";snapshot=false)
    else
        chat_insert!(editor,clean;snapshot=false)
    end
    nothing
end

"""Renumber retained paste markers only for the original atomic backspace deletion contract."""
function chat_remove_paste!(editor::ChatEditorState,start::Int,stop::Int)
    marker=chat_slice(chat_text(editor),start,stop);found=match(CHAT_PASTE_MARKER,marker)
    if !isnothing(found)
        id=something(chat_parseint(found.captures[1]),0)
        if haskey(editor.pastes,id)
            delete!(editor.pastes,id);editor.paste_counter-=1
            for higher in sort(filter(key->key>id,collect(keys(editor.pastes))))
                editor.pastes[higher-1]=pop!(editor.pastes,higher)
            end
            text=replace(chat_text(editor),CHAT_PASTE_MARKER=>old->begin
                record=match(CHAT_PASTE_MARKER,old);value=something(chat_parseint(record.captures[1]),0)
                value>id ? "[paste #$(value-1)$(something(record.captures[2],"undefined"))]" : old
            end)
            chat_write!(editor,text,editor.input.cursor)
        end
    end
    nothing
end
function chat_delete_key!(editor::ChatEditorState,direction::Int;word::Bool=false,line::Bool=false)
    cursor=editor.input.cursor
    target=if line
        position=chat_position(editor);lines=split(chat_text(editor),'\n';keepempty=true)
        offset=chat_line_offset(lines,position.line)
        boundary=direction<0 ? offset : offset+length(lines[position.line])
        boundary==cursor ? clamp(cursor+direction,0,length(chat_text(editor))) : boundary
    else
        chat_boundary(editor,direction;word)
    end
    start,stop=minmax(cursor,target)
    marker=direction<0 && !word && !line ? match(CHAT_PASTE_MARKER,chat_slice(chat_text(editor),start,stop)) : nothing
    if !isnothing(marker) && haskey(editor.pastes,chat_parseint(marker.captures[1]))
        chat_push_undo!(editor);chat_remove_paste!(editor,start,stop)
        snapshot=pop!(editor.undo)
        chat_delete!(editor,start,stop)
        editor.undo[end]=snapshot
    else
        chat_delete!(editor,start,stop;kill=word||line,backward=direction<0)
    end
    nothing
end

function chat_jump!(editor::ChatEditorState,text::AbstractString,direction::Int)
    full=chat_text(editor);cursor=editor.input.cursor
    needle=String(text)::String
    locations=[length(SubString(full,1,prevind(full,first(found)))) for found in findall(needle,full)]
    choices=filter(index->direction<0 ? index<cursor : index>cursor,locations)
    if !isempty(choices)
        editor.last_action=:none;chat_cursor!(editor,direction<0 ? last(choices) : first(choices))
    end
    nothing
end
const CHAT_EDITOR_KEYS=Dict(
    "\e[A"=>:up,"\e[B"=>:down,"\e[D"=>:left,"\x02"=>:left,"\e[C"=>:right,"\x06"=>:right,
    "\e[H"=>:home,"\eOH"=>:home,"\e[1~"=>:home,"\x01"=>:home,"\e[F"=>:end,"\eOF"=>:end,"\e[4~"=>:end,"\x05"=>:end,
    "\eb"=>:word_left,"\e[1;3D"=>:word_left,"\e[1;5D"=>:word_left,"\ef"=>:word_right,"\e[1;3C"=>:word_right,"\e[1;5C"=>:word_right,
    "\x7f"=>:backspace,"\x08"=>:backspace,"\e[3~"=>:delete,"\x04"=>:delete,
    "\x17"=>:delete_word_backward,"\e\x7f"=>:delete_word_backward,"\ed"=>:delete_word_forward,"\e[3;3~"=>:delete_word_forward,
    "\x15"=>:delete_start,"\x0b"=>:delete_end,"\x19"=>:yank,"\ey"=>:yank_pop,"\x1f"=>:undo,
    "\e[5~"=>:page_up,"\e[5;5~"=>:page_up,"\e[6~"=>:page_down,"\e[6;5~"=>:page_down,
    "\x1d"=>:jump_forward,"\e\x1d"=>:jump_backward,"\n"=>:newline,"\e\r"=>:newline,"\e[13;2u"=>:newline,"\e[13;2~"=>:newline,
    "\r"=>:submit,"\e[13u"=>:submit,"\t"=>:complete,"\x03"=>:copy,"\e"=>:interrupt)

"""Apply a native editor operation and return only real owner requests, never simulated success."""
function chat_edit!(editor::ChatEditorState,action::Symbol)
    response=(action=:handled,text="")
    if action in (:left,:right,:word_left,:word_right)
        chat_horizontal!(editor,action in (:left,:word_left) ? -1 : 1;word=action in (:word_left,:word_right))
    elseif action in (:home,:end)
        chat_line_move!(editor,action==:end)
    elseif action in (:up,:down)
        chat_arrow!(editor,action==:up ? -1 : 1)
    elseif action in (:page_up,:page_down)
        chat_vertical!(editor,action==:page_up ? -1 : 1;page=true)
    elseif action in (:backspace,:delete,:delete_word_backward,:delete_word_forward,:delete_start,:delete_end)
        if action==:delete && isempty(chat_text(editor))
            response=(action=:exit,text="")
        else
            chat_delete_key!(editor,action in (:backspace,:delete_word_backward,:delete_start) ? -1 : 1;word=action in (:delete_word_backward,:delete_word_forward),line=action in (:delete_start,:delete_end))
        end
    elseif action in (:yank,:yank_pop)
        chat_yank!(editor;rotate=action==:yank_pop)
    elseif action==:undo
        chat_undo!(editor)
    elseif action==:newline
        chat_insert!(editor,"\n")
    elseif action in (:jump_forward,:jump_backward)
        editor.jump=action==:jump_forward ? :forward : :backward
    elseif action==:submit && !editor.disable_submit
        before=chat_prefix(chat_text(editor),editor.input.cursor)
        if endswith(before,"\\")
            chat_delete_key!(editor,-1);chat_insert!(editor,"\n")
        else
            response=(action=:submit,text=String(strip(chat_expanded_text(editor))))
        end
    elseif action in (:complete,:copy,:interrupt)
        response=(action,text="")
    end
    response
end

"""Normalize Kitty and modifyOtherKeys controls while rejecting functional private-use text."""
function chat_key_packet(data::AbstractString)
    kitty=match(r"^\e\[([0-9]+)(?::([0-9]*))?(?::([0-9]+))?(?:;([0-9]+))?(?::([0-9]+))?u$",data)
    other=match(r"^\e\[27;([0-9]+);([0-9]+)~$",data)
    if isnothing(kitty) && isnothing(other)
        (action=get(CHAT_EDITOR_KEYS,String(data),:none),printable=nothing)
    else
        code=chat_parseint(isnothing(kitty) ? other.captures[2] : kitty.captures[1])
        mod=chat_parseint(isnothing(kitty) ? other.captures[1] : something(kitty.captures[4],"1"))
        modifier=isnothing(mod) ? -1 : (mod-1)&~192
        shifted=isnothing(kitty) || isnothing(kitty.captures[2]) || isempty(kitty.captures[2]) ? nothing : chat_parseint(kitty.captures[2])
        effective=modifier==1 && !isnothing(shifted) ? shifted : code
        action=:none;printable=nothing
        if !isnothing(code)
            if modifier==4 && (97<=code<=122 || 65<=code<=90)
                action=get(CHAT_EDITOR_KEYS,string(Char(code-(code<=90 ? 64 : 96))),:none)
            elseif modifier==4 && code==45
                action=:undo
            elseif code in (13,57414) && modifier in (0,1)
                action=modifier==1 ? :newline : :submit
            elseif code in (8,127) && modifier in (0,1,2)
                action=modifier==2 ? :delete_word_backward : :backspace
            elseif modifier==2 && 32<=code<=126
                action=get(CHAT_EDITOR_KEYS,"\e"*string(Char(code)),:none)
            elseif code==27 && modifier==0
                action=:interrupt
            elseif code==9 && modifier==0
                action=:complete
            elseif modifier in (0,1) && !isnothing(effective) && 32<=effective<=0x10ffff && !(57344<=effective<=63743) && !(0xd800<=effective<=0xdfff)
                printable=string(Char(effective))
            end
        end
        (;action,printable)
    end
end

"""Consume raw terminal packets and fragmented paste without invoking a provider or shell."""
function chat_editor_input!(editor::ChatEditorState,packet::AbstractString)
    chat_sync!(editor);data=String(packet);response=(action=:handled,text="")
    action=chat_key_packet(data).action
    if editor.jump!=:none
        direction=editor.jump==:forward ? 1 : -1;editor.jump=:none
        printable=something(chat_key_packet(data).printable,!isempty(data) && Int(first(data))>=32 ? data : "")
        if action in (:jump_forward,:jump_backward)
            data=""
        elseif !isempty(printable)
            chat_jump!(editor,printable,direction);data=""
        end
    end
    if occursin("\e[200~",data)
        editor.pasting=true;editor.paste_buffer="";data=replace(data,"\e[200~"=>"";count=1)
    end
    if editor.pasting
        editor.paste_buffer*=data;ending=findfirst("\e[201~",editor.paste_buffer)
        if !isnothing(ending)
            content=String(SubString(editor.paste_buffer,1,prevind(editor.paste_buffer,first(ending))))
            !isempty(content) && chat_paste!(editor,content)
            remainder=String(SubString(editor.paste_buffer,nextind(editor.paste_buffer,last(ending))))
            editor.paste_buffer="";editor.pasting=false
            !isempty(remainder) && (response=chat_editor_input!(editor,remainder))
        end
    elseif !isempty(data)
        operation=chat_key_packet(data).action
        if operation!=:none
            response=chat_edit!(editor,operation)
        else
            printable=chat_key_packet(data).printable
            if !isnothing(printable)
                chat_insert!(editor,printable;typed=true)
            elseif Int(first(data))>=32
                chat_insert!(editor,data;typed=true)
            end
        end
    end
    response
end

"""Handle synthesized clicks only, leaving raw drag selection and wheel events to the screen owner."""
function chat_editor_mouse!(editor::ChatEditorState,type::Symbol,button::Symbol,x::Int,y::Int,width::Int;padding::Int=0)
    handled=type==:click && button==:left
    if handled && 0<y<=editor.visible_rows
        rows=chat_layout(editor,editor.layout_width)
        index=editor.scroll+y
        if index<=length(rows)
            row=rows[index];margin=clamp(padding,0,max(0,fld(width-1,2)))
            target=max(0,x-margin);column=0;offset=length(row.text);laststart=0;found=false
            for segment in chat_segments(editor,row.text)
                following=column+menu_search_width(segment.text);laststart=segment.start
                if !found && target<following
                    offset=segment.start;found=true
                end
                column=following
            end
            final=index==length(rows) || rows[index+1].line!=row.line
            !final && offset==length(row.text) && !isempty(row.text) && (offset=laststart)
            lines=split(chat_text(editor),'\n';keepempty=true)
            chat_cursor!(editor,chat_line_offset(lines,row.line)+row.start+offset)
            editor.last_action=:none;chat_exit_history!(editor)
        end
    end
    (handled,focus=handled)
end
