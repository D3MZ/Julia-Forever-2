# App-owned CommonMark rule: delegate actual link parsing, retain only inert source-label metadata.
"""Retain raw Markdown label spelling alongside CommonMark's native parsed link/image tree."""
struct SessionMarkdownLabelRule end

function session_markdown_string_parser(text::String,offset::Int=1)
    parser=CommonMark.InlineParser()
    parser.buf=text;parser.len=ncodeunits(text);parser.pos=offset
    parser
end

"""Use the maintained parser for destination boundaries, preserving literal display bytes separately."""
function session_markdown_raw_destination(parser::CommonMark.InlineParser)
    CommonMark.chomp_ws(parser)
    start=position(parser)
    normalized=CommonMark.parse_link_destination(parser)
    if isnothing(normalized)
        nothing
    else
        raw=String(CommonMark.bytes(parser,start,position(parser)-1))
        startswith(raw,'<')&&endswith(raw,'>')&&(raw=String(chop(raw;head=1,tail=1)))
        unescaped=replace(raw,Regex("\\\\("*CommonMark.ESCAPABLE*")")=>s"\1")
        (normalized=String(normalized),display=String(unescaped))
    end
end

function session_markdown_close_label(parser::CommonMark.InlineParser,block::CommonMark.Node)
    opener=parser.brackets
    closeposition=position(parser)
    label=isnothing(opener) ? nothing : String(CommonMark.bytes(parser,opener.index+1,closeposition-1))
    previous=block.last_child
    parsed=CommonMark.parse_close_bracket(parser,block)
    node=block.last_child
    data=node.t
    if !isnothing(label) && node!==previous && (data isa CommonMark.Link || data isa CommonMark.Image)
        existing=node.meta
        metadata=isnothing(existing) ? Dict{String,Any}() : copy(existing)
        metadata["JuliaForever2.rawLabel"]=label
        probe=session_markdown_string_parser(parser.buf,closeposition+1)
        raw=nothing
        if CommonMark.trypeek(probe,Char,nothing)=='('&&position(parser)>closeposition+1
            read(probe,Char)
            raw=session_markdown_raw_destination(probe)
        end
        if !isnothing(raw)&&raw.normalized==data.destination
            metadata["JuliaForever2.displayHref"]=raw.display
        else
            seek(probe,closeposition+1)
            length=CommonMark.parse_link_label(probe)
            reference=length>2 ? String(CommonMark.bytes(probe,closeposition+1,closeposition+length)) : label
            metadata["JuliaForever2.referenceLabel"]=String(CommonMark.normalize_reference(reference))
        end
        node.meta=metadata
    end
    parsed
end
CommonMark.inline_rule(::SessionMarkdownLabelRule)=CommonMark.Rule(session_markdown_close_label,0,"]")

function session_markdown_raw_label(node::CommonMark.Node)
    metadata=node.meta
    if !isnothing(metadata)&&get(metadata,"JuliaForever2.rawLabel",nothing) isa String
        metadata["JuliaForever2.rawLabel"]::String
    else
        join(child.literal for (child,entering) in node if entering&&child.t isa CommonMark.Text)
    end
end

function session_markdown_display_href(node::CommonMark.Node)
    data=node.t
    if !(data isa CommonMark.Link || data isa CommonMark.Image)
        error("Expected a parsed Markdown link or image")
    end
    metadata=node.meta
    if !isnothing(metadata)&&get(metadata,"JuliaForever2.displayHref",nothing) isa String
        metadata["JuliaForever2.displayHref"]::String
    elseif isnothing(metadata)
        label=session_markdown_raw_label(node)
        data.destination==CommonMark.normalize_uri(label) ? label :
            data.destination==CommonMark.normalize_uri("mailto:"*label) ? "mailto:"*label : data.destination
    else
        data.destination
    end
end

"""Retain native reference-definition nodes without taking over multiline title parsing."""
struct SessionMarkdownReferenceRule
    source_lines::Vector{String}
end

function session_markdown_reference!(rule::SessionMarkdownReferenceRule,parser::CommonMark.Parser,container::CommonMark.Node)
    following=parser.line_number<length(rule.source_lines) ? replace(rule.source_lines[parser.line_number+1],r"^\s*(?:>\s*)*"=>"") : ""
    multiline_title=startswith(following,'\"')||startswith(following,'\'')||startswith(following,'(')
    line=String(CommonMark.rest_from_nonspace(parser))
    result=multiline_title ? 0 : CommonMark.block_rule(CommonMark.ReferenceLinkRule()).fn(parser,container)
    definition=parser.tip
    data=definition.t
    if result==2&&data isa CommonMark.ReferenceDefinition
        probe=session_markdown_string_parser(line)
        count=CommonMark.parse_link_label(probe)
        if count>0&&CommonMark.trypeek(probe,Char,nothing)==':'
            read(probe,Char)
            raw=session_markdown_raw_destination(probe)
            if !isnothing(raw)&&raw.normalized==data.destination
                definition.meta=Dict{String,Any}("JuliaForever2.displayHref"=>raw.display)
            end
        end
    end
    result
end
CommonMark.block_rule(rule::SessionMarkdownReferenceRule)=CommonMark.Rule((parser,container)->session_markdown_reference!(rule,parser,container),0.5,"[")

function session_markdown_resolve_references!(ast::CommonMark.Node)
    references=Dict{String,String}()
    for (node,entering) in ast
        data=node.t;metadata=node.meta
        if entering&&data isa CommonMark.ReferenceDefinition&&!isnothing(metadata)
            raw=get(metadata,"JuliaForever2.displayHref",nothing)
            key=CommonMark.normalize_reference(data.label)
            raw isa String&&!haskey(references,key)&&(references[key]=raw)
        end
    end
    for (node,entering) in ast
        data=node.t;metadata=node.meta
        if entering&&(data isa CommonMark.Link||data isa CommonMark.Image)&&!isnothing(metadata)
            key=get(metadata,"JuliaForever2.referenceLabel",nothing)
            if key isa String&&haskey(references,key)
                metadata["JuliaForever2.displayHref"]=references[key]
            end
        end
    end
    ast
end
