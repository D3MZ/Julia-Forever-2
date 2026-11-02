module PromptStringBoundaryTests
using Test,JuliaForever2
const J=JuliaForever2
using Base: AnnotatedString
struct ContractString <: AbstractString
    text::String
end
Base.String(value::ContractString)=value.text
Base.ncodeunits(value::ContractString)=ncodeunits(value.text)
Base.codeunit(::Type{ContractString})=UInt8
Base.codeunit(value::ContractString,index::Integer)=codeunit(value.text,index)
Base.isvalid(value::ContractString,index::Integer)=isvalid(value.text,index)
Base.iterate(value::ContractString)=iterate(value.text)
Base.iterate(value::ContractString,index::Integer)=iterate(value.text,index)
Base.length(value::ContractString)=length(value.text)
Base.getindex(value::ContractString,index::Int)=value.text[index]
Base.thisind(value::ContractString,index::Int)=thisind(value.text,index)
Base.nextind(value::ContractString,index::Int)=nextind(value.text,index)
Base.prevind(value::ContractString,index::Int)=prevind(value.text,index)
wraps=[identity,text->SubString("X"*text,2),text->AnnotatedString(text,[(1:ncodeunits(text),:fixture,true)]),ContractString]
@testset "Prompt boundaries consume textual strings, not styled characters or arrays" begin
 for wrap in wraps
  @test J.prompt_parse_args(wrap("α 'two words' \"\" 🙂"))==["α","two words","","🙂"]
  @test J.prompt_strip(wrap(" \t🙂 \u3000"))=="🙂"
  @test J.prompt_command_parts(wrap("/example  α 🙂"))==(name="example",arguments="α 🙂")
  @test J.prompt_command_parts(wrap("/example"))==(name="example",arguments="")
  @test J.prompt_command_parts(wrap("plain"))===nothing
  args=AbstractString[wrap("α"),wrap("two words"),wrap("🙂")]
  output=J.prompt_substitute_args(wrap(raw"$1|$@|${@:2:2}|${4:-$1}"),args)
  @test output=="α|α two words 🙂|two words 🙂|\$1"
  @test output isa String
  @test J.prompt_description(wrap("\n\t\n actual description\nnext"))==" actual description"
  parsed=J.prompt_parse_frontmatter(wrap("---\ndescription: Unicode 🙂\n---\n  Body \$x\n"))
  @test parsed.metadata["description"]=="Unicode 🙂"
  @test parsed.body=="Body \$x"
  @test J.prompt_display_text(wrap("visual 🙂")) isa String
 end
 @test_throws Exception J.prompt_substitute_args(AnnotatedString(raw"$@ $@"),[AnnotatedString("1234")];max_bytes=7)
end
end
