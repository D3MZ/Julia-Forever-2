import JuliaSyntaxHighlighting

"""Translate maintained JuliaSyntax annotations into inert source semantic ranges."""
function julia_source_highlight(source::AbstractString;max_bytes::Int=262_144)
    max_bytes>=0||error("Source parser byte budget must be nonnegative")
    text=String(source)
    status=!isvalid(text) ? :invalid_source : ncodeunits(text)>max_bytes ? :byte_budget : :success
    colors=SessionSourceColor[]
    if status==:success
        annotated=JuliaSyntaxHighlighting.highlight(text)
        for annotation in Base.annotations(annotated)
            face=annotation.value
            kind=if face==:julia_keyword
                :keyword
            elseif face in (:julia_comment,:julia_shebang)
                :comment
            elseif face in (:julia_string,:julia_string_delim,:julia_cmd,:julia_cmd_delim,:julia_char,:julia_char_delim,:julia_string_interpolation)
                :string
            elseif face in (:julia_number,:julia_bool)
                :number
            elseif face in (:julia_type,:julia_builtin,:julia_singleton_identifier)
                :type
            else
                :default
            end
            region=annotation.region
            if kind!=:default&&1<=first(region)<=last(region)<=ncodeunits(text)
                push!(colors,SessionSourceColor(;first=first(region),last=last(region),kind))
            end
        end
    end
    SourceSyntaxResult(;status,language="julia",colors)
end
