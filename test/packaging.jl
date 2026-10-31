@testset "Headless core loading" begin
    project = dirname(Base.active_project())
    source = "using JuliaForever2; print(any(package.name in (\"Tachikoma\", \"CommonMark\") for package in keys(Base.loaded_modules)))"
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $source`
    @test read(command, String) == "false"
end
