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
"""Keep registered paste atoms in the shared dictionary word-boundary reducer."""
chat_dictionary_boundary(editor::ChatEditorState,text::AbstractString,direction::Int) =
    editor_word_distance(chat_word_segments(editor,text),direction,chat_space)
