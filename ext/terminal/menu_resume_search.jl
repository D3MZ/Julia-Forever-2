# Native archive search. User regex compilation is a status-returning C boundary, not eval.
Base.@kwdef mutable struct ResumePattern
    code::Ptr{Cvoid}=C_NULL
    error::Union{Nothing,String}=nothing
end

function resume_pattern_close!(pattern::ResumePattern)
    if pattern.code!=C_NULL
        ccall((:pcre2_code_free_8,Base.PCRE.PCRE_LIB),Cvoid,(Ptr{Cvoid},),pattern.code)
        pattern.code=C_NULL
    end
    nothing
end

"""Compile bounded native regex syntax, reporting invalid patterns without exceptions."""
function resume_pattern(value::AbstractString)
    pattern=String(value)
    result=ResumePattern()
    if isempty(pattern)
        result.error="Empty regex"
    elseif ncodeunits(pattern)>8192
        result.error="Regex exceeds the native 8192-byte limit"
    else
        error=Ref{Cint}(0)
        offset=Ref{Csize_t}(0)
        options=UInt32(Base.PCRE.CASELESS|Base.PCRE.UTF|Base.PCRE.ALT_BSUX|Base.PCRE.MATCH_UNSET_BACKREF)
        result.code=ccall((:pcre2_compile_8,Base.PCRE.PCRE_LIB),Ptr{Cvoid},
            (Ptr{UInt8},Csize_t,UInt32,Ref{Cint},Ref{Csize_t},Ptr{Cvoid}),pattern,ncodeunits(pattern),options,error,offset,C_NULL)
        if result.code==C_NULL
            result.error="Invalid native regex (code $(error[]) at byte $(offset[]))"
        end
    end
    finalizer(resume_pattern_close!,result)
    result
end

"""Bound regex work and return a non-match for allocation, engine, or match-limit failures."""
function resume_pattern_match(pattern::ResumePattern,text::AbstractString)
    matched=false
    GC.@preserve pattern begin
      if pattern.code!=C_NULL
        data=ccall((:pcre2_match_data_create_from_pattern_8,Base.PCRE.PCRE_LIB),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid}),pattern.code,C_NULL)
        context=ccall((:pcre2_match_context_create_8,Base.PCRE.PCRE_LIB),Ptr{Cvoid},(Ptr{Cvoid},),C_NULL)
        if data!=C_NULL && context!=C_NULL
            ccall((:pcre2_set_match_limit_8,Base.PCRE.PCRE_LIB),Cint,(Ptr{Cvoid},UInt32),context,100_000)
            ccall((:pcre2_set_depth_limit_8,Base.PCRE.PCRE_LIB),Cint,(Ptr{Cvoid},UInt32),context,1000)
            value=String(text)
            status=ccall((:pcre2_match_8,Base.PCRE.PCRE_LIB),Cint,
                (Ptr{Cvoid},Ptr{UInt8},Csize_t,Csize_t,UInt32,Ptr{Cvoid},Ptr{Cvoid}),
                pattern.code,value,ncodeunits(value),0,0,data,context)
            matched=status>=0
        end
        if data!=C_NULL
            ccall((:pcre2_match_data_free_8,Base.PCRE.PCRE_LIB),Cvoid,(Ptr{Cvoid},),data)
        end
        if context!=C_NULL
            ccall((:pcre2_match_context_free_8,Base.PCRE.PCRE_LIB),Cvoid,(Ptr{Cvoid},),context)
        end
      end
    end
    matched
end

Base.@kwdef struct ResumeQuery
    tokens::Vector{Tuple{Symbol,String}}=Tuple{Symbol,String}[]
    pattern::Union{Nothing,ResumePattern}=nothing
end
resume_normalize(text::AbstractString)=String(strip(replace(lowercase(text),r"\s+"=>" ")))

"""Parse literal phrases and fuzzy tokens, retaining unmatched quotes as ordinary text."""
function resume_query(value::AbstractString)
    text=String(strip(value))
    tokens=Tuple{Symbol,String}[]
    pattern=nothing
    if startswith(text,"re:")
        pattern=resume_pattern(strip(chop(text;head=3,tail=0)))
    else
        buffer=IOBuffer()
        quoted=false
        for character in text
            if character=='"' || (!quoted && isspace(character))
                token=String(strip(String(take!(buffer))))
                isempty(token) || push!(tokens,(quoted ? :phrase : :fuzzy,token))
                if character=='"'
                    quoted=!quoted
                end
            else
                print(buffer,character)
            end
        end
        token=String(strip(String(take!(buffer))))
        isempty(token) || push!(tokens,(quoted ? :phrase : :fuzzy,token))
        if quoted
            tokens=[(:fuzzy,String(token)) for token in split(text) if !isempty(token)]
        end
    end
    ResumeQuery(;tokens,pattern)
end

function resume_token_score(entry,kind::Symbol,value::AbstractString)
    phrase=kind==:phrase
    query=phrase ? resume_normalize(value) : lowercase(value)
    name=phrase ? resume_normalize(something(entry.name,"")) : lowercase(something(entry.name,""))
    fields=(lowercase(entry.id),phrase ? resume_normalize(entry.text) : lowercase(entry.text),
        phrase ? resume_normalize(entry.cwd) : lowercase(entry.cwd))
    score=Inf
    if occursin(query,name)
        score=thinking_token_score(name,query)
    elseif any(field->occursin(query,field),fields)
        score=1_000_000.0
    elseif !phrase
        score=2_000_000+min(thinking_token_score(something(entry.name,""),value),thinking_token_score(entry.cwd,value))
    end
    score
end

function resume_match(entry,query::ResumeQuery)
    score=0.0
    if isnothing(query.pattern)
        for (kind,value) in query.tokens
            score+=resume_token_score(entry,kind,value)
        end
    elseif !isnothing(entry.name) && resume_pattern_match(query.pattern,entry.name)
        score=0.0
    elseif any(value->resume_pattern_match(query.pattern,value),(entry.id,entry.text,entry.cwd))
        score=1_000_000.0
    else
        score=Inf
    end
    (matches=isfinite(score),score=isfinite(score) ? score : 0.0)
end

"""Preserve service order for recent and empty-query modes; rank other filtered views stably."""
function resume_search(entries::AbstractVector,query::AbstractString,sort::Symbol=:threaded,names::Symbol=:all)
    candidates=[entry for entry in entries if names==:all || !isempty(strip(something(entry.name,"")))]
    if !isempty(strip(query))
        parsed=resume_query(query)
        ranked=[(entry,resume_match(entry,parsed)) for entry in candidates]
        filter!(pair->last(pair).matches,ranked)
        if sort!=:recent
            sort!(ranked;by=pair->(last(pair).score,-first(pair).modified),alg=Base.Sort.MergeSort)
        end
        candidates=first.(ranked)
        isnothing(parsed.pattern) || resume_pattern_close!(parsed.pattern)
    end
    candidates
end
