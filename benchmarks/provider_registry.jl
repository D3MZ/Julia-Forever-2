using JuliaForever2

function copied_provider_lookup(registry, id)
    descriptors = JuliaForever2.provider_descriptors(registry)
    index = findfirst(descriptor -> descriptor.id == id, descriptors)
    return isnothing(index) ? nothing : descriptors[index]
end

function repeated_lookup(f, registry, id, repetitions)
    result = nothing
    for _ in 1:repetitions
        result = f(registry, id)
    end
    return result
end

function measure_lookup(f, registry, id; repetitions=100_000)
    repeated_lookup(f, registry, id, 100)
    GC.gc()
    allocated_bytes = @allocated repeated_lookup(f, registry, id, repetitions)
    started = time_ns()
    result = repeated_lookup(f, registry, id, repetitions)
    elapsed_nanoseconds = time_ns() - started
    return (id=result.id, bytes_per_lookup=allocated_bytes / repetitions,
        nanoseconds_per_lookup=elapsed_nanoseconds / repetitions)
end

println((julia=string(VERSION), threads=Threads.nthreads(:default)))
for descriptor_count in (4, 32, 256)
    registry = JuliaForever2.ProviderRegistry()
    for index in 1:descriptor_count
        id = Symbol("provider_", index)
        JuliaForever2.register_provider!(registry,
            JuliaForever2.ProviderDescriptor(id, string(id), identity))
    end
    name = Symbol("provider_", descriptor_count)
    snapshot_copy = measure_lookup(copied_provider_lookup, registry, name)
    direct_lookup = measure_lookup(JuliaForever2.provider_descriptor, registry, name)
    println((descriptor_count, snapshot_copy, direct_lookup))
end
