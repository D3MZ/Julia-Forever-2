using JuliaForever2: Kernel, ComponentSpec, install!, acquire!, release!, remove!, component, with_component, wrap_component!

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

@testset "Dependency generations survive retired consumers" begin
    kernel = Kernel()
    disposed = Symbol[]
    resource = Ref(false)
    install!(kernel, ComponentSpec(:resource, resource; cleanup=value -> (value[] = true; push!(disposed, :resource))))
    install!(kernel, ComponentSpec(:consumer, () -> resource[]; requires=[:resource], cleanup=value -> push!(disposed, :consumer)))
    lease = acquire!(kernel, :consumer)
    @test remove!(kernel, :consumer).ok
    @test remove!(kernel, :resource).ok
    @test !lease.value()
    @test isempty(disposed)
    release!(lease)
    @test disposed == [:consumer, :resource]
end

@testset "Installed consumers retain their dependency generation" begin
    kernel = Kernel()
    old = Ref(false)
    new = Ref(false)
    install!(kernel, ComponentSpec(:resource, old; cleanup=value -> (value[] = true)))
    install!(kernel, ComponentSpec(:consumer, () -> old[]; requires=[:resource]))
    @test install!(kernel, ComponentSpec(:resource, new; cleanup=value -> (value[] = true))).ok
    @test !component(kernel, :consumer)()
    @test remove!(kernel, :consumer).ok
    @test old[]
    @test !new[]
    close(kernel)
    @test new[]
    @test !isopen(kernel)
    @test !install!(kernel, ComponentSpec(:late, 1)).ok
end

@testset "Scoped resources and composable wrappers" begin
    kernel = Kernel()
    resource = Ref(false)
    install!(kernel, ComponentSpec(:resource, resource; cleanup=value -> (value[] = true)))
    observed = with_component(kernel, :resource) do value
        install!(kernel, ComponentSpec(:resource, Ref(false)))
        !value[]
    end
    @test observed
    @test resource[]
    disposed = Symbol[]
    install!(kernel, ComponentSpec(:calculate, x -> x + 1; cleanup=value -> push!(disposed, :inner)))
    @test wrap_component!(inner -> x -> 2 * inner(x), kernel, :calculate).ok
    @test wrap_component!(inner -> x -> inner(x) + 3, kernel, :calculate).ok
    @test with_component(value -> value(4), kernel, :calculate) == 13
    @test isempty(disposed)
    close(kernel)
    @test disposed == [:inner]
    close(kernel)
    @test disposed == [:inner]
end

@testset "Shutdown retains leased dependency chains" begin
    kernel = Kernel()
    disposed = Symbol[]
    install!(kernel, ComponentSpec(:resource, 1; cleanup=value -> push!(disposed, :resource)))
    install!(kernel, ComponentSpec(:consumer, 2; requires=[:resource], cleanup=value -> push!(disposed, :consumer)))
    lease = acquire!(kernel, :consumer)
    close(kernel)
    @test isempty(disposed)
    release!(lease)
    @test disposed == [:consumer, :resource]
end

@testset "Concurrent wrappers cannot silently overwrite one another" begin
    kernel = Kernel()
    disposed = Symbol[]
    install!(kernel, ComponentSpec(:calculate, x -> 2 * x; cleanup=value -> push!(disposed, :inner)))
    ready = Channel{Nothing}(2)
    finish = Channel{Nothing}(2)
    wrap = increment -> wrap_component!(kernel, :calculate) do inner
        put!(ready, nothing)
        take!(finish)
        x -> inner(x) + increment
    end
    first = Threads.@spawn wrap(1)
    second = Threads.@spawn wrap(10)
    take!(ready)
    take!(ready)
    put!(finish, nothing)
    put!(finish, nothing)
    results = [fetch(first), fetch(second)]
    @test count(result -> result.ok, results) == 1
    @test only(filter(result -> !result.ok, results)).reason == "Component changed during composition"
    @test with_component(value -> value(3), kernel, :calculate) in (7, 16)
    @test isempty(disposed)
    close(kernel)
    @test disposed == [:inner]
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
