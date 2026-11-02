"""Replace malformed input bytes before Unicode operations without interpreting terminal controls."""
terminal_search_text(value::AbstractString) = isvalid(value) ? String(value) : join(isvalid(char) ? string(char) : "�" for char in value)

"""Match JavaScript's explicit whitespace class without treating NEL as a separator."""
terminal_search_space(char::Char) = Int(char) in (9,10,11,12,13,32,160,0x1680,0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff) || 0x2000<=Int(char)<=0x200a
terminal_search_plain(line::AbstractString) = replace(terminal_search_text(line),MENU_SEARCH_ANSI=>"")
terminal_search_plain(line::Vector{Tachikoma.Span}) = join(terminal_search_plain(span.content) for span in line)

"""Normalize only source-equivalent whitespace; queries remain literal text, never executable patterns."""
function terminal_search_normalize(query::AbstractString)
    out=IOBuffer();pending=false;started=false
    for char in terminal_search_text(query)
        if terminal_search_space(char)
            pending=started
        else
            pending && print(out,' ')
            print(out,char);pending=false;started=true
        end
    end
    String(take!(out))
end

"""Build a searchable rendered-text corpus with whole-grapheme cell provenance."""
function terminal_search_corpus(lines::Vector{String})
    output=IOBuffer();spans=TerminalSearchSpan[];offset=0;pending=false
    for (index,line) in enumerate(lines)
        text=terminal_search_plain(line);column=0;ascii=all(char->' '<=char<='~',text)
        if ascii
            position=1
            while position<=ncodeunits(text)
                if codeunit(text,position)==0x20
                    pending=offset>0;column+=1;position+=1
                else
                    stop=position
                    while stop<=ncodeunits(text) && codeunit(text,stop)!=0x20
                        stop+=1
                    end
                    if pending
                        print(output,' ');offset+=1;pending=false
                    end
                    count=stop-position
                    print(output,SubString(text,position,stop-1))
                    push!(spans,TerminalSearchSpan(;first=offset,last=offset+count,row=index-1,column,stop=column+count,linear=true))
                    offset+=count;column+=count;position=stop
                end
            end
        else
            for glyph in Base.Unicode.graphemes(text)
                width=menu_search_width(glyph)
                if all(terminal_search_space,glyph)
                    pending=offset>0
                else
                    if pending
                        print(output,' ');offset+=1;pending=false
                    end
                    bytes=ncodeunits(glyph)
                    print(output,glyph)
                    push!(spans,TerminalSearchSpan(;first=offset,last=offset+bytes,row=index-1,column,stop=column+width))
                    offset+=bytes
                end
                column+=width
            end
        end
        pending=offset>0
    end
    (text=String(take!(output)),spans)
end

"""Resolve the already-required native ICU simple-fold service without compiling user-controlled regex."""
function terminal_search_fold_api()
    library=JuliaForever2.WordSegmentation.ICU_jll
    handle=library.libicuuc_handle::Ptr{Cvoid}
    version=Base.pkgversion(library)::VersionNumber
    handle==C_NULL ? nothing : JuliaForever2.WordSegmentation.Libdl.dlsym(handle,Symbol("u_foldCase_",version.major);throw_error=false)
end

"""Fold valid codepoints one-to-one, retaining original byte offsets and avoiding full-fold expansions."""
function terminal_search_fold(text::String,api::Ptr{Cvoid})
    folded=Int32[];offsets=Int[]
    for index in eachindex(text)
        character=text[index]
        code=isvalid(character) ? Int32(UInt32(character)) : Int32(0xfffd)
        folded_code=code<128 ? (65<=code<=90 ? code+Int32(32) : code) : ccall(api,Int32,(Int32,UInt32),code,UInt32(0))
        push!(folded,folded_code)
        push!(offsets,index-1)
    end
    push!(offsets,ncodeunits(text))
    (;folded,offsets)
end

"""Find literal nonoverlapping ranges in linear time without pattern-size or regex syntax failures."""
function terminal_search_ranges(text::String,query::String,api::Ptr{Cvoid})
    source=terminal_search_fold(text,api);pattern=terminal_search_fold(query,api).folded
    ranges=Tuple{Int,Int}[];failure=zeros(Int,length(pattern));matched=0
    for index in 2:length(pattern)
        while matched>0 && pattern[index]!=pattern[matched+1]
            matched=failure[matched]
        end
        pattern[index]==pattern[matched+1] && (matched+=1)
        failure[index]=matched
    end
    matched=0
    if !isempty(pattern)
        for (index,character) in enumerate(source.folded)
            while matched>0 && character!=pattern[matched+1]
                matched=failure[matched]
            end
            character==pattern[matched+1] && (matched+=1)
            if matched==length(pattern)
                push!(ranges,(source.offsets[index-matched+1],source.offsets[index+1]))
                matched=0
            end
        end
    end
    ranges
end

"""Map nonoverlapping literal matches to their original document rows and grapheme columns."""
function terminal_search_matches(text::String,spans::Vector{TerminalSearchSpan},query::String,api::Ptr{Cvoid})
    matches=TerminalSearchMatch[];span_index=1
    if !isempty(query)
        for (first,last) in terminal_search_ranges(text,query,api)
            while span_index<=length(spans) && spans[span_index].last<=first
                span_index+=1
            end
            segments=TerminalSearchSegment[]
            for index in span_index:length(spans)
                span=spans[index]
                if span.first>=last
                    break
                elseif span.last>first
                    left=span.linear ? span.column+max(first,span.first)-span.first : span.column
                    right=span.linear ? span.column+min(last,span.last)-span.first : span.stop
                    if !isempty(segments) && segments[end].row==span.row && left<=segments[end].last
                        previous=pop!(segments)
                        push!(segments,TerminalSearchSegment(;row=span.row,first=previous.first,last=max(previous.last,right)))
                    else
                        push!(segments,TerminalSearchSegment(;row=span.row,first=left,last=right))
                    end
                end
            end
            while span_index<=length(spans) && spans[span_index].last<=last
                span_index+=1
            end
            isempty(segments) || push!(matches,TerminalSearchMatch(;segments))
        end
    end
    matches
end

"""Invalidate the index on actual rendered-row changes, not merely archive count or query labels."""
function terminal_search_index!(index::TerminalSearchIndex,lines::Vector{String},query::AbstractString)
    valid=isvalid(query) && all(isvalid,lines)
    changed=true
    if valid
        source_changed=!index.initialized || index.source!=lines
        if source_changed
            corpus=terminal_search_corpus(lines)
            index.source=copy(lines);index.corpus=corpus.text;index.spans=corpus.spans;index.initialized=true
        end
        normalized=terminal_search_normalize(query)
        changed=source_changed || index.query!=normalized || !isnothing(index.error)
        if changed
            index.query=normalized
            api=terminal_search_fold_api()
            index.error=isnothing(api) ? "Native Unicode search is unavailable" : nothing
            index.matches=isnothing(api) ? TerminalSearchMatch[] : terminal_search_matches(index.corpus,index.spans,normalized,api)
        end
    else
        index.error="Search text contains invalid UTF-8"
        index.matches=TerminalSearchMatch[]
    end
    (matches=index.matches,changed)
end

terminal_search_match_key(match::TerminalSearchMatch) = (first(match.segments).row,first(match.segments).first,last(match.segments).row,last(match.segments).last)
