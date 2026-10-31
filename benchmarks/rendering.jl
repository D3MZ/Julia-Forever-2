using JuliaForever2
using JuliaForever2: append_message!, default_kernel
using Tachikoma
using CommonMark

const Terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)

function measured_render(render::F, prepare::P; repetitions=10) where {F,P}
    for _ in 1:2
        prepare()
        render()
    end
    prepare()
    allocated_bytes = @allocated render()
    durations = Float64[]
    for _ in 1:repetitions
        prepare()
        started = time_ns()
        render()
        push!(durations, (time_ns() - started) / 1.0e6)
    end
    sort!(durations)
    return (; allocated_bytes, minimum_ms=first(durations), median_ms=durations[cld(length(durations), 2)], repetitions)
end

function rendering_benchmarks(directory)
    println((; julia=string(VERSION), threads=Threads.nthreads(:default), viewport=(80, 24)))
    for message_count in (20, 200, 2000)
        application = Terminal.App(default_kernel(); settings_dir=directory)
        for index in 1:message_count
            message = isodd(index) ? Message(:user, "Prompt number $(index): explain this code.") : Message(:assistant, "Answer $(index) with **bold** text and `code`.\n\nA second paragraph provides a deterministic rendering workload.")
            append_message!(application.session, message)
        end
        backend = TestBackend(80, 24)
        frame = Tachikoma.Frame(backend.buf, backend.buf.area, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
        render = () -> Tachikoma.view(application, frame)
        cache_hit = measured_render(render, Returns(nothing); repetitions=20)
        full_rebuild = measured_render(render, () -> (application.transcript_width = 0); repetitions=5)
        append_one = measured_render(render, () -> append_message!(application.session, Message(:assistant, "One additional **formatted** response.")); repetitions=10)
        println((; message_count, cache_hit, full_rebuild, append_one))
        close(application.session)
    end
end

mktempdir() do directory
    withenv("JULIAFOREVER_CONFIG_DIR" => directory, "OPENROUTER_API_KEY" => "") do
        rendering_benchmarks(directory)
    end
end
