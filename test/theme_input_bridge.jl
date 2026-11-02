using Test,JSON,Tachikoma,SHA
module ThemeInputTests
using Test,JSON,Tachikoma,SHA
for file in ("theme_colors.jl","theme_system.jl","theme_runtime.jl","theme_terminal_query.jl","theme_file_watch.jl","theme_lifecycle.jl","theme_input_bridge.jl")
    include(joinpath(@__DIR__,"..","ext","terminal",file))
end
const TACHIKOMA_SOURCE_HASHES=Dict("events.jl"=>"56d4b899e9d047e977de2a20a906cbe7142f5ac5ea05fea59c08abaac896c643",
    "app.jl"=>"2d310d8f91a898ad73a0fa3a9ccbca490b2e94e8887445e9799be0bf56fde5d1",
    "terminal.jl"=>"df19a8fc51e06258ebdd2f09550e4550a76e0d48f78c8615e0f22bf69b55646d")
function life()
    value=ThemeLifecycle(;runtime=ThemeRuntime(theme_catalog(;preserve_extras=false)),output=IOBuffer())
    theme_lifecycle_start!(value)
end
function gather(input,pass,reports)
    changed=true
    while changed
        changed=false
        bytes=readavailable(input)
        if !isempty(bytes)
            append!(pass,bytes);changed=true
        end
        if !isempty(input.reports)
            push!(reports,popfirst!(input.reports));changed=true
        end
    end
    nothing
end
function event_record(event)
    event isa Tachikoma.MouseEvent ? (kind="mouse",x=event.x,y=event.y,button=string(event.button),action=string(event.action)) :
        (kind="key",key=String(event.key),char=string(event.char))
end
@testset "Exact installed Tachikoma 2.8 input/startup source pin" begin
    @test pkgversion(Tachikoma)==v"2.8.0"
    for (name,hash) in TACHIKOMA_SOURCE_HASHES
        @test bytes2hex(sha256(read(joinpath(dirname(pathof(Tachikoma)),name))))==hash
    end
end
@testset "Original StdinBuffer fragmented control, cancellation and paste boundaries" begin
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    evidence=get(ENV,"THEME_INPUT_EVIDENCE",mktempdir());mkpath(evidence)
    output=joinpath(evidence,"original-fresh.json");oracle=joinpath(@__DIR__,"differential","pi_theme_input_oracle.mjs")
    run(`node $oracle $reference $output`)
    original=JSON.parsefile(output)
    for case in original["cases"]
        lifecycle=life();now=Ref(0.0)
        input=ThemeTerminalInput(;source=IOBuffer(),lifecycle,clock=()->now[])
        pass=UInt8[];reports=String[]
        for expected in case["snapshots"]
            step=expected["step"]
            if haskey(step,"data")
                theme_input_feed!(input,codeunits(step["data"]))
            else
                now[] += step["advance"]/1000
            end
            gather(input,pass,reports)
            @test String(copy(pass))==expected["passthrough"]
            @test reports==expected["reports"]
        end
        close(input);theme_lifecycle_close!(lifecycle)
    end
end
@testset "Single real pipe reader preserves keys and mouse while isolating color replies" begin
    pipe=Pipe();Base.link_pipe!(pipe;reader_supports_async=true,writer_supports_async=true);Base.start_reading(pipe.out)
    lifecycle=life();input=ThemeTerminalInput(;source=pipe.out,lifecycle)
    previous=Tachikoma.INPUT_IO[];active=Tachikoma.INPUT_ACTIVE[];capture=Tachikoma.raw_capture_enabled()
    Tachikoma.INPUT_IO[]=input;Tachikoma.INPUT_ACTIVE[]=true;Tachikoma.enable_raw_capture!()
    fragments=["a","\e]11;rgb:","1111/","2222/3333\e","\\","\e[?1;2c","\e[<0;","12;8M","\e[A","z"]
    writer=@async for chunk in fragments
        write(pipe.in,chunk);flush(pipe.in);sleep(0.004)
    end
    events=Any[];raw=String[]
    result=timedwait(3;pollint=0.002) do
        while bytesavailable(input)>0
            push!(events,event_record(Tachikoma.read_event()))
            push!(raw,String(copy(Tachikoma.last_event_raw())))
        end
        theme_input_poll!(input)
        length(events)>=4 && lifecycle.runtime.catalog.background==(17,34,51)
    end
    @test result==:ok
    @test events==[(kind="key",key="char",char="a"),(kind="mouse",x=12,y=8,button="mouse_left",action="mouse_press"),
        (kind="key",key="up",char="\0"),(kind="key",key="char",char="z")]
    @test raw==["a","\e[<0;12;8M","\e[A","z"]
    wait(writer);theme_lifecycle_close!(lifecycle);close(input)
    Tachikoma.INPUT_IO[]=previous;Tachikoma.INPUT_ACTIVE[]=active;capture || Tachikoma.disable_raw_capture!()
    Base.stop_reading(pipe.out);close(pipe.in);close(pipe.out)
end
@testset "Ownership barrier, reserved DA1, invalid bytes and teardown" begin
    lifecycle=life();input=ThemeTerminalInput(;source=IOBuffer(),lifecycle)
    theme_input_feed!(input,codeunits("a\e]11;#112233\a\e[?1;2cz"))
    @test String(readavailable(input))=="a"
    @test isnothing(lifecycle.runtime.catalog.background)
    @test theme_input_poll!(input)
    @test lifecycle.runtime.catalog.background==(17,34,51)
    @test String(readavailable(input))=="z"
    theme_input_feed!(input,codeunits("\e[?1;2cx"))
    @test String(readavailable(input))=="\e[?1;2cx"
    theme_lifecycle_selection!(lifecycle)
    theme_input_reserve_device_reply!(input)
    theme_input_feed!(input,codeunits("\e[?1;2c"))
    @test String(readavailable(input))=="\e[?1;2c"
    @test !terminal_color_settled(lifecycle.queries,lifecycle.latest_query)
    theme_input_feed!(input,codeunits("\e[?1;2c"));theme_input_poll!(input)
    @test terminal_color_settled(lifecycle.queries,lifecycle.latest_query)
    invalid=UInt8[0x1b,0x5d,0x31,0x31,0x3b,0xff,0x07]
    theme_input_feed!(input,invalid)
    @test readavailable(input)==invalid
    close(input);@test isopen(input.source)
    theme_input_feed!(input,codeunits("ignored"));@test isempty(readavailable(input))
    theme_lifecycle_close!(lifecycle)
    previous=Tachikoma.INPUT_IO[];active=Tachikoma.INPUT_ACTIVE[]
    Tachikoma.INPUT_ACTIVE[]=false
    unopened=life();@test !theme_input_attach!(unopened).ok;theme_lifecycle_close!(unopened)
    fresh=life();source=IOBuffer();Tachikoma.INPUT_IO[]=source;Tachikoma.INPUT_ACTIVE[]=true
    attached=theme_input_attach!(fresh)
    @test attached.ok && Tachikoma.INPUT_IO[]===attached.input
    @test !theme_input_attach!(fresh).ok
    @test theme_input_detach!(attached.input).restored
    @test Tachikoma.INPUT_IO[]===source && isopen(source)
    other=IOBuffer();attached=theme_input_attach!(fresh);Tachikoma.INPUT_IO[]=other
    @test !theme_input_detach!(attached.input).restored
    @test Tachikoma.INPUT_IO[]===other
    theme_lifecycle_close!(fresh);Tachikoma.INPUT_IO[]=previous;Tachikoma.INPUT_ACTIVE[]=active
end
end

@testset "Libuv bridge waits for source readability without consuming bytes" begin
    pipe = Pipe()
    Base.link_pipe!(pipe;reader_supports_async=true,writer_supports_async=true)
    writer = @async begin
        sleep(0.01)
        write(pipe.in,"x")
    end
    @test ThemeInputTests.theme_input_wait_source(pipe.out) === nothing
    @test bytesavailable(pipe.out) == 1
    @test read(pipe.out,UInt8) == UInt8('x')
    wait(writer)
    close(pipe.in)
    close(pipe.out)
end
