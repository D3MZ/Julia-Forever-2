# Native math formatting from pinned Pi latex.ts (MIT; licenses/pi-LICENSE).
session_math_script_value(value::AbstractString)=String(replace(strip(value),r"\s*([=+-])\s*"=>s"\1"))
function session_math_unicode_script(value::AbstractString,kind::Symbol)
    replacements=kind==:sub ? SESSION_MATH_SUBSCRIPTS : SESSION_MATH_SUPERSCRIPTS
    characters=string.(collect(session_math_script_value(value)))
    all(character->haskey(replacements,character),characters) ? join(replacements[character] for character in characters) : nothing
end
function session_math_script(value::AbstractString,kind::Symbol)
    normalized=session_math_script_value(value);unicode=session_math_unicode_script(normalized,kind)
    prefix=kind==:sub ? "_" : "^"
    isnothing(unicode) ? prefix*(length(normalized)==1||kind==:sub&&occursin(r"^[A-Za-z]+$",normalized) ? normalized : "("*normalized*")") : unicode
end
function session_math_fraction(numerator::AbstractString,denominator::AbstractString)
    top=String(strip(numerator));bottom=String(strip(denominator))
    (occursin(r"^[\p{L}\p{N}.]+$",top) ? top : "("*top*")")*"/"*(occursin(r"^[\p{N}.]+$",bottom)||length(bottom)==1 ? bottom : "("*bottom*")")
end
function session_math_root(value::AbstractString,symbol::String="√")
    text=String(strip(value))
    symbol*(occursin(r"^[\p{L}\p{N}.]+$",text) ? text : "("*text*")")
end
const SESSION_MATH_OPERATOR_LEFT_SPACING=Regex("(?<=[\\p{L}\\p{N})\\]}"*SESSION_MATH_MARKER_END*"])"*SESSION_MATH_OPERATOR_START)
const SESSION_MATH_OPERATOR_RIGHT_SPACING=Regex(SESSION_MATH_OPERATOR_END*"(?=[\\p{L}\\p{N}√"*SESSION_MATH_MARKER_START*"])")

function session_math_normalize(value::AbstractString)
    text=replace(String(value),SESSION_MATH_OPERATOR_LEFT_SPACING=>" ")
    text=replace(text,SESSION_MATH_OPERATOR_START=>"")
    text=replace(text,SESSION_MATH_OPERATOR_RIGHT_SPACING=>" ")
    text=replace(text,SESSION_MATH_OPERATOR_END=>"")
    lines=String[strip(replace(line,r"[ \t]+"=>" ")) for line in split(text,'\n';keepempty=true)]
    String(strip(join([line for (index,line) in enumerate(lines) if !isempty(line)||1<index<length(lines)],'\n')))
end
