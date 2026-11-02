"""Find parser-proven unfinished multiline tokens without executing or rewriting source text."""
function session_markdown_terminator(language::String,text::String)
    grammar=JuliaForever2.session_parser_grammar(language)
    token=Base.@lock grammar.lock begin
        tree=parse(grammar.parser,text;injections=false)
        pending=[JuliaForever2.TreeSitter.root(tree)]
        choices=Tuple{Int,String}[]
        while !isempty(pending)
            node=pop!(pending)
            kind=JuliaForever2.TreeSitter.node_type(node)
            parent=JuliaForever2.TreeSitter.parent(node)
            parentkind=isnothing(parent)||JuliaForever2.TreeSitter.is_null(parent) ? "" : JuliaForever2.TreeSitter.node_type(parent)
            source=kind in ("string_start","ERROR") ? String(JuliaForever2.TreeSitter.slice(text,node)) : ""
            if language=="python"&&kind=="string_start"&&parentkind=="ERROR"
                for delimiter in ("\"\"\"","'''")
                    endswith(source,delimiter)&&push!(choices,(first(JuliaForever2.TreeSitter.byte_range(node)),delimiter))
                end
            elseif language in ("javascript","typescript")&&kind=="`"&&parentkind=="ERROR"
                push!(choices,(first(JuliaForever2.TreeSitter.byte_range(node)),"`"))
            elseif language in ("javascript","typescript","c","cpp","java","css","rust")&&kind=="ERROR"&&startswith(source,"/*")&&!occursin("*/",SubString(text,first(JuliaForever2.TreeSitter.byte_range(node))))
                push!(choices,(first(JuliaForever2.TreeSitter.byte_range(node)),"*/"))
            end
            append!(pending,JuliaForever2.TreeSitter.children(node))
        end
        isempty(choices) ? "" : last(minimum(choices))
    end
    token
end

"""Use a parser-only closing delimiter to color unfinished multiline input, clipping all ranges to real bytes."""
function session_markdown_fragment_colors(result::JuliaForever2.SourceSyntaxResult,language::String,text::String,policy)
    colors=result.colors
    if result.status==:success&&language in ("python","javascript","typescript","c","cpp","java","css","rust")
        terminator=session_markdown_terminator(language,text)
        if !isempty(terminator)&&ncodeunits(text)+ncodeunits(terminator)<=policy.max_bytes
            closed=source_syntax_highlight(language,text*terminator;phase=policy.phase,max_bytes=policy.max_bytes)
            colors=[JuliaForever2.SessionSourceColor(;first=color.first,last=min(color.last,ncodeunits(text)),kind=color.kind,priority=color.priority) for color in closed.colors if color.first<=ncodeunits(text)]
        end
    end
    colors
end
