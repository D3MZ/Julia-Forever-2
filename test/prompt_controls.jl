module PromptControlsTests
using JSON,Test,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
fixture=joinpath(@__DIR__,"../parity/fixtures/pi-prompt-controls.json")
oracle=JSON.parsefile(fixture)
reference=get(ENV,"PI_REFERENCE","")
if !isempty(reference)
    mktempdir() do directory
        output=joinpath(directory,"fresh.json")
        cases=joinpath(@__DIR__,"../parity/fixtures/pi-prompt-controls-cases.json")
        script=joinpath(@__DIR__,"../parity/pi_prompt_controls_oracle.mjs")
        run(addenv(`node $script $cases $output`,"PI_SOURCE_ROOT"=>reference))
        @test JSON.parsefile(output)==oracle
    end
end
@test oracle["pin"]=="2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
@testset "Original autocomplete argument hints" begin
 for record in oracle["menuHints"]
  item=record["item"]
  @test T.prompt_menu_description(item["description"],get(item,"argumentHint",nothing))==record["description"]
 end
end
@testset "Original argument parser" begin
 for item in oracle["args"]
  @test T.prompt_parse_args(item["input"])==item["output"]
 end
end
@testset "Original nonrecursive substitutions" begin
 for item in oracle["substitutions"]
  @test T.prompt_substitute_args(item["template"],String[item["args"]...])==item["output"]
 end
 templates=[T.PromptTemplateData(name="demo",content="Hello \$1 \${2:-default}")]
 for item in oracle["commands"]
  @test T.prompt_expand_template(item["input"],templates)==item["output"]
 end
end
@testset "Original registered template frontmatter" begin
 for item in oracle["frontmatter"]
  @testset "$(item["name"])" begin
   if isempty(item["loaded"])
    @test_throws Exception T.prompt_template_from_text(item["name"],item["raw"])
   else
    expected=only(item["loaded"]);actual=T.prompt_template_from_text(item["name"],item["raw"])
    @test actual.name==expected["name"]
    @test actual.content==expected["content"]
    @test actual.description==expected["description"]
    @test actual.argument_hint==expected["argumentHint"]
   end
  end
 end
end
@testset "Original skill command bodies and arguments" begin
 mktempdir() do directory
  path=joinpath(directory,"SKILL.md");write(path,"---\nname: fixture\ndescription: demo\n---\n  Use relative references.\n")
  skills=[(name="fixture",path=path)]
  for item in oracle["skills"]
   @test replace(T.skill_expand_command(item["input"],skills),directory=>"ROOT")==item["output"]
  end
  rm(path)
  @test_throws Exception T.skill_expand_command("/skill:fixture x",skills)
 end
end
@testset "Resource limits, inert tags, and rejected input" begin
 @test T.prompt_parse_args("a\u0085b")==["a\u0085b"]
 @test T.prompt_substitute_args(raw"$1 ${2:-$1}",[raw"$2"] )==raw"$2 $1"
 @test_throws Exception T.prompt_parse_args(repeat("x",T.PROMPT_RESOURCE_LIMIT+1))
 @test_throws Exception T.prompt_substitute_args(raw"$@ $@",[repeat("x",16)];max_bytes=20)
 @test_throws Exception T.prompt_parse_frontmatter("---\na: &a [*a]\n---\nbody")
 @test_throws Exception T.prompt_parse_frontmatter("---\ndescription: "*repeat("[",65)*repeat("]",65)*"\n---\nbody")
 @test_throws Exception T.prompt_read_file("relative.md")
 @test_throws Exception T.prompt_read_file("/tmp/"*repeat("x",T.PROMPT_PATH_LIMIT))
 @test_throws Exception T.prompt_read_file("/tmp/invalid\0name")
 metadata=T.prompt_parse_frontmatter("---\ndescription: !include /private/missing\n---\nno execution")
 @test metadata.metadata["description"]=="/private/missing"
 failed=T.prompt_expansion_result("/missing") do
  error("resource is missing")
 end
 @test !failed.ok
 @test failed.text=="/missing"
 @test occursin("resource is missing",failed.reason)
 app=(menus=(prompts=[(name="metadata-only",description="metadata")],skills=Any[]),)
 rejected=T.expand_registered_resources(app,"/metadata-only hi")
 @test !rejected.ok
 @test occursin("content unavailable",rejected.reason)
 @test T.expand_registered_resources(app,"/unknown hi").text=="/unknown hi"
end

end
