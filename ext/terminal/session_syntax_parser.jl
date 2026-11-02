using JuliaForever2: SessionSourceColor, SESSION_PARSER_MODULES, SESSION_PARSER_GRAMMARS, SESSION_PARSER_EXTENSIONS, SESSION_PARSER_PLAIN, SESSION_PARSER_EAGER, session_parser_colors, session_parser_grammar, source_syntax_highlight

"""Byte-bounded source coloring through an explicit registry of native grammar libraries."""
Base.@kwdef struct SessionParserSyntaxRenderer
    phase::Symbol = :full
    max_bytes::Int = 262_144
end

function session_parser_style(kind::Symbol)
    kind==:meta ? session_display_style(:muted) : session_syntax_style(kind)
end

function (renderer::SessionParserSyntaxRenderer)(path::AbstractString,raw::AbstractString)
    renderer.phase in (:eager,:full)||error("Unsupported syntax initialization phase")
    renderer.max_bytes>=0||error("Source parser byte budget must be nonnegative")
    text=String(session_display_safe(raw))
    extension=lowercase(last(split(path,'.')))
    language=get(SESSION_PARSER_EXTENSIONS,extension,"")
    fallback=language in SESSION_PARSER_PLAIN||renderer.phase==:eager&&!(language in SESSION_PARSER_EAGER)
    result=if isempty(language)
        SessionSyntaxRenderer(phase=renderer.phase)(path,text)
    elseif fallback||!isvalid(text)||ncodeunits(text)>renderer.max_bytes
        SessionSyntaxLines(session_syntax_lines(text,fill(session_display_style(:codeblock),length(text));keep_trailing=true))
    elseif haskey(SESSION_PARSER_MODULES,language)&&isvalid(text)&&ncodeunits(text)<=renderer.max_bytes
        colors=source_syntax_highlight(language,text;phase=renderer.phase,max_bytes=renderer.max_bytes).colors
        sort!(colors;by=c->(c.priority>=1000,-(c.last-c.first),c.priority))
        positions=session_syntax_positions(text)
        styles=fill(session_syntax_style(:default),length(text))
        for color in colors
            if 1<=color.first<=color.last<=ncodeunits(text)&&isvalid(text,color.first)&&(color.last==ncodeunits(text)||isvalid(text,color.last+1))
                styles[positions[color.first]:positions[color.last+1]-1].=Ref(session_parser_style(color.kind))
            end
        end
        SessionSyntaxLines(session_syntax_lines(text,styles))
    else
        SessionSyntaxRenderer(phase=renderer.phase)(path,text)
    end
    result
end
