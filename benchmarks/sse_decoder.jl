using JuliaForever2

function decode_events(wire::String)
    received = Ref(0)
    decoder = JuliaForever2.SSEDecoder(event -> (received[] += 1))
    write(decoder, wire)
    return received[]
end

function measure_sse(event_count::Int; repetitions=10)
    wire = repeat("id: 21\nevent: delta\ndata: {\"content\":\"λ:ok\"}\n\n", event_count)
    for _ in 1:3
        decode_events(wire)
    end
    observed = decode_events(wire)
    observed == event_count || error("SSE decoder emitted $observed events, expected $event_count")
    allocated_bytes = @allocated decode_events(wire)
    times = Float64[]
    for _ in 1:repetitions
        start = time_ns()
        decode_events(wire)
        push!(times, (time_ns() - start) / 1.0e6)
    end
    sort!(times)
    return (events=event_count, wire_bytes=ncodeunits(wire),
        allocated_bytes, median_ms=times[cld(length(times), 2)], repetitions)
end

println((julia=string(VERSION), threads=Threads.nthreads(:default)))
for count in (100, 1000, 10_000)
    println(measure_sse(count))
end
