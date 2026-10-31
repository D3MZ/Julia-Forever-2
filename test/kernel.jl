using JuliaForever2: Kernel, ComponentSpec, install!, acquire!, release!, remove!, component

@testset "Component lifecycle" begin
    kernel = Kernel()
    disposed = String[]
    first = ComponentSpec(:provider, "old"; cleanup=x -> push!(disposed, x))
    second = ComponentSpec(:provider, "new"; cleanup=x -> push!(disposed, x))
    @test install!(kernel, first).ok
    lease = acquire!(kernel, :provider)
    @test lease.value == "old"
    @test install!(kernel, second).ok
    @test component(kernel, :provider) == "new"
    @test isempty(disposed)
    release!(lease)
    @test disposed == ["old"]
    release!(lease)
    @test disposed == ["old"]
    @test remove!(kernel, :provider).ok
    @test disposed == ["old", "new"]
end

@testset "Component dependencies" begin
    kernel = Kernel()
    consumer = ComponentSpec(:agent, 2; requires=[:provider])
    @test !install!(kernel, consumer).ok
    @test install!(kernel, ComponentSpec(:provider, 1)).ok
    @test install!(kernel, consumer).ok
    @test !remove!(kernel, :provider).ok
    @test component(kernel, :provider) == 1
    @test remove!(kernel, :agent).ok
    @test remove!(kernel, :provider).ok
end
