"""Native, replaceable source highlighting; source characters are preserved and never evaluated."""
Base.@kwdef struct SessionSyntaxRenderer
    phase::Symbol = :full
end
struct SessionSyntaxLines
    lines::SessionDisplayRows
end
const SESSION_SYNTAX_EXTENSIONS = Dict(
    "py"=>"python","ts"=>"typescript","tsx"=>"typescript","js"=>"javascript","jsx"=>"javascript","mjs"=>"javascript","cjs"=>"javascript",
    "json"=>"json","md"=>"markdown","markdown"=>"markdown","yaml"=>"yaml","yml"=>"yaml","html"=>"html","htm"=>"html","xml"=>"html",
    "sh"=>"bash","bash"=>"bash","zsh"=>"bash","sql"=>"sql","rs"=>"rust")
const SESSION_SYNTAX_KEYWORDS=Dict(
    "python"=>Set(split("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield")),
    "javascript"=>Set(split("async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield")),
    "typescript"=>Set(split("abstract any as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function if implements import in instanceof interface keyof let module namespace never new public private protected readonly require return super switch this throw try type typeof var void while with yield")),
    "rust"=>Set(split("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while")),
    "sql"=>Set(split("select from where insert into update delete create table alter drop join left right inner outer on as and or not null group by order having limit offset values set distinct union all exists case when then else end")),
    "bash"=>Set(split("if then else elif fi for while until do done case esac function in select time coproc")))
const SESSION_SYNTAX_TYPES=Set(split("string number boolean any void never unknown object symbol bigint i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result"))
const SESSION_SYNTAX_BUILTINS=Dict("python"=>Set(split("print len range int str float bool list dict set tuple open sum min max abs enumerate zip isinstance super object type")),
    "javascript"=>Set(split("console window document Math JSON Array Object Promise Number String Boolean Map Set Date")),
    "typescript"=>Set(split("console window document Math JSON Array Object Promise Number String Boolean Map Set Date")),
    "bash"=>Set(split("printf echo cd pwd read exit export source alias unset set test true false exec command local declare typeset readonly shift getopts eval trap wait kill jobs fg bg")))

function session_syntax_style(kind::Symbol;bold=false,italic=false,underline=false)
    names=(comment="syntaxComment",keyword="syntaxKeyword",function_name="syntaxFunction",variable="syntaxVariable",string="syntaxString",number="syntaxNumber",type="syntaxType",operator="syntaxOperator",punctuation="syntaxPunctuation")
    colors=(comment=(157,165,169),keyword=(105,173,208),function_name=(205,154,34),variable=(93,179,186),string=(222,141,90),number=(104,183,141),type=(167,152,215),operator=(157,165,169),punctuation=(157,165,169))
    runtime=isdefined(@__MODULE__,:ACTIVE_NATIVE_THEME) ? ACTIVE_NATIVE_THEME[] : nothing
    fg=!isnothing(runtime)&&haskey(names,kind) ? theme_token_style(runtime,names[kind]).fg : haskey(colors,kind) ? Tachikoma.ColorRGB(colors[kind]...) : kind==:text ? session_display_style(:text).fg : Tachikoma.NoColor()
    Tachikoma.Style(;fg,bold,italic,underline)
end

function session_syntax_paint!(styles,positions,match,style;capture=0)
    if capture==0
        firstbyte=match.offset;text=match.match
    else
        firstbyte=match.offsets[capture];text=match[capture]
    end
    if firstbyte>0&&!isnothing(text)
        firstchar=positions[firstbyte]
        lastchar=positions[firstbyte+ncodeunits(text)]-1
        styles[firstchar:lastchar].=Ref(style)
    end
    nothing
end
function session_syntax_positions(text)
    positions=zeros(Int,ncodeunits(text)+1)
    for (index,byte) in enumerate(eachindex(text))
        positions[byte]=index
    end
    positions[end]=length(text)+1
    positions
end

function session_syntax_lex!(styles,positions,text,language)
    pattern=language in ("python","bash","yaml") ? r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\#[^\n]*|\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b|[\p{L}_][\p{L}\p{N}_]*" : r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/|--[^\n]*|\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b|[\p{L}_][\p{L}\p{N}_]*!?"
    words=get(SESSION_SYNTAX_KEYWORDS,language,Set{String}())
    builtins=get(SESSION_SYNTAX_BUILTINS,language,Set{String}())
    for token in eachmatch(pattern,text)
        word=String(token.match)
        kind=if startswith(word,"#")||startswith(word,"//")||startswith(word,"/*")||(language=="sql"&&startswith(word,"--"))
            :comment
        elseif first(word) in ('"','\'','`')
            :string
        elseif language=="sql" && !isdigit(first(word))
            session_sql_word_kind(word,text,token.offset+ncodeunits(word))
        elseif isdigit(first(word)) || word in ("true","false","null","None","True","False")
            :number
        elseif (language=="sql" ? lowercase(word) : word) in words || language=="sql"&&lowercase(word)=="none"
            :keyword
        elseif word in builtins || language in ("typescript","rust")&&word in SESSION_SYNTAX_TYPES || language=="rust"&&endswith(word,"!")
            :type
        else
            :default
        end
        session_syntax_paint!(styles,positions,token,session_syntax_style(kind))
        if kind==:string&&language in ("javascript","typescript")&&startswith(word,"`")
            for part in eachmatch(r"\$\{[^}]*\}",word)
                start=token.offset+part.offset-1;stop=start+ncodeunits(part.match)
                styles[positions[start]:positions[stop]-1].=Ref(session_syntax_style(:text))
            end
        elseif kind==:string&&language=="bash"
            for part in eachmatch(r"\$[A-Za-z_][A-Za-z_0-9]*|\$\{[^}]*\}",word)
                start=token.offset+part.offset-1;stop=start+ncodeunits(part.match)
                styles[positions[start]:positions[stop]-1].=Ref(session_syntax_style(:variable))
            end
        end
    end
    nothing
end

function session_syntax_semantics!(styles,positions,text,language)
    if language in ("python","javascript","rust")
        declaration=language=="python" ? r"\b(def)(\s+)([\p{L}_][\p{L}\p{N}_]*)(\()([^\n)]*)(\)\s*:?)" : language=="javascript" ? r"\b(function)(\s+)([\p{L}_][\p{L}\p{N}_]*)(\()([^\n)]*)(\)\s*)" : r"\b(fn)(\s+)([\p{L}_][\p{L}\p{N}_]*)"
        for item in eachmatch(declaration,text)
            # Only declarations beginning in a keyword token qualify, not strings/comments.
            if styles[positions[item.offset]]==session_syntax_style(:keyword)
                for field in 2:length(item.captures)
                    session_syntax_paint!(styles,positions,item,session_syntax_style(field==5 ? :variable : :function_name);capture=field)
                end
            end
        end
    elseif language=="typescript"
        for item in eachmatch(r"\)(\s*:\s*)([A-Za-z_][A-Za-z_0-9]*)(\s*=>)",text)
            session_syntax_paint!(styles,positions,item,session_syntax_style(:variable);capture=2)
            session_syntax_paint!(styles,positions,item,session_syntax_style(:function_name);capture=3)
        end
    elseif language=="json"
        for item in eachmatch(r"(\"(?:\\.|[^\"\\])*\")\s*:",text)
            session_syntax_paint!(styles,positions,item,session_syntax_style(:variable);capture=1)
        end
    elseif language=="sql"
        for item in eachmatch(r"[=<>+*/%-]",text)
            if styles[positions[item.offset]]==session_syntax_style(:default)
                session_syntax_paint!(styles,positions,item,session_syntax_style(:operator))
            end
        end
    end
    nothing
end

function session_syntax_markup!(styles,positions,text,language)
    if language=="markdown"
        for (pattern,style) in ((r"\*\*[^\n]+?\*\*|__[^\n]+?__",session_syntax_style(:default;bold=true)),
                (r"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)",session_syntax_style(:default;italic=true)))
            for token in eachmatch(pattern,text)
                session_syntax_paint!(styles,positions,token,style)
            end
        end
        for token in eachmatch(r"\[([^\]\n]*)\]\(([^)\n]+)\)",text)
            session_syntax_paint!(styles,positions,token,session_syntax_style(:string);capture=1)
            session_syntax_paint!(styles,positions,token,session_syntax_style(:default;underline=true);capture=2)
        end
    elseif language=="yaml"
        for token in eachmatch(r"(?m)^\s*([A-Za-z_][A-Za-z_0-9-]*:)",text)
            session_syntax_paint!(styles,positions,token,session_syntax_style(:variable);capture=1)
        end
        for token in eachmatch(r"(?m)(?:^[ \t]*-[ \t]+|:[ \t]+)([^\n#]+)",text)
            value=strip(token[1]::AbstractString)
            if !(lowercase(value) in ("true","false","null","~"))&&isnothing(tryparse(Float64,value))
                session_syntax_paint!(styles,positions,token,session_syntax_style(:string);capture=1)
            end
        end
    elseif language=="html"
        for token in eachmatch(r"<!--[\s\S]*?-->|</?[A-Za-z][^>]*>",text)
            if startswith(token.match,"<!--")
                session_syntax_paint!(styles,positions,token,session_syntax_style(:comment))
            else
                session_syntax_paint!(styles,positions,token,session_syntax_style(:punctuation))
                for part in eachmatch(r"(?<=<)/?([A-Za-z][A-Za-z_0-9:-]*)|([A-Za-z_][A-Za-z_0-9:-]*)(?=\s*=)|(\"[^\"]*\"|'[^']*')",token.match)
                    capture=!isnothing(part[1]) ? 1 : !isnothing(part[2]) ? 2 : 3
                    byte=token.offset+part.offsets[capture]-1
                    chars=positions[byte]:positions[byte+ncodeunits(part[capture]::AbstractString)]-1
                    styles[chars].=Ref(session_syntax_style(capture==1 ? :keyword : capture==2 ? :variable : :string))
                end
            end
        end
    end
    nothing
end

function session_syntax_lines(text::String,styles::Vector{Tachikoma.Style};keep_trailing=false)
    rows=SessionDisplayRows()
    row=Tachikoma.Span[]
    characters=collect(text)
    start=1
    for index in eachindex(characters)
        if characters[index]=='\n'
            start<index&&push!(row,Tachikoma.Span(join(@view characters[start:index-1]),styles[start]))
            push!(rows,row);row=Tachikoma.Span[];start=index+1
        elseif index>start&&styles[index]!=styles[start]
            push!(row,Tachikoma.Span(join(@view characters[start:index-1]),styles[start]));start=index
        end
    end
    start<=length(characters)&&push!(row,Tachikoma.Span(join(@view characters[start:end]),styles[start]))
    push!(rows,row)
    if !keep_trailing
        while !isempty(rows)&&isempty(last(rows))
            pop!(rows)
        end
    end
    rows
end

"""Return logical highlighted source lines, including eager-to-full language availability transitions."""
function (renderer::SessionSyntaxRenderer)(path::AbstractString,raw::AbstractString)
    renderer.phase in (:eager,:full)||error("Unsupported syntax initialization phase")
    text=String(session_display_safe(raw))
    extension=lowercase(last(split(path,'.')))
    language=get(SESSION_SYNTAX_EXTENSIONS,extension,"")
    eager_fallback=renderer.phase==:eager&&language in ("markdown","yaml","html","sql")
    style=isempty(language) ? session_tool_style(:output) : eager_fallback ? session_display_style(:codeblock) : session_syntax_style(:default)
    styles=fill(style,length(text))
    if !isempty(language)&&!eager_fallback
        positions=session_syntax_positions(text)
        if language in ("markdown","html")
            session_syntax_markup!(styles,positions,text,language)
        else
            session_syntax_lex!(styles,positions,text,language)
            session_syntax_semantics!(styles,positions,text,language)
            language=="yaml"&&session_syntax_markup!(styles,positions,text,language)
        end
    end
    SessionSyntaxLines(session_syntax_lines(text,styles;keep_trailing=eager_fallback))
end
