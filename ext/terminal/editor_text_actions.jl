# Native editor primitives inspired by Pi (MIT), pinned 2c8d1feb147f6b3d97e855da803bfe7b19f3c403.
# License: licenses/pi-LICENSE. State remains owned by each input/editor.

"""Accumulate adjacent kills in their original textual order without sharing editor state."""
function editor_kill_push!(ring::Vector{String},text::AbstractString;prepend::Bool=false,accumulate::Bool=false)
    if !isempty(text)
        if accumulate && !isempty(ring)
            ring[end]=prepend ? text*ring[end] : ring[end]*text
        else
            push!(ring,String(text))
        end
    end
    nothing
end

"""Cycle the newest killed text to the oldest position, retaining every owned entry."""
function editor_kill_rotate!(ring::Vector{String})
    length(ring)>1 && pushfirst!(ring,pop!(ring))
    nothing
end

"""Use ECMAScript whitespace rather than the broader native Unicode whitespace class."""
editor_input_space(text::AbstractString) = any(character->Int(character) in (0x09,0x0a,0x0b,0x0c,0x0d,0x20,0xa0,0x1680,0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff) || 0x2000<=Int(character)<=0x200a,text)

const EDITOR_WORD_PUNCTUATION=r"[(){}\[\]<>.,;:'\"!?+\-=*/\\|&%^$#@~`]"

"""Compute one word movement using dictionary words and explicit ASCII punctuation boundaries."""
function editor_word_distance(segments::AbstractVector,direction::Int,is_space::F) where {F}
    direction<0 && reverse!(segments)
    consumed=0;started=false;done=false;punctuation=false
    for segment in segments
        if !done
            if !started && !segment.atomic && is_space(segment.text)
                consumed+=length(segment.text)
            elseif !started
                started=true
                if segment.atomic
                    consumed+=length(segment.text);done=true
                elseif segment.word
                    boundaries=collect(eachmatch(EDITOR_WORD_PUNCTUATION,segment.text))
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
            elseif punctuation && !segment.atomic && !segment.word && !is_space(segment.text)
                consumed+=length(segment.text)
            else
                done=true
            end
        end
    end
    consumed
end
