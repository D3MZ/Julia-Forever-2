# Native rich startup text layout; behavior tested against Pi (MIT), pinned in test provenance.
Base.@kwdef struct StartupGlyph
    text::String = ""
    style::Tachikoma.Style = Tachikoma.Style()
end
const StartupRichText = Vector{StartupGlyph}

"""Keep literal content separate from typed styles and strip executable terminal control sequences."""
function startup_safe_text(value::AbstractString;multiline::Bool=false)
    clean=replace(String(value),MENU_SEARCH_ANSI=>"")
    join(character=='\t' ? "   " : character=='\n' && multiline ? "\n" :
        iscntrl(character) ? "�" : string(character) for character in clean)
end

"""Append literal text and explicit style boundaries without retaining terminal escape strings."""
function startup_rich!(out::StartupRichText,text::AbstractString,style::Tachikoma.Style=Tachikoma.Style();reset::Bool=true)
    styled=style!=Tachikoma.Style()
    styled && push!(out,StartupGlyph(;style))
    for glyph in menu_search_graphemes(startup_safe_text(text;multiline=true))
        push!(out,StartupGlyph(;text=glyph,style))
    end
    reset && styled && push!(out,StartupGlyph())
    out
end
startup_rich(text::AbstractString="",style::Tachikoma.Style=Tachikoma.Style()) = startup_rich!(StartupRichText(),text,style)
startup_active(style) = style==Tachikoma.Style() ? StartupRichText() : StartupRichText([StartupGlyph(;style)])
startup_rich_width(items) = sum(item->menu_search_width(item.text),items;init=0)
startup_cjk(text) = occursin(r"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]",text)

"""Keep style transitions attached to their next glyph, including a terminal reset on the last token."""
function startup_tokens(items::StartupRichText)
    tokens=StartupRichText[];current=StartupRichText();pending=StartupRichText();kind=:none
    for item in items
        if isempty(item.text)
            push!(pending,item)
        else
            nextkind=item.text==" " ? :space : :word
            cjk=startup_cjk(item.text)
            if !isempty(current) && (kind!=nextkind || cjk)
                push!(tokens,current);current=StartupRichText()
            end
            append!(current,pending);empty!(pending);push!(current,item);kind=nextkind
            if cjk
                push!(tokens,current);current=StartupRichText();kind=:none
            end
        end
    end
    if !isempty(current)
        append!(current,pending);push!(tokens,current)
    elseif !isempty(tokens)
        append!(last(tokens),pending)
    elseif !isempty(pending)
        push!(tokens,pending)
    end
    tokens
end

"""Trim only literal trailing whitespace; an explicit color reset terminates trimming."""
function startup_trim(items::StartupRichText)
    result=copy(items)
    while !isempty(result) && !isempty(last(result).text) && all(isspace,last(result).text)
        pop!(result)
    end
    result
end

"""Wrap structured glyphs with preserved active foreground at every soft line break."""
function startup_wrap_line(items::StartupRichText,width::Int)
    output=StartupRichText[]
    if startup_rich_width(items)<=width
        push!(output,items)
    else
        current=StartupRichText();used=0;style=Tachikoma.Style()
        for token in startup_tokens(items)
            size=startup_rich_width(token)
            whitespace=all(item->isempty(item.text)||all(isspace,item.text),token)
            if size>width && !whitespace
                if !isempty(current)
                    push!(output,startup_trim(current))
                end
                current=startup_active(style);used=0
                for item in token
                    columns=menu_search_width(item.text)
                    if !isempty(item.text) && used+columns>width
                        push!(output,current);current=startup_active(style);used=0
                    end
                    push!(current,item);style=item.style;used+=columns
                end
            elseif used+size>width && used>0
                line=startup_trim(current)
                if whitespace
                    codes=filter(item->isempty(item.text),token)
                    append!(line,codes)
                    !isempty(codes) && (style=last(codes).style)
                end
                push!(output,line)
                current=startup_active(style);used=0
                if !whitespace
                    append!(current,token);used=size
                end
            elseif whitespace && used+size>width && any(item->isempty(item.text),token)
                append!(current,filter(item->isempty(item.text),token))
            else
                append!(current,token);used+=size
            end
            !isempty(token) && (style=last(token).style)
        end
        !isempty(current) && push!(output,current)
        output=startup_trim.(output)
    end
    isempty(output) ? [StartupRichText()] : output
end

"""Render padded text components as native styled spans, including narrow-margin reduction."""
function startup_text_lines(items::StartupRichText,width::Int;padding::Int=0)
    lines=Vector{Tachikoma.Span}[]
    if any(item->!isempty(strip(item.text)),items)
        margin=min(padding,max(0,fld(width-1,2)));room=max(1,width-2margin)
        inputs=StartupRichText[];current=StartupRichText();style=Tachikoma.Style()
        for item in items
            if item.text in ("\n","\r","\r\n")
                push!(inputs,current);current=startup_active(style)
            else
                push!(current,item);style=item.style
            end
        end
        push!(inputs,current)
        for input in inputs,line in startup_wrap_line(input,room)
            spans=Tachikoma.Span[Tachikoma.Span(repeat(" ",margin),Tachikoma.Style())]
            active=Tachikoma.Style()
            for item in line
                active=item.style
                if !isempty(item.text)
                    if !isempty(spans) && last(spans).style==active
                        previous=pop!(spans);push!(spans,Tachikoma.Span(previous.content*item.text,active))
                    else
                        push!(spans,Tachikoma.Span(item.text,active))
                    end
                end
            end
            push!(spans,Tachikoma.Span(repeat(" ",max(0,width-margin-startup_rich_width(line))),active))
            push!(lines,spans)
        end
    end
    lines
end
