# Native command dispatch for the explicitly supported Pi terminal-math grammar.
function session_math_command!(parser::SessionMathParser)
    parser.depth+=1
    result=if parser.depth>parser.max_depth
        parser.supported=false;parser.position=length(parser.source)+1;""
    else
        session_math_command_body!(parser)
    end
    parser.depth-=1
    result
end

function session_math_command_body!(parser::SessionMathParser)
    parser.position+=1
    if parser.position>length(parser.source)
        parser.supported=false;""
    else
        first=session_math_peek(parser)
        if first in ('\n','\r')
            parser.position+=1
            first=='\r'&&session_math_peek(parser)=='\n'&&(parser.position+=1)
            " "
        else
            command=if session_math_ascii_letter(first)
                start=parser.position
                while session_math_ascii_letter(session_math_peek(parser))
                    parser.position+=1
                end
                session_math_slice(parser,start,parser.position-1)
            else
                parser.position+=1;string(first)
            end
            session_math_named_command!(parser,command)
        end
    end
end

function session_math_named_command!(parser::SessionMathParser,command::String)
    if command=="\\"
        "\n"
    elseif command in SESSION_MATH_SPACING_COMMANDS
        " "
    elseif command in SESSION_MATH_NEGATIVE_SPACING_COMMANDS
        "\0"
    elseif command in SESSION_MATH_FONT_SWITCH_COMMANDS
        session_math_skip!(parser);""
    elseif command in SESSION_MATH_IGNORED_COMMANDS||command in SESSION_MATH_SIZE_COMMANDS
        ""
    elseif command in ("{","}","\$","%","#","_","&")
        command
    elseif command=="|"
        "‖"
    elseif command=="not"
        value=String(strip(session_math_argument!(parser,false)))
        if haskey(SESSION_MATH_NEGATED_SYMBOLS,value)
            " "*SESSION_MATH_NEGATED_SYMBOLS[value]*" "
        elseif isempty(value)
            parser.supported=false;""
        else
            characters=collect(value)
            " "*string(first(characters))*"\u0338"*String(characters[2:end])*" "
        end
    elseif command in SESSION_MATH_LIMIT_OPERATORS
        session_math_operator!(parser,command,:bracket,true,true)
    elseif haskey(SESSION_MATH_SYMBOLS,command)
        symbol=SESSION_MATH_SYMBOLS[command]
        if command in SESSION_MATH_DISPLAY_LIMIT_SYMBOLS
            session_math_operator!(parser,symbol,:script,true)
        else
            command in ("cdot","times")||command in SESSION_MATH_RELATION_COMMANDS ? " "*symbol*" " : symbol
        end
    elseif command in SESSION_MATH_NAMED_OPERATORS
        SESSION_MATH_OPERATOR_START*command*SESSION_MATH_OPERATOR_END
    elseif command in ("left","middle","right")
        session_math_peek(parser)=='.'&&(parser.position+=1);""
    elseif command in ("frac","dfrac","tfrac")
        stack=parser.display&&parser.stack_fractions&&command!="tfrac"
        numerator=session_math_argument!(parser,!stack);denominator=session_math_argument!(parser,!stack)
        stack ? session_math_node!(parser,SessionMathFraction(session_math_normalize(numerator),session_math_normalize(denominator))) : session_math_fraction(numerator,denominator)
    elseif command=="sqrt"
        optional=session_math_optional!(parser);degree=isnothing(optional) ? nothing : String(strip(optional));value=session_math_argument!(parser)
        if isnothing(degree)||degree=="2"
            session_math_root(value)
        elseif degree=="3"
            session_math_root(value,"∛")
        elseif degree=="4"
            session_math_root(value,"∜")
        else
            session_math_script(degree,:sup)*session_math_root(value)
        end
    elseif command in ("boxed","fbox")
        "["*strip(session_math_argument!(parser))*"]"
    elseif command in ("binom","dbinom","tbinom")
        "("*session_math_argument!(parser)*" choose "*session_math_argument!(parser)*")"
    elseif haskey(SESSION_MATH_ACCENTS,command)
        value=session_math_argument!(parser)
        length(value)==1 ? value*SESSION_MATH_ACCENTS[command] : command*"("*value*")"
    elseif command=="mathbb"
        join(get(SESSION_MATH_BLACKBOARD,string(character),string(character)) for character in session_math_argument!(parser))
    elseif command=="operatorname"
        starred=session_math_peek(parser)=='*';starred&&(parser.position+=1)
        operator=String(strip(session_math_normalize(session_math_argument!(parser))))
        session_math_operator!(parser,operator,:bracket,starred,true)
    elseif command in ("mod","bmod")
        " mod "
    elseif command in ("pmod","pod")
        value=strip(session_math_argument!(parser));command=="pmod" ? " (mod "*value*")" : " ("*value*")"
    elseif command in ("overset","stackrel")
        upper=session_math_argument!(parser);value=strip(session_math_argument!(parser))
        value*session_math_script(upper,:sup)
    elseif command=="underset"
        lower=session_math_argument!(parser);value=strip(session_math_argument!(parser))
        value*session_math_script(lower,:sub)
    elseif command in SESSION_MATH_PLAIN_WRAPPERS
        value=session_math_argument!(parser)
        startswith(command,"text")||command=="mbox" ? value : String(strip(value))
    elseif command=="begin"
        session_math_environment!(parser)
    elseif command=="end"
        parser.supported=false;""
    else
        parser.supported=false;"\\"*command
    end
end
