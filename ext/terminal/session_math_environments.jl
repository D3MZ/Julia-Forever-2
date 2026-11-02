# Native environments and matrix/cases layout from pinned Pi latex.ts (MIT).
const SESSION_MATH_ALIGNED=Set(["aligned","align","align*","alignedat","alignat","alignat*","gather","gathered","multline","multline*","split"])
const SESSION_MATH_MATRIX=Set(["array","matrix","smallmatrix","pmatrix","bmatrix","Bmatrix","vmatrix","Vmatrix"])
const SESSION_MATH_DELIMITERS=Dict("pmatrix"=>("⎛","⎞","⎜","⎟","⎝","⎠"),"bmatrix"=>("⎡","⎤","⎢","⎥","⎣","⎦"),"Bmatrix"=>("⎧","⎫","⎨","⎬","⎩","⎭"),"vmatrix"=>("│","│","│","│","│","│"),"Vmatrix"=>("║","║","║","║","║","║"))
session_math_environment_rows(body::AbstractString)=String.(split(body,r"\\\\(?:\[[^\]\n]*\])?";keepempty=true))
session_math_cell(row::Vector{String},column::Int)=get(row,column,"")

function session_math_environment!(parser::SessionMathParser)
    environment=session_math_raw_group!(parser)
    if isnothing(environment)||isempty(environment)
        ""
    else
        marker="\\end{"*environment*"}";remaining=session_math_slice(parser,parser.position);ending=findfirst(marker,remaining)
        if isnothing(ending)
            parser.supported=false;""
        else
            body=first(ending)==firstindex(remaining) ? "" : String(SubString(remaining,firstindex(remaining),prevind(remaining,first(ending))))
            parser.position+=length(body)+length(marker)
            session_math_environment_body!(parser,environment,body)
        end
    end
end

function session_math_environment_body!(parser::SessionMathParser,environment::String,body::String)
    if environment in ("equation","equation*","displaymath")
        String(strip(session_math_nested!(parser,body)))
    elseif environment in SESSION_MATH_ALIGNED
        paired=environment in ("alignedat","alignat","alignat*")
        content=paired ? replace(body,r"^\s*\{[^}]*\}"=>"") : body
        rendered=String[]
        for row in session_math_environment_rows(content)
            cells=split(row,'&';keepempty=true)
            source=paired ? join([join(cells[index:min(index+1,length(cells))]) for index in 1:2:length(cells)]," ") : join(cells)
            value=String(strip(session_math_nested!(parser,source)))
            !isempty(value)&&push!(rendered,value)
        end
        join(rendered,'\n')
    elseif environment in ("cases","cases*")
        session_math_cases!(parser,body)
    elseif environment in SESSION_MATH_MATRIX
        content=environment=="array" ? replace(body,r"^\s*\{[^}]*\}"=>"") : body
        session_math_matrix!(parser,environment,content)
    else
        parser.supported=false;body
    end
end

function session_math_cells!(parser::SessionMathParser,body::String)
    rows=Vector{String}[]
    for raw in session_math_environment_rows(body)
        row=String[strip(session_math_nested!(parser,cell,false)) for cell in split(raw,'&';keepempty=true)]
        any(!isempty,row)&&push!(rows,row)
    end
    rows
end

function session_math_cases!(parser::SessionMathParser,body::String)
    rows=session_math_cells!(parser,body)
    width=maximum((session_math_width(replace(session_math_cell(row,1),r",\s*$"=>"")) for row in rows);init=0)
    contents=String[]
    for row in rows
        value=replace(session_math_cell(row,1),r",\s*$"=>"");condition=session_math_cell(row,2)
        text=isempty(condition) ? value : value*repeat(SESSION_MATH_PROTECTED_SPACE,max(0,width-session_math_width(value)))*(occursin(r"^(?:if|when|for|otherwise)\b"i,condition) ? " " : " if ")*condition
        push!(contents,text)
    end
    if length(contents)<=1
        isempty(contents) ? "" : "⎧ "*only(contents)
    else
        middle=fld(length(contents),2);visual=Union{Nothing,String}[contents...]
        iseven(length(contents))&&insert!(visual,middle+1,nothing)
        lines=String[]
        for (index,content) in enumerate(visual)
            delimiter=index==1 ? "⎧" : index==length(visual) ? "⎩" : "⎨"
            push!(lines,isnothing(content) ? delimiter : delimiter*" "*content)
        end
        session_math_node!(parser,SessionMathMatrix(lines,middle))
    end
end

function session_math_matrix!(parser::SessionMathParser,environment::String,body::String)
    matrix=session_math_cells!(parser,body);columns=maximum(length,matrix;init=0)
    widths=[maximum((session_math_width(session_math_cell(row,column)) for row in matrix);init=0) for column in 1:columns]
    rows=String[join([session_math_cell(row,column)*repeat(SESSION_MATH_PROTECTED_SPACE,max(0,widths[column]-session_math_width(session_math_cell(row,column)))) for column in 1:columns]," │ ") for row in matrix]
    lines=if environment in ("array","matrix","smallmatrix")
        rows
    elseif haskey(SESSION_MATH_DELIMITERS,environment)
        delimiters=SESSION_MATH_DELIMITERS[environment]
        String[(index==1 ? delimiters[1] : index==length(rows) ? delimiters[5] : delimiters[3])*" "*row*" "*(index==1 ? delimiters[2] : index==length(rows) ? delimiters[6] : delimiters[4]) for (index,row) in enumerate(rows)]
    else
        parser.supported=false;rows
    end
    length(lines)<=1 ? (isempty(lines) ? "" : only(lines)) : session_math_node!(parser,SessionMathMatrix(lines,0))
end
