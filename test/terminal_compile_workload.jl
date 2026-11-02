using Test,JuliaForever2,Tachikoma,CommonMark
const TCW=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
isdefined(TCW,:terminal_compile_workload)||Base.include(TCW,joinpath(@__DIR__,"../ext/terminal/compile_workload.jl"))
@testset "Native precompile fixture cannot start external work" begin
    theme=TCW.ACTIVE_NATIVE_THEME[]
    fixture=TCW.terminal_compile_fixture()
    @test isempty(fixture.settings.providers)
    @test isnothing(fixture.settings.auth_flow)
    @test isnothing(fixture.settings.auth_task)
    @test isempty(fixture.operations.watchers)
    @test isempty(fixture.session.runtime.handles)
    @test isnothing(fixture.archive.timeline.path)
    @test isnothing(fixture.archive.timeline.disk_digest)
    @test fixture.session.runtime.executor.scope===TCW
    @test length(JuliaForever2.timeline_entries(fixture.archive.timeline))==2
    close(fixture.queue.channel)
    close(fixture.session.kernel)
    @test TCW.terminal_compile_workload()>0
    @test TCW.ACTIVE_NATIVE_THEME[]===theme
end
