const NATIVE_BINDING_SYMBOLS=Set(collect("`-=\\[];',./!@#\$%^&*()_+|~{}:<>?"))
const NATIVE_BINDING_SHIFTED_SYMBOLS=Set(collect("~!@#\$%^&*()_+|{}:<>?"))
const NATIVE_BINDING_SPECIAL=Set(vcat(["escape","esc","enter","return","tab","space","backspace","delete","insert","clear","home","end","pageUp","pageDown","up","down","left","right"],["f"*string(i) for i in 1:12]))
const NATIVE_BINDING_MODIFIERS=("shift"=>1,"alt"=>2,"ctrl"=>4,"super"=>8)
const NATIVE_BINDING_CODES=Dict("escape"=>27,"esc"=>27,"tab"=>9,"enter"=>13,"return"=>13,"space"=>32,"backspace"=>127,
    "up"=>-1,"down"=>-2,"right"=>-3,"left"=>-4,"delete"=>-10,"insert"=>-11,"pageup"=>-12,"pagedown"=>-13,"home"=>-14,"end"=>-15,
    ("f"*string(i)=>-20-i for i in 1:12)...)
const NATIVE_BINDING_TILDE=Dict(2=>-11,3=>-10,5=>-12,6=>-13,7=>-14,8=>-15,11=>-21,12=>-22,13=>-23,14=>-24,15=>-25,17=>-26,18=>-27,19=>-28,20=>-29,21=>-30,23=>-31,24=>-32)
const NATIVE_BINDING_KEYPAD=Dict(57409=>46,57410=>47,57411=>42,57412=>45,57413=>43,57415=>61,57416=>44,57417=>-4,57418=>-3,57419=>-1,57420=>-2,57421=>-12,57422=>-13,57423=>-14,57424=>-15,57425=>-11,57426=>-10)
const NATIVE_BINDING_LEGACY=Dict(
    "up"=>["\e[A","\eOA"],"down"=>["\e[B","\eOB"],"right"=>["\e[C","\eOC"],"left"=>["\e[D","\eOD"],
    "home"=>["\e[H","\eOH","\e[1~","\e[7~"],"end"=>["\e[F","\eOF","\e[4~","\e[8~"],"insert"=>["\e[2~"],"delete"=>["\e[3~"],
    "pageup"=>["\e[5~","\e[[5~"],"pagedown"=>["\e[6~","\e[[6~"],"clear"=>["\e[E","\eOE"],
    "f1"=>["\eOP","\e[11~","\e[[A"],"f2"=>["\eOQ","\e[12~","\e[[B"],"f3"=>["\eOR","\e[13~","\e[[C"],"f4"=>["\eOS","\e[14~","\e[[D"],"f5"=>["\e[15~","\e[[E"],
    "f6"=>["\e[17~"],"f7"=>["\e[18~"],"f8"=>["\e[19~"],"f9"=>["\e[20~"],"f10"=>["\e[21~"],"f11"=>["\e[23~"],"f12"=>["\e[24~"])

"""Validate only data-defined key IDs, retaining original strings for conflict diagnostics."""
function native_key_id(value::AbstractString)
    rest=String(value);modifier=0;valid=ncodeunits(rest)<=80
    while valid
        selected=findfirst(pair->startswith(rest,first(pair)*"+"),NATIVE_BINDING_MODIFIERS)
        isnothing(selected) && break
        name,bit=NATIVE_BINDING_MODIFIERS[selected]
        valid=(modifier&bit)==0
        modifier|=bit
        rest=String(SubString(rest,ncodeunits(name)+2))
    end
    keyvalid=rest in NATIVE_BINDING_SPECIAL || length(rest)==1 && (first(rest) in 'a':'z' || first(rest) in '0':'9' || first(rest) in NATIVE_BINDING_SYMBOLS)
    valid && keyvalid ? (key=lowercase(rest),modifier) : nothing
end
native_binding_number(::Nothing,fallback::Int=0)=fallback
native_binding_number(value::AbstractString,fallback::Int=0)=isempty(value) ? fallback : something(tryparse(Int,value),-10_000_000)
native_binding_normalize(code::Int)=57399<=code<=57408 ? code-57351 : get(NATIVE_BINDING_KEYPAD,code,code)
native_binding_letter(code::Int,modifier::Int)=(modifier&1)!=0 && 65<=code<=90 ? code+32 : code
native_binding_code(key::String)=get(NATIVE_BINDING_CODES,key,length(key)==1 ? Int(first(key)) : 0)

"""Parse one terminal key without interpreting pasted bytes or accepting released keys as actions."""
function native_binding_sequence_unchecked(packet::AbstractString)
    ncodeunits(packet)>128 && return nothing
    kitty=match(r"^\e\[(\d+)(?::(\d*))?(?::(\d+))?(?:;(\d+))?(?::(\d+))?u$",packet)
    if !isnothing(kitty)
        (code=native_binding_number(kitty.captures[1]),modifier=native_binding_number(kitty.captures[4],1)-1,
            shifted=native_binding_number(kitty.captures[2],-1),base=native_binding_number(kitty.captures[3],-1),release=kitty.captures[5]=="3",event=native_binding_number(kitty.captures[5],1),kind=:kitty)
    else
        arrow=match(r"^\e\[1;(\d+)(?::(\d+))?([ABCDHF])$",packet)
        tilde=match(r"^\e\[(\d+)(?:;(\d+))?(?::(\d+))?~$",packet)
        functionkey=match(r"^\e\[(?:1;(\d+)(?::(\d+))?)?([PQS])$",packet)
        other=match(r"^\e\[27;(\d+);(\d+)~$",packet)
        if !isnothing(other)
            (code=native_binding_number(other.captures[2]),modifier=native_binding_number(other.captures[1],1)-1,shifted=-1,base=-1,release=false,event=1,kind=:other)
        elseif !isnothing(arrow)
            (code=get(Dict("A"=>-1,"B"=>-2,"C"=>-3,"D"=>-4,"H"=>-14,"F"=>-15),arrow.captures[3],0),modifier=native_binding_number(arrow.captures[1],1)-1,shifted=-1,base=-1,release=arrow.captures[2]=="3",event=native_binding_number(arrow.captures[2],1),kind=:kitty)
        elseif !isnothing(tilde) && haskey(NATIVE_BINDING_TILDE,native_binding_number(tilde.captures[1]))
            (code=NATIVE_BINDING_TILDE[native_binding_number(tilde.captures[1])],modifier=native_binding_number(tilde.captures[2],1)-1,shifted=-1,base=-1,release=tilde.captures[3]=="3",event=native_binding_number(tilde.captures[3],1),kind=:kitty)
        elseif !isnothing(functionkey)
            (code=functionkey.captures[3]=="P" ? -21 : functionkey.captures[3]=="Q" ? -22 : -24,modifier=native_binding_number(functionkey.captures[1],1)-1,shifted=-1,base=-1,release=functionkey.captures[2]=="3",event=native_binding_number(functionkey.captures[2],1),kind=:kitty)
        else
            nothing
        end
    end
end

"""Reject malformed supplied integers rather than interpreting them as omitted defaults."""
function native_binding_sequence(packet::AbstractString)
    sequence=native_binding_sequence_unchecked(packet)
    scalar(value)=value==-1 || 0<=value<=0x10ffff && isvalid(Char,value)
    valid=!isnothing(sequence) && -32<=sequence.code<=0x10ffff && (sequence.code<0 || isvalid(Char,sequence.code)) &&
        0<=sequence.modifier<=255 && scalar(sequence.shifted) && scalar(sequence.base) && sequence.event in (1,2,3)
    valid ? sequence : nothing
end

"""Preserve physical identity, reported shifted symbols and non-Latin base-layout fallback."""
function native_binding_sequence_matches(sequence,expected::Int,modifier::Int)
    if isnothing(sequence) || sequence.release || sequence.modifier<0
        false
    else
        actual=sequence.kind==:kitty ? sequence.modifier&~192 : sequence.modifier
        code=native_binding_letter(native_binding_normalize(sequence.code),actual)
        expected=native_binding_letter(native_binding_normalize(expected),modifier)
        physical=actual==modifier && code==expected
        shifted=native_binding_normalize(sequence.kind==:other ? sequence.code : sequence.shifted)
        symbol=0<=shifted<=0x10ffff && isvalid(Char,shifted) && Char(shifted) in (sequence.kind==:other ? NATIVE_BINDING_SHIFTED_SYMBOLS : NATIVE_BINDING_SYMBOLS)
        logical=(actual&1)!=0 && symbol && (actual&~1)==modifier && shifted==expected
        known=97<=code<=122 || 0<=code<=0x10ffff && isvalid(Char,code) && Char(code) in NATIVE_BINDING_SYMBOLS
        fallback=sequence.kind==:kitty && sequence.base>=0 && actual==modifier && sequence.base==expected && !known
        physical || logical || fallback
    end
end

native_binding_windows_terminal()=!isempty(get(ENV,"WT_SESSION","")) && all(name->isempty(get(ENV,name,"")),("SSH_CONNECTION","SSH_CLIENT","SSH_TTY"))
"""Match pinned native key semantics without invoking an action or reading clipboard/provider state."""
function native_binding_matches(packet::AbstractString,id::AbstractString;kitty::Bool=false,windows_terminal::Bool=native_binding_windows_terminal())
    keyid=native_key_id(id)
    if isnothing(keyid) || ncodeunits(packet)>128 || occursin("\e[200~",packet)
        false
    else
        key,modifier=keyid.key,keyid.modifier
        sequence=native_binding_sequence(packet)
        !isnothing(sequence) && sequence.release && return false
        code=native_binding_code(key)
        structured=code!=0 && native_binding_sequence_matches(sequence,code,modifier) && !(modifier==0 && key in ("tab","enter","return") && !isnothing(sequence) && sequence.kind==:other)
        if key in ("escape","esc")
            modifier==0 && (packet=="\e" || structured)
        elseif key in ("enter","return")
            extra=native_binding_sequence_matches(sequence,57414,modifier)
            raw=modifier==0 && (packet=="\r" || !kitty && packet=="\n" || packet=="\eOM") || modifier==1 && kitty && packet in ("\e\r","\n") || modifier==2 && !kitty && packet=="\e\r"
            structured || extra || raw
        elseif key=="tab"
            structured || modifier==0 && packet=="\t" || modifier==1 && packet=="\e[Z"
        elseif key=="space"
            structured || modifier==0 && packet==" " || !kitty && (modifier==4 && packet=="\0" || modifier==2 && packet=="\e ")
        elseif key=="backspace"
            raw=modifier==0 && packet=="\x7f" || packet=="\x08" && modifier==(windows_terminal ? 4 : 0) || modifier==2 && packet in ("\e\x7f","\e\x08")
            structured || raw
        elseif haskey(NATIVE_BINDING_LEGACY,key)
            raw=modifier==0 && packet in NATIVE_BINDING_LEGACY[key]
            if key in ("up","down","right","left","clear")
                letter=get(Dict("up"=>"a","down"=>"b","right"=>"c","left"=>"d","clear"=>"e"),key,"")
                raw |= modifier==1 && packet=="\e["*letter || modifier==4 && packet=="\eO"*letter
            elseif key in ("insert","delete","pageup","pagedown","home","end")
                number=get(Dict("insert"=>2,"delete"=>3,"pageup"=>5,"pagedown"=>6,"home"=>7,"end"=>8),key,0)
                raw |= modifier==1 && packet=="\e["*string(number)*"\$" || modifier==4 && packet=="\e["*string(number)*"^"
            end
            if modifier==2
                raw |= key=="up" && packet=="\ep" || key=="down" && packet=="\en" || key=="left" && (packet in ("\eb","\e[1;3D") || !kitty && packet=="\eB") || key=="right" && (packet in ("\ef","\e[1;3C") || !kitty && packet=="\eF")
            end
            structured || raw
        elseif length(key)==1
            char=first(key);letter='a'<=char<='z'
            control=letter || char in "[\\]_" ? string(Char(Int(char)&31)) : char=='-' ? "\x1f" : ""
            raw=modifier==0 && packet==key || modifier==1 && letter && packet==uppercase(key) || modifier==4 && !isempty(control) && packet==control || !kitty && modifier==6 && !isempty(control) && packet=="\e"*control || !kitty && modifier==2 && packet=="\e"*key
            structured || raw
        else
            false
        end
    end
end

function native_keybinding_matches(state::NativeKeybindings,action::AbstractString,packet::AbstractString;kwargs...)
    any(key->native_binding_matches(packet,key;kwargs...),get(state.effective,String(action),String[]))
end
