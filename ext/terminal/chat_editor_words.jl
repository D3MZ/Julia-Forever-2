"""Use the native core dictionary service rather than any editor or Node process adapter."""
chat_icu_segments(text::AbstractString) = JuliaForever2.WordSegmentation.segments(text)

"""Merge only registered paste IDs into the native ICU stream before applying editor word actions."""
function chat_word_segments(editor::ChatEditorState,text::AbstractString)
    segments=chat_icu_segments(text)
    atomic=filter(item->item.atomic,chat_segments(editor,text))
    result=NamedTuple{(:text,:start,:stop,:word,:atomic),Tuple{String,Int,Int,Bool,Bool}}[]
    for segment in segments
        marker=findfirst(item->item.start<=segment.start<item.stop,atomic)
        if isnothing(marker)
            push!(result,(;segment...,atomic=false))
        elseif atomic[marker].start==segment.start
            item=atomic[marker]
            push!(result,(text=item.text,start=item.start,stop=item.stop,word=false,atomic=true))
        end
    end
    result
end
const CHAT_WORD_PUNCTUATION=r"[(){}\[\]<>.,;:'\"!?+\-=*/\\|&%^$#@~`]"

"""Compute one word movement using dictionary words and explicit ASCII punctuation boundaries."""
function chat_dictionary_boundary(editor::ChatEditorState,text::AbstractString,direction::Int)
    segments=chat_word_segments(editor,text)
    direction<0 && reverse!(segments)
    consumed=0;started=false;done=false;punctuation=false
    for segment in segments
        if !done
            if !started && !segment.atomic && chat_space(segment.text)
                consumed+=length(segment.text)
            elseif !started
                started=true
                if segment.atomic
                    consumed+=length(segment.text);done=true
                elseif segment.word
                    boundaries=collect(eachmatch(CHAT_WORD_PUNCTUATION,segment.text))
                    if isempty(boundaries)
                        consumed+=length(segment.text)
                    else
                        boundary=direction<0 ? last(boundaries) : first(boundaries)
                        prefix=length(SubString(segment.text,1,prevind(segment.text,boundary.offset)))
                        consumed+=direction<0 ? length(segment.text)-prefix-length(boundary.match) : prefix
                    end
                    done=true
                else
                    consumed+=length(segment.text);punctuation=true
                end
            elseif punctuation && !segment.atomic && !segment.word && !chat_space(segment.text)
                consumed+=length(segment.text)
            else
                done=true
            end
        end
    end
    consumed
end
