# Native bounded parser for the pinned Pi terminal-math grammar, not a TeX engine.
Base.@kwdef mutable struct SessionMathParser
    source::Vector{Char}
    nodes::Vector{SessionMathNode}=SessionMathNode[]
    display::Bool=false
    position::Int=1
    supported::Bool=true
    stack_fractions::Bool=true
    script_depth::Int=0
    depth::Int=0
    max_depth::Int=64
    max_nodes::Int=4096
end
session_math_space(character::Char)=isspace(character)||character=='\ufeff'
session_math_ascii_letter(character::Char)='a'<=character<='z'||'A'<=character<='Z'
session_math_peek(parser::SessionMathParser,position::Int=parser.position)=get(parser.source,position,'\0')
session_math_slice(parser::SessionMathParser,first::Int,last::Int=length(parser.source))=first<=last ? String(parser.source[max(1,first):min(last,length(parser.source))]) : ""
function session_math_skip!(parser::SessionMathParser;horizontal::Bool=false)
    while parser.position<=length(parser.source)&&(horizontal ? session_math_peek(parser) in (' ','\t') : session_math_space(session_math_peek(parser)))
        parser.position+=1
    end
    nothing
end
function session_math_node!(parser::SessionMathParser,node::SessionMathNode)
    if length(parser.nodes)>=parser.max_nodes
        parser.supported=false
        ""
    else
        push!(parser.nodes,node)
        SESSION_MATH_MARKER_START*string(length(parser.nodes)-1)*SESSION_MATH_MARKER_END
    end
end

function session_math_parse!(parser::SessionMathParser)
    rendered=session_math_sequence!(parser)
    parser.supported&&parser.position==length(parser.source)+1 ? session_math_normalize(rendered) : nothing
end

function session_math_sequence!(parser::SessionMathParser,ending::Char='\0')
    result="";done=false;closed=false
    parser.depth+=1
    if parser.depth>parser.max_depth
        parser.supported=false;done=true;parser.position=length(parser.source)+1
    end
    while parser.position<=length(parser.source)&&!done
        character=session_math_peek(parser)
        if ending!='\0'&&character==ending
            parser.position+=1;closed=true;done=true
        elseif character=='}'
            parser.supported=false;done=true
        elseif character=='{'
            parser.position+=1;result*=session_math_sequence!(parser,'}')
        elseif character=='\\'
            command=session_math_command!(parser)
            if command=="\0"
                result=String(rstrip(result));result=String(chopsuffix(result,SESSION_MATH_OPERATOR_END))
            else
                result*=command
            end
        elseif character in ('^','_')
            parser.position+=1;result=String(rstrip(result));script=session_math_scripts!(parser,character)
            result=endswith(result,SESSION_MATH_OPERATOR_END) ? String(chopsuffix(result,SESSION_MATH_OPERATOR_END))*script*SESSION_MATH_OPERATOR_END : result*script
        elseif session_math_space(character)
            session_math_skip!(parser);result*=" "
        elseif character in ('=','<','>')
            result=String(rstrip(result))*" "*string(character)*" ";parser.position+=1
        elseif character=='&'
            parser.position+=1
        elseif character=='~'
            parser.position+=1;result*=" "
        else
            marker=character=='.' ? match(SESSION_MATH_TRAILING_MARKER,result) : nothing
            capture=isnothing(marker) ? nothing : only(marker.captures)
            index=isnothing(capture) ? nothing : tryparse(Int,capture)
            node=isnothing(index)||!(0<=index<length(parser.nodes)) ? nothing : parser.nodes[index+1]
            if node isa SessionMathMatrix&&!isempty(node.lines)
                node.lines[end]*=string(character);parser.position+=1
            else
                start=parser.position;parser.position+=1
                while parser.position<=length(parser.source)&&!(session_math_peek(parser) in ('{','}','\\','^','_','=','<','>','&','~','.'))&&!session_math_space(session_math_peek(parser))
                    parser.position+=1
                end
                result*=session_math_slice(parser,start,parser.position-1)
            end
        end
        !parser.supported&&(done=true)
    end
    ending!='\0'&&!closed&&(parser.supported=false)
    parser.depth-=1
    result
end

function session_math_argument!(parser::SessionMathParser,stack::Bool=true)
    previous=parser.stack_fractions;parser.stack_fractions&=stack
    session_math_skip!(parser)
    value=if parser.position>length(parser.source)
        parser.supported=false;""
    elseif session_math_peek(parser)=='{'
        parser.position+=1;session_math_sequence!(parser,'}')
    elseif session_math_peek(parser)=='\\'
        session_math_command!(parser)
    else
        character=session_math_peek(parser);parser.position+=1;string(character)
    end
    parser.stack_fractions=previous
    value
end

function session_math_scripts!(parser::SessionMathParser,initial::Char)
    scripts=Dict{Symbol,String}();order=Symbol[]
    kind=initial=='_' ? :sub : :sup
    parser.script_depth+=1;scripts[kind]=session_math_argument!(parser,false);parser.script_depth-=1;push!(order,kind)
    position=parser.position
    while position<=length(parser.source)&&session_math_space(session_math_peek(parser,position))
        position+=1
    end
    next=session_math_peek(parser,position)
    if next in ('^','_')&&next!=initial
        parser.position=position+1;kind=next=='_' ? :sub : :sup
        parser.script_depth+=1;scripts[kind]=session_math_argument!(parser,false);parser.script_depth-=1;push!(order,kind)
    end
    lower=get(scripts,:sub,nothing);upper=get(scripts,:sup,nothing)
    lower_unicode=isnothing(lower) ? nothing : session_math_unicode_script(lower,:sub)
    upper_unicode=isnothing(upper) ? nothing : session_math_unicode_script(upper,:sup)
    can_layout=!any(value->occursin('/',value)||(!occursin(SESSION_MATH_MARKER_START,value)&&length(value)>1&&!occursin(r"[A-Z*∗]",value)),values(scripts))
    needs_layout=parser.display&&can_layout&&(parser.script_depth>0||!isnothing(lower)&&isnothing(lower_unicode)||!isnothing(upper)&&isnothing(upper_unicode))
    if needs_layout
        session_math_node!(parser,SessionMathScript(isnothing(lower) ? nothing : session_math_normalize(lower),isnothing(upper) ? nothing : session_math_normalize(upper)))
    else
        join(session_math_script(scripts[kind],kind) for kind in order)
    end
end

function session_math_nested!(parser::SessionMathParser,source::AbstractString,stack::Bool=true)
    nested=SessionMathParser(;source=collect(String(source)),nodes=parser.nodes,display=parser.display&&stack,depth=parser.depth,max_depth=parser.max_depth,max_nodes=parser.max_nodes)
    rendered=session_math_parse!(nested)
    if isnothing(rendered)
        parser.supported=false;String(source)
    else
        rendered
    end
end

function session_math_optional!(parser::SessionMathParser)
    session_math_skip!(parser;horizontal=true)
    if session_math_peek(parser)!='['
        nothing
    else
        ending=findnext(==(']'),parser.source,parser.position+1)
        if isnothing(ending)
            parser.supported=false;nothing
        else
            value=session_math_slice(parser,parser.position+1,ending-1);parser.position=ending+1
            session_math_nested!(parser,value)
        end
    end
end

function session_math_raw_group!(parser::SessionMathParser)
    session_math_skip!(parser;horizontal=true)
    if session_math_peek(parser)!='{'
        parser.supported=false;nothing
    else
        parser.position+=1;start=parser.position;depth=1;value=nothing
        while parser.position<=length(parser.source)&&depth>0
            character=session_math_peek(parser)
            if character=='\\'
                parser.position+=2
            else
                character=='{'&&(depth+=1);character=='}'&&(depth-=1)
                depth==0&&(value=session_math_slice(parser,start,parser.position-1))
                parser.position+=1
            end
        end
        depth>0&&(parser.supported=false)
        value
    end
end

function session_math_operator!(parser::SessionMathParser,operator::String,lower_style::Symbol,limits::Bool,spaced::Bool=false)
    position=parser.position
    while session_math_peek(parser,position) in (' ','\t')
        position+=1
    end
    modifier=match(r"^\\(limits|nolimits)(?![A-Za-z])",session_math_slice(parser,position))
    if !isnothing(modifier)
        limits=only(modifier.captures)=="limits";parser.position=position+length(modifier.match)
    end
    lower=nothing;upper=nothing;done=false
    while !done
        position=parser.position
        while session_math_peek(parser,position) in (' ','\t')
            position+=1
        end
        kind=session_math_peek(parser,position)
        if !(kind in ('_','^'))
            done=true
        else
            parser.position=position+1;value=replace(session_math_normalize(session_math_argument!(parser,false))," "=>"")
            if kind=='_'
                !isnothing(lower)&&(parser.supported=false);lower=value
            else
                !isnothing(upper)&&(parser.supported=false);upper=value
            end
            !parser.supported&&(done=true)
        end
    end
    if parser.display&&limits&&(!isnothing(lower)||!isnothing(upper))
        session_math_node!(parser,SessionMathOperator(operator,lower,upper))
    else
        rendered=operator
        !isnothing(lower)&&(rendered*=lower_style==:bracket ? "["*lower*"]" : session_math_script(lower,:sub))
        !isnothing(upper)&&(rendered*=session_math_script(upper,:sup))
        spaced ? " "*rendered*" " : rendered
    end
end

"""Render the bounded native terminal-math grammar, returning nothing for unsupported, unsafe or malformed input."""
function session_math_render(source::AbstractString;display::Bool=false,max_bytes::Int=65_536,max_depth::Int=64,max_nodes::Int=4096)
    text=String(source)
    valid=isvalid(text)&&ncodeunits(text)<=max_bytes&&max_depth>0&&max_nodes>0&&all(character->!('\U000f0000'<=character<='\U000f0005')&&(!(iscntrl(character))||character in ('\n','\r','\t')),text)
    if !valid
        nothing
    else
        parser=SessionMathParser(;source=collect(text),display,max_depth,max_nodes)
        rendered=session_math_parse!(parser)
        output=if isnothing(rendered)
            nothing
        elseif isempty(parser.nodes)
            replace(rendered,SESSION_MATH_PROTECTED_SPACE=>" ")
        else
            lines=session_math_layout(rendered,parser.nodes).lines
            indentation=minimum((length(line)-length(lstrip(line)) for line in lines if !isempty(strip(line)));init=typemax(Int))
            trimmed=String[indentation==typemax(Int) ? "" : rstrip(join(Iterators.drop(line,indentation))) for line in lines]
            replace(String(rstrip(join(trimmed,'\n'))),SESSION_MATH_PROTECTED_SPACE=>" ")
        end
        isnothing(output)||all(character->!('\U000f0000'<=character<='\U000f0005')&&(!iscntrl(character)||character in ('\n','\r','\t')),output) ? output : nothing
    end
end
