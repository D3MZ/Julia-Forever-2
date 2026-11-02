import TreeSitter
import tree_sitter_bash_jll, tree_sitter_c_jll, tree_sitter_cpp_jll, tree_sitter_c_sharp_jll
import tree_sitter_css_jll, tree_sitter_elixir_jll, tree_sitter_go_jll, tree_sitter_html_jll
import tree_sitter_java_jll, tree_sitter_javascript_jll, tree_sitter_json_jll, tree_sitter_ocaml_jll
import tree_sitter_php_jll, tree_sitter_python_jll, tree_sitter_r_jll, tree_sitter_ruby_jll
import tree_sitter_rust_jll, tree_sitter_toml_jll, tree_sitter_typescript_jll

"""A trusted native grammar with its own parser and serialized access, never selected from a path."""
Base.@kwdef struct SessionSyntaxGrammar
    parser::TreeSitter.Parser
    query::TreeSitter.Query
    lock::ReentrantLock = ReentrantLock()
end

Base.@kwdef struct SessionSourceColor
    first::Int = 1
    last::Int = 0
    kind::Symbol = :default
    priority::Int = 0
end

const SESSION_PARSER_MODULES = Dict(
    "bash"=>tree_sitter_bash_jll, "c"=>tree_sitter_c_jll, "cpp"=>tree_sitter_cpp_jll,
    "csharp"=>tree_sitter_c_sharp_jll, "css"=>tree_sitter_css_jll, "elixir"=>tree_sitter_elixir_jll,
    "go"=>tree_sitter_go_jll, "html"=>tree_sitter_html_jll, "xml"=>tree_sitter_html_jll, "java"=>tree_sitter_java_jll,
    "javascript"=>tree_sitter_javascript_jll, "json"=>tree_sitter_json_jll, "ocaml"=>tree_sitter_ocaml_jll,
    "php"=>tree_sitter_php_jll, "python"=>tree_sitter_python_jll, "r"=>tree_sitter_r_jll,
    "ruby"=>tree_sitter_ruby_jll, "rust"=>tree_sitter_rust_jll, "toml"=>tree_sitter_toml_jll,
    "typescript"=>tree_sitter_typescript_jll)
const SESSION_PARSER_GRAMMARS = Dict{String,SessionSyntaxGrammar}()
const SESSION_PARSER_LOCK = ReentrantLock()
const SESSION_PARSER_EXTENSIONS = Dict(
    "ts"=>"typescript","tsx"=>"typescript","js"=>"javascript","jsx"=>"javascript","mjs"=>"javascript","cjs"=>"javascript",
    "py"=>"python","rb"=>"ruby","rs"=>"rust","go"=>"go","java"=>"java","kt"=>"kotlin","swift"=>"swift",
    "c"=>"c","h"=>"c","cpp"=>"cpp","cc"=>"cpp","cxx"=>"cpp","hpp"=>"cpp","cs"=>"csharp","php"=>"php",
    "sh"=>"bash","bash"=>"bash","zsh"=>"bash","fish"=>"fish","ps1"=>"powershell","sql"=>"sql",
    "html"=>"html","htm"=>"html","css"=>"css","scss"=>"scss","sass"=>"sass","less"=>"less",
    "json"=>"json","yaml"=>"yaml","yml"=>"yaml","toml"=>"toml","xml"=>"xml","md"=>"markdown","markdown"=>"markdown",
    "dockerfile"=>"dockerfile","makefile"=>"makefile","cmake"=>"cmake","lua"=>"lua","perl"=>"perl","r"=>"r",
    "scala"=>"scala","clj"=>"clojure","ex"=>"elixir","exs"=>"elixir","erl"=>"erlang","hs"=>"haskell","ml"=>"ocaml",
    "vim"=>"vim","graphql"=>"graphql","proto"=>"protobuf","tf"=>"hcl","hcl"=>"hcl")
const SESSION_PARSER_EAGER = Set(split("python java go javascript json cpp typescript php ruby c csharp bash rust scala kotlin swift perl lua"))
const SESSION_PARSER_PLAIN = Set(split("fish graphql hcl sass"))
const SOURCE_SYNTAX_TYPES = Set(split("string number boolean any void never unknown object symbol bigint i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result"))
const SESSION_PARSER_BUILTINS = Dict(
    "python"=>Set(split("abs all any ascii bin bool breakpoint bytearray bytes callable chr classmethod compile complex delattr dict dir divmod enumerate eval exec filter float format frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len list locals map max memoryview min next object oct open ord pow print property range repr reversed round set setattr slice sorted staticmethod str sum super tuple type vars zip __import__")),
    "c"=>Set(split("printf fprintf sprintf snprintf scanf fscanf sscanf puts putchar getchar fopen fclose fread fwrite malloc calloc realloc free memcpy memmove memset strlen strcpy strncpy strcmp strncmp strcat strchr strstr abort exit atoi atof qsort bsearch")),
    "r"=>Set(split("c sum min max abs sqrt mean print log exp sin cos tan length list matrix array data.frame as.numeric as.character is.na is.null")),
    "javascript"=>Set(split("console window document Math JSON Array Object Promise Number String Boolean Map Set Date")),
    "typescript"=>Set(split("console window document Math JSON Array Object Promise Number String Boolean Map Set Date")),
    "bash"=>Set(split("printf echo cd pwd read exit export source alias unset set test true false exec command local declare typeset readonly shift getopts eval trap wait kill jobs fg bg")))

function session_parser_grammar(language::String)
    Base.@lock SESSION_PARSER_LOCK get!(SESSION_PARSER_GRAMMARS,language) do
        native=TreeSitter.Language(SESSION_PARSER_MODULES[language])
        parent=language=="cpp" ? "c" : language=="typescript" ? "javascript" : ""
        querytext=get(native.queries,"highlights","")
        if !isempty(parent)
            inherited=TreeSitter.Language(SESSION_PARSER_MODULES[parent])
            querytext=get(inherited.queries,"highlights","")*"\n"*querytext
        end
        SessionSyntaxGrammar(TreeSitter.Parser(native;languages=TreeSitter.Language[]),TreeSitter.Query(native,querytext),ReentrantLock())
    end
end

function session_parser_field(node::TreeSitter.Node,name::String)
    child=TreeSitter.Node(TreeSitter.API.ts_node_child_by_field_name(node.ptr,name,sizeof(name)),node.tree)
    TreeSitter.is_null(child) ? nothing : child
end
session_parser_type(::Nothing)=""
session_parser_type(node::TreeSitter.Node)=TreeSitter.is_null(node) ? "" : TreeSitter.node_type(node)
session_parser_range(node::TreeSitter.Node)=TreeSitter.byte_range(node)
session_parser_text(text::String,node::TreeSitter.Node)=String(TreeSitter.slice(text,node))
function session_parser_color!(colors::Vector{SessionSourceColor},node::TreeSitter.Node,kind::Symbol;priority::Int=0)
    a,b=session_parser_range(node)
    session_parser_color!(colors,a,b,kind;priority)
end
function session_parser_color!(colors::Vector{SessionSourceColor},a::Int,b::Int,kind::Symbol;priority::Int=0)
    if a<=b&&kind!=:default
        push!(colors,SessionSourceColor(first=a,last=b,kind=kind,priority=priority))
    end
    nothing
end

function session_parser_capture_kind(language::String,capture::String,node::TreeSitter.Node,text::String)
    parent=session_parser_type(TreeSitter.parent(node))
    word=session_parser_text(text,node)
    head=first(split(capture,'.'))
    kind=if head=="comment"
        :comment
    elseif head in ("string","character","escape")
        :string
    elseif head in ("number","boolean")||capture=="constant.builtin"
        :number
    elseif head in ("keyword","conditional","repeat","include")
        :keyword
    else
        :default
    end
    if language in ("c","cpp")
        if capture=="type"&&session_parser_type(node)=="primitive_type"
            kind=:keyword
        elseif startswith(capture,"function")&&parent=="function_declarator"
            kind=:function_name
        elseif language=="cpp"&&parent=="type_parameter_declaration"
            kind=:default
        elseif word in get(SESSION_PARSER_BUILTINS,"c",Set{String}())
            kind=:type
        end
    elseif language=="python"
        if word in SESSION_PARSER_BUILTINS[language]
            kind=:type
        elseif capture=="function"&&parent=="function_definition"||capture=="constructor"&&parent=="class_definition"
            kind=:function_name
        end
    elseif language in ("javascript","typescript")
        if word in SESSION_PARSER_BUILTINS[language]||capture=="type.builtin"
            kind=:type
        elseif capture=="constructor"&&parent in ("class_declaration","class_heritage")||startswith(capture,"function")&&parent in ("function_declaration","method_definition")
            kind=:function_name
        end
    elseif language=="go"
        if capture=="function"&&parent in ("function_declaration","method_declaration")
            kind=:function_name
        end
    elseif language=="java"
        if capture=="type.builtin"
            kind=:keyword
        elseif head=="type"&&parent in ("class_declaration","interface_declaration")||startswith(capture,"function")&&parent in ("method_declaration","constructor_declaration")
            kind=:function_name
        end
    elseif language=="csharp"
        if capture=="type.builtin"
            kind=:type
        elseif head=="type"&&parent=="class_declaration"||head=="function"&&parent=="method_declaration"
            kind=:function_name
        end
    elseif language=="ruby"
        if capture=="constructor"&&parent=="class"||startswith(capture,"function")&&parent=="method"
            kind=:function_name
        end
    elseif language=="php"
        if capture=="tag"
            kind=:meta
        elseif head=="variable"
            kind=:variable
        elseif capture=="type.builtin"
            kind=parent=="function_definition" ? :function_name : :keyword
        elseif head=="function"&&parent=="function_definition"
            kind=:function_name
        end
    elseif language=="rust"
        if head=="type"&&parent in ("struct_item","enum_item","trait_item")||head=="function"&&parent=="function_item"
            kind=:function_name
        elseif capture in ("type.builtin","function.macro")||word in SOURCE_SYNTAX_TYPES
            kind=:type
        elseif capture=="variable.builtin"
            kind=:keyword
        end
    elseif language=="json"
        if capture=="string.special.key"
            kind=:variable
        end
    elseif language=="toml"
        if head=="type"
            kind=parent=="pair" ? :variable : :default
        end
    elseif language=="css"
        if head=="string"
            kind=:default
        end
    elseif language=="r"
        if word in SESSION_PARSER_BUILTINS[language]
            kind=:type
        end
    elseif language in ("html","xml")
        if capture=="tag"
            kind=:keyword
        elseif capture=="attribute"
            kind=:variable
        end
    elseif language=="bash"
        if capture=="function"&&word in SESSION_PARSER_BUILTINS[language]
            kind=:type
        end
    end
    kind
end

function session_parser_header!(colors::Vector{SessionSourceColor},node::TreeSitter.Node,text::String,language::String)
    kind=session_parser_type(node)
    a,b=session_parser_range(node)
    name=session_parser_field(node,"name")
    body=session_parser_field(node,"body")
    params=session_parser_field(node,"parameters")
    if language=="cpp"&&kind=="template_declaration"
        children=collect(TreeSitter.children(node))
        definition=findfirst(n->session_parser_type(n)=="function_definition",children)
        if !isnothing(definition)
            body=session_parser_field(children[definition],"body")
            isnothing(body)||session_parser_color!(colors,a,first(session_parser_range(body))-1,:function_name)
        end
    elseif language in ("c","cpp")&&kind=="function_definition"
        declarator=session_parser_field(node,"declarator")
        if !isnothing(body)
            session_parser_color!(colors,a,first(session_parser_range(body))-1,:function_name)
        end
        if !isnothing(declarator)
            parameters=session_parser_field(declarator,"parameters")
            isnothing(parameters)||session_parser_color!(colors,parameters,:variable)
        end
    elseif language in ("python","javascript","typescript","go","java","csharp","ruby","php")
        function_node=kind in ("function_definition","function_declaration","method_definition","method_declaration","constructor_declaration","method")
        if function_node&&!isnothing(name)
            nameend=last(session_parser_range(name))
            finish=if (language in ("python","java","php")||language in ("javascript","typescript")&&kind=="function_declaration")&&!isnothing(body)
                first(session_parser_range(body))-1
            elseif !isnothing(params)
                last(session_parser_range(params))
            else
                nameend
            end
            if language=="python"
                stop=findlast(':',SubString(text,a,thisind(text,finish)))
                isnothing(stop)||(finish=a+stop-1)
            end
            beginpos=a
            if language in ("javascript","typescript")&&kind=="method_definition"
                beginpos=first(session_parser_range(name))
            end
            session_parser_color!(colors,beginpos,finish,:function_name)
            if !isnothing(params)
                x,y=session_parser_range(params)
                interior=language in ("python","javascript","typescript","csharp","php")
                session_parser_color!(colors,x+Int(interior),y-Int(interior),:variable)
            end
        end
        if language in ("javascript","typescript")&&kind=="arrow_function"
            annotation=session_parser_field(node,"return_type")
            children=collect(TreeSitter.children(node))
            arrow=findfirst(n->session_parser_type(n)=="=>",children)
            if !isnothing(arrow)
                endpoint=last(session_parser_range(children[arrow]))
                if !isnothing(annotation)
                    parts=collect(TreeSitter.named_children(annotation))
                    if !isempty(parts)
                        start=first(session_parser_range(parts[1]))
                        session_parser_color!(colors,start,endpoint,:function_name;priority=2)
                        session_parser_color!(colors,parts[1],:variable;priority=4)
                    end
                elseif !isnothing(params)
                    x,y=session_parser_range(params)
                    session_parser_color!(colors,x,endpoint,:function_name)
                    session_parser_color!(colors,x+1,y-1,:variable)
                end
            end
        end
        if kind in ("class_definition","class_declaration","class")&&!isnothing(name)&&language!="csharp"
            finish=isnothing(body) ? last(session_parser_range(name)) : first(session_parser_range(body))-1
            if language=="ruby"
                finish=last(session_parser_range(name))
            elseif language=="python"
                stop=findfirst(':',SubString(text,a,thisind(text,finish)))
                isnothing(stop)||(finish=a+stop-1)
                bases=session_parser_field(node,"superclasses")
                if !isnothing(bases)
                    x,y=session_parser_range(bases);session_parser_color!(colors,x+1,y-1,:variable)
                end
            elseif language=="java"
                children=collect(TreeSitter.children(node))
                keyword=findfirst(n->session_parser_type(n)=="class",children)
                isnothing(keyword)||(a=first(session_parser_range(children[keyword])))
            end
            session_parser_color!(colors,a,finish,:type)
        end
    elseif language=="elixir"&&kind=="call"
        children=collect(TreeSitter.named_children(node))
        if length(children)>=2
            command=session_parser_text(text,children[1])
            arguments=collect(TreeSitter.named_children(children[2]))
            if command in ("defmodule","defprotocol","defimpl","def","defp","defmacro","defmacrop")&&!isempty(arguments)
                target=arguments[1]
                targetchildren=collect(TreeSitter.named_children(target))
                name=session_parser_type(target)=="call"&&!isempty(targetchildren) ? targetchildren[1] : target
                session_parser_color!(colors,a,last(session_parser_range(name)),command in ("defmodule","defprotocol","defimpl") ? :type : :function_name)
                session_parser_color!(colors,name,:function_name;priority=2)
            end
        end
    elseif language=="rust"&&kind in ("struct_item","enum_item","trait_item","function_item")&&!isnothing(name)
        session_parser_color!(colors,a,last(session_parser_range(name)),kind=="function_item" ? :function_name : :type)
    end
    nothing
end

function session_parser_nodes!(colors::Vector{SessionSourceColor},tree::TreeSitter.Tree,text::String,language::String)
    pending=[TreeSitter.root(tree)]
    protected=Tuple{Int,Int}[]
    while !isempty(pending)
        node=pop!(pending)
        kind=session_parser_type(node)
        a,b=session_parser_range(node)
        session_parser_header!(colors,node,text,language)
        if kind in ("string","string_literal","interpreted_string_literal","raw_string_literal","encapsed_string","interpolated_string_expression","template_string","regex")
            session_parser_color!(colors,node,:string)
        elseif language=="json"&&kind=="pair"
            key=session_parser_field(node,"key")
            if !isnothing(key)
                session_parser_color!(colors,key,:variable;priority=9)
                push!(protected,session_parser_range(key))
            end
        elseif language=="bash"&&kind in ("simple_expansion","expansion")
            session_parser_color!(colors,node,:variable;priority=3)
        elseif language=="bash"&&kind=="command_substitution"
            session_parser_color!(colors,node,:text;priority=3)
        elseif kind in ("interpolation","template_substitution")
            session_parser_color!(colors,node,:text;priority=2)
        elseif kind in ("preproc_include","preproc_def","preproc_function_def","preproc_call","attribute_item","decorator","doctype")
            endbyte=b
            while endbyte>=a&&text[thisind(text,endbyte)]=='\n'
                endbyte-=1
            end
            session_parser_color!(colors,a,endbyte,:meta;priority=9)
            push!(protected,(a,endbyte))
        elseif language=="php"&&kind=="variable_name"
            session_parser_color!(colors,node,:variable)
        elseif language=="css"&&kind in ("color_value","integer_value","float_value")
            session_parser_color!(colors,node,:number;priority=2)
        elseif language=="ocaml"&&kind=="unit"
            session_parser_color!(colors,node,:number)
        elseif language in ("html","xml")&&kind in ("start_tag","end_tag","self_closing_tag")
            session_parser_color!(colors,node,:punctuation)
        elseif language in ("html","xml")&&kind=="quoted_attribute_value"
            session_parser_color!(colors,node,:string)
        end
        append!(pending,reverse(collect(TreeSitter.children(node))))
    end
    protected
end

function session_parser_colors(grammar::SessionSyntaxGrammar,language::String,text::String;depth::Int=0,phase::Symbol=:full)
    Base.@lock grammar.lock begin
        tree=parse(grammar.parser,text;injections=false)
        colors=SessionSourceColor[]
        protected=session_parser_nodes!(colors,tree,text,language)
        if language=="xml"
            cursor=1
            while cursor<=ncodeunits(text)
                opening=findnext("<?",text,cursor)
                if isnothing(opening)
                    cursor=ncodeunits(text)+1
                else
                    closing=findnext("?>",text,last(opening)+1)
                    finish=isnothing(closing) ? ncodeunits(text) : last(closing)
                    session_parser_color!(colors,first(opening),finish,:meta;priority=1000)
                    push!(protected,(first(opening),finish))
                    cursor=finish+1
                end
            end
        end
        for found in eachmatch(grammar.query,tree)
            if TreeSitter.predicate(grammar.query,found,text)
                for capture in TreeSitter.captures(found)
                    a,b=session_parser_range(capture.node)
                    if !any(range->range[1]<=a&&b<=range[2],protected)
                        kind=session_parser_capture_kind(language,TreeSitter.capture_name(grammar.query,capture),capture.node,text)
                        session_parser_color!(colors,a,b,kind;priority=kind==:variable ? 3 : 1)
                    end
                end
            end
        end
        if language in ("html","xml")&&depth<3
            pending=[TreeSitter.root(tree)]
            while !isempty(pending)
                node=pop!(pending)
                kind=session_parser_type(node)
                if kind=="raw_text"
                    parent=session_parser_type(TreeSitter.parent(node))
                    innerlanguage=parent=="script_element" ? "javascript" : parent=="style_element" ? "css" : ""
                    if !isempty(innerlanguage)
                        innertext=session_parser_text(text,node)
                        offset=first(session_parser_range(node))-1
                        for color in session_parser_colors(session_parser_grammar(innerlanguage),innerlanguage,innertext;depth=depth+1)
                            push!(colors,SessionSourceColor(first=color.first+offset,last=color.last+offset,kind=color.kind,priority=color.priority))
                        end
                    end
                end
                append!(pending,TreeSitter.children(node))
            end
        end
        if language=="typescript"&&depth<3
            pending=[TreeSitter.root(tree)]
            starts=Int[]
            while !isempty(pending)
                node=pop!(pending)
                if session_parser_type(node)=="type_parameters"&&session_parser_type(TreeSitter.parent(node))=="arrow_function"
                    push!(starts,first(session_parser_range(node)))
                end
                append!(pending,TreeSitter.children(node))
            end
            if !isempty(starts)
                firstbyte=minimum(starts)
                tail=String(SubString(text,firstbyte))
                session_parser_color!(colors,firstbyte,ncodeunits(text),:plain;priority=1000)
                if phase==:full
                    for color in session_parser_colors(session_parser_grammar("html"),"html",tail;depth=depth+1,phase)
                        push!(colors,SessionSourceColor(first=firstbyte+color.first-1,last=firstbyte+color.last-1,kind=color.kind,priority=1001+color.priority))
                    end
                end
            end
        end
        colors
    end
end


"""A bounded syntax result with explicit unsupported, invalid-source, and byte-budget outcomes."""
Base.@kwdef struct SourceSyntaxResult
    status::Symbol = :unsupported
    language::String = ""
    colors::Vector{SessionSourceColor} = SessionSourceColor[]
end

"""Color inert source using only installed, trusted native grammars and explicit byte bounds."""
function source_syntax_highlight(language::AbstractString,source::AbstractString;phase::Symbol=:full,max_bytes::Int=262_144)
    phase in (:eager,:full)||error("Unsupported syntax initialization phase")
    max_bytes>=0||error("Source parser byte budget must be nonnegative")
    name=String(language)
    text=String(source)
    status=if !haskey(SESSION_PARSER_MODULES,name)
        :unsupported
    elseif phase==:eager&&!(name in SESSION_PARSER_EAGER)
        :unavailable
    elseif !isvalid(text)
        :invalid_source
    elseif ncodeunits(text)>max_bytes
        :byte_budget
    else
        :success
    end
    colors=status==:success ? session_parser_colors(session_parser_grammar(name),name,text;phase) : SessionSourceColor[]
    SourceSyntaxResult(;status,language=name,colors)
end
