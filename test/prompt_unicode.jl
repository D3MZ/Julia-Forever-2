module PromptUnicodeTests
using Test,JSON,JuliaForever2
const JF=JuliaForever2
@testset "Original UTF16 description boundary and valid terminal display" begin
 oracle=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi-prompt-unicode.json"))
 for item in oracle["rows"]
  parsed=JF.prompt_template_from_text(item["name"],item["raw"])
  @test Int.(transcode(UInt16,parsed.description))==item["metadataUnits"]
  visible=JF.prompt_menu_description(parsed.description,parsed.argument_hint)
  @test visible==item["visibleDescription"]
  @test isvalid(visible)
 end
end
end
