using Test,Tachikoma,JuliaForever2,CommonMark
module ResourceRegistrationNativeTests
using Tachikoma,JuliaForever2,CommonMark
const Owner=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const StartupRichText=Owner.StartupRichText
const startup_rich! = Owner.startup_rich!
const startup_rich=Owner.startup_rich
const startup_text_lines=Owner.startup_text_lines
const theme_token_style=Owner.theme_token_style
include(joinpath(@__DIR__,"..","ext","terminal","startup_document.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","resource_registration.jl"))
include(joinpath(@__DIR__,"..","ext","terminal","startup_controls.jl"))
Base.@kwdef mutable struct Registry
    skills::Vector{Owner.RegisteredSkill} = Owner.RegisteredSkill[]
    prompts::Vector{Owner.RegisteredPrompt} = Owner.RegisteredPrompt[]
    resource_revisions::Dict{Tuple{Symbol,String},UInt} = Dict{Tuple{Symbol,String},UInt}()
end
end
@testset "Resource ownership respects every explicit registration" begin
    N=ResourceRegistrationNativeTests;T=N.Owner
    app=(menus=N.Registry(),)
    controls=N.StartupControls(;document=N.StartupDocument())
    skill=T.RegisteredSkill("owned","/real/owned.md","owned")
    prompt=T.RegisteredPrompt("owned","owned")
    push!(app.menus.skills,skill);push!(app.menus.prompts,prompt)
    @test N.resource_registered!(app,:skill,"owned")==1
    @test N.resource_registered!(app,:prompt,"owned")==1
    controls.disk_registrations[(:skill,"owned")]=(UInt(1),skill)
    controls.disk_registrations[(:prompt,"owned")]=(UInt(1),prompt)
    N.startup_remove_disk_registrations!(controls,app)
    @test isempty(app.menus.skills) && isempty(app.menus.prompts)
    @test isempty(controls.disk_registrations)
    push!(app.menus.skills,skill);push!(app.menus.prompts,prompt)
    controls.disk_registrations[(:skill,"owned")]=(UInt(1),skill)
    controls.disk_registrations[(:prompt,"owned")]=(UInt(1),prompt)
    @test N.resource_registered!(app,:skill,"owned")==2
    @test N.resource_registered!(app,:prompt,"owned")==2
    N.startup_remove_disk_registrations!(controls,app)
    @test only(app.menus.skills)===skill && only(app.menus.prompts)===prompt
    controls.disk_registrations[(:skill,"owned")]=(UInt(2),skill)
    controls.disk_registrations[(:prompt,"owned")]=(UInt(2),prompt)
    replacement=T.RegisteredSkill("owned","/explicit/replaced.md","owned")
    app.menus.skills[1]=replacement
    app.menus.prompts[1]=T.RegisteredPrompt("owned","direct replacement")
    N.startup_remove_disk_registrations!(controls,app)
    @test only(app.menus.skills)===replacement
    @test only(app.menus.prompts).description=="direct replacement"
    second=(menus=N.Registry(),)
    @test N.resource_registration_revision(second,:skill,"owned")==0
    @test N.resource_registered!(second,:skill,"owned")==1
    @test N.resource_registration_revision(app,:skill,"owned")==2
end

@testset "Startup advertises only confirmed host capabilities" begin
    N=ResourceRegistrationNativeTests
    doc=N.StartupDocument(;capabilities=Set(["commands","app.tools.expand"]),bindings=Dict("app.tools.expand"=>"ctrl+o"))
    text=join(span.content for line in N.startup_text_lines(N.startup_header(doc,nothing),100) for span in line)
    @test occursin("/ commands",text) && occursin("ctrl+o more",text)
    @test !occursin("! bash",text) && !occursin("clear/exit",text)
    doc.expanded=true
    text=join(span.content for line in N.startup_text_lines(N.startup_header(doc,nothing),100) for span in line)
    @test !occursin("run bash",text) && !occursin("drop files",text)
    @test !occursin("external editor",text) && !occursin("to suspend",text)
    @test occursin("ctrl+o to expand tools",text)
    doc.capabilities=Set(["commands"]);doc.expanded=false
    text=join(span.content for line in N.startup_text_lines(N.startup_header(doc,nothing),100) for span in line)
    @test !occursin("Press ",text) && occursin("/ commands",text)
end
