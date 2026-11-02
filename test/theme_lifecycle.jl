using Test,JSON,Tachikoma
module ThemeLifecycleTests
using Test,JSON,Tachikoma
for file in ("theme_colors.jl","theme_system.jl","theme_runtime.jl","theme_terminal_query.jl","theme_file_watch.jl","theme_lifecycle.jl")
    include(joinpath(@__DIR__,"..","ext","terminal",file))
end
Base.@kwdef mutable struct ClockTimer
    due::Float64
    delay::Float64
    callback::Any
    cancelled::Bool = false
end
Base.@kwdef mutable struct Clock
    now::Float64 = 0.0
    timers::Vector{ClockTimer} = ClockTimer[]
end
function schedule(clock,seconds,callback)
    timer = ClockTimer(;due=clock.now+seconds,delay=seconds,callback)
    push!(clock.timers,timer)
    timer
end
cancel(timer::ClockTimer) = (timer.cancelled=true;nothing)
cancel(::Nothing) = nothing
function advance!(clock,ms)
    clock.now += ms/1000
    for timer in clock.timers
        if !timer.cancelled && timer.due<=clock.now+1e-12
            timer.cancelled = true
            timer.callback()
        end
    end
    nothing
end
delays(clock) = [round(Int,t.delay*1000) for t in clock.timers if !t.cancelled]
rgb(value) = Dict("r"=>value[1],"g"=>value[2],"b"=>value[3])
function colors(value::TerminalColors)
    result = Dict{String,Any}()
    isnothing(value.foreground) || (result["foreground"]=rgb(value.foreground))
    isnothing(value.background) || (result["background"]=rgb(value.background))
    isempty(value.palette) || (result["palette"]=rgb.(value.palette))
    result
end
function ansi(runtime)
    style=theme_token_style(runtime,"accent")
    style.fg isa Tachikoma.NoColor ? "\e[39m" : sprint(io -> Tachikoma.write_fg(io,style.fg))
end
function accent(runtime)
    value = theme_rgb(runtime.active.colors["accent"])
    "#"*join(string(channel;base=16,pad=2) for channel in value)
end
function watcher_events!(watcher,previous)
    timedwait(() -> lock(() -> watcher.observed_events>previous,watcher.lock),2;pollint=0.005)==:ok
end
function theme_document(accent)
    document = JSON.parsefile(joinpath(@__DIR__,"..","ext","terminal","theme_assets","dark.json"))
    document["name"]="fixture"
    document["colors"]["accent"]=accent
    document
end

function run_original()
    reference=get(ENV,"PI_REFERENCE","")
    @test isdir(reference)
    evidence=get(ENV,"THEME_LIFECYCLE_EVIDENCE",mktempdir())
    mkpath(evidence)
    output=joinpath(evidence,"original-fresh.json")
    oracle=joinpath(@__DIR__,"differential","pi_theme_lifecycle_oracle.mjs")
    run(`node $oracle $reference $output`)
    JSON.parsefile(output)
end
const original=run_original()
@testset "Exact original OSC and scheme parsing" begin
    for case in original["parsers"]
        color=terminal_color_response(case["input"])
        actual=isnothing(color) ? nothing : Dict{String,Any}("target"=>color.target in ("foreground","background") ? color.target : parse(Int,color.target))
        if !isnothing(color) && !isnothing(color.rgb)
            actual["rgb"]=rgb(color.rgb)
        end
        @test actual==case["color"]
        scheme=terminal_color_scheme(case["input"])
        @test (isnothing(scheme) ? nothing : String(scheme))==case["scheme"]
    end
end
@testset "Exact original query timing, late partial reply, duplicate and DA1 queue boundaries" begin
    for case in original["queries"]
        clock=Clock();events=Any[];writes=String[]
        queries=TerminalColorQueries(;write=bytes -> push!(writes,bytes),
            deliver=(id,kind,value) -> push!(events,Dict("index"=>Int(id)-1,"kind"=>String(kind),"colors"=>colors(value))),
            schedule=(seconds,callback) -> schedule(clock,seconds,callback),cancel)
        for expected in case["snapshots"]
            step=expected["step"];consumed=nothing
            if step["type"]=="start"
                terminal_color_query!(queries)
            elseif step["type"]=="advance"
                advance!(clock,step["ms"]);terminal_color_poll!(queries)
            else
                consumed=terminal_color_input!(queries,step["input"])
            end
            @test consumed==expected["consumed"]
            @test events==expected["events"]
            @test writes==expected["writes"]
            @test length(queries.queue)==expected["pending"]
            @test delays(clock)==expected["timers"]
        end
        terminal_color_close!(queries)
        size=length(events);advance!(clock,1000);terminal_color_poll!(queries)
        @test length(events)==size
        @test !terminal_color_input!(queries,"\e]11;#ffffff\a")
        @test isempty(delays(clock))
    end
end
@testset "Real directory watcher matches original last-good and debounce lifecycle" begin
    mktempdir() do directory
        path=joinpath(directory,"fixture.json")
        write(path,JSON.json(theme_document("#112233")))
        runtime=ThemeRuntime(theme_catalog(directory;preserve_extras=false);setting="fixture")
        clock=Clock();watcher=ThemeFileWatch(;runtime,schedule=(seconds,callback) -> schedule(clock,seconds,callback),cancel)
        @test theme_file_watch!(watcher).watching
        states=Any[]
        capture(event)=push!(states,Dict("event"=>event,"accent"=>accent(runtime),"changed"=>watcher.reloads,"delays"=>delays(clock)))
        last_observed=Ref(UInt64(0))
        observed()=(@test watcher_events!(watcher,last_observed[]);last_observed[]=watcher.observed_events;theme_file_poll!(watcher))
        capture("start")
        write(path,JSON.json(theme_document("#445566")));observed();capture("write")
        advance!(clock,99);theme_file_poll!(watcher);capture("before-debounce")
        advance!(clock,1);theme_file_poll!(watcher);capture("reload")
        write(path,"{");observed();advance!(clock,100);theme_file_poll!(watcher);capture("invalid-retains")
        rm(path);observed();advance!(clock,100);theme_file_poll!(watcher);capture("missing-retains")
        write(path,JSON.json(theme_document("#778899")));observed();advance!(clock,100);theme_file_poll!(watcher);capture("recreate-reloads")
        write(joinpath(directory,"other.json"),JSON.json(theme_document("#ffffff")));observed();advance!(clock,100);theme_file_poll!(watcher);capture("unrelated-ignored")
        temporary=joinpath(directory,"replacement.json");write(temporary,JSON.json(theme_document("#aabbcc")));Base.Filesystem.rename(temporary,path);observed();advance!(clock,100);theme_file_poll!(watcher);capture("atomic-replace-reloads")
        write(path,JSON.json(theme_document("#abcdef")));observed();capture("pending-before-stop")
        monitor=watcher.monitor;worker=watcher.worker
        theme_file_close!(watcher);advance!(clock,100);theme_file_poll!(watcher);capture("stopped-retains")
        @test !isopen(monitor)
        @test istaskdone(worker)
        @test states==original["watcher"]
        evidence=get(ENV,"THEME_LIFECYCLE_EVIDENCE","")
        isempty(evidence) || write(joinpath(evidence,"native-watcher.json"),JSON.json(states))
    end
end
@testset "Debounce replacement, stale generations and real watcher timers" begin
    mktempdir() do directory
        path=joinpath(directory,"fixture.json")
        write(path,JSON.json(theme_document("#112233")))
        runtime=ThemeRuntime(theme_catalog(directory;preserve_extras=false);setting="fixture")
        clock=Clock();watcher=ThemeFileWatch(;runtime,schedule=(seconds,callback) -> schedule(clock,seconds,callback),cancel)
        @test theme_file_watch!(watcher).watching
        generation=watcher.generation
        theme_file_event!(watcher,"fixture.json")
        advance!(clock,99)
        theme_file_event!(watcher,"fixture.json")
        advance!(clock,1);@test !theme_file_poll!(watcher)
        advance!(clock,99);@test theme_file_poll!(watcher)
        @test watcher.reloads==1
        theme_file_event!(watcher,"")
        advance!(clock,100)
        theme_file_event!(watcher,"fixture.json")
        @test !theme_file_poll!(watcher)
        @test !isnothing(watcher.timer)
        theme_file_close!(watcher)
        @test isempty(delays(clock))
        theme_file_event!(watcher,"fixture.json",generation)
        advance!(clock,200);@test !theme_file_poll!(watcher)
        @test watcher.reloads==1
        runtime.requested="dark";runtime.active=theme_load(runtime.catalog,"dark").theme
        @test !theme_file_watch!(watcher).watching
        @test isnothing(watcher.monitor)
        runtime.requested="fixture";runtime.active=theme_load(runtime.catalog,"fixture").theme
        real=ThemeFileWatch(;runtime)
        @test theme_file_watch!(real).watching
        write(path,JSON.json(theme_document("#aabbcc")))
        @test timedwait(() -> (theme_file_poll!(real);accent(runtime)=="#aabbcc"),2;pollint=0.005)==:ok
        @test runtime.catalog.registered["fixture"]===runtime.active
        write(path,"{")
        @test timedwait(() -> (theme_file_poll!(real);!isempty(real.last_error)),2;pollint=0.005)==:ok
        @test accent(runtime)=="#aabbcc"
        theme_file_close!(real)
    end
end

@testset "Original controller appearance and partial-color transitions" begin
    clock=Clock();output=IOBuffer();runtime=ThemeRuntime(theme_catalog(;preserve_extras=false))
    lifecycle=ThemeLifecycle(;runtime,output,colorfgbg="",schedule=(seconds,callback) -> schedule(clock,seconds,callback),cancel)
    for expected in original["controller"]
        step=expected["step"];kind=step["type"]
        if kind=="start"
            theme_lifecycle_start!(lifecycle)
        elseif kind=="reset"
            theme_lifecycle_close!(lifecycle)
            clock=Clock();output=IOBuffer();runtime=ThemeRuntime(theme_catalog(;preserve_extras=false);setting=step["setting"])
            lifecycle=ThemeLifecycle(;runtime,output,colorfgbg="",schedule=(seconds,callback) -> schedule(clock,seconds,callback),cancel)
            theme_lifecycle_start!(lifecycle)
        elseif kind=="instance"
            runtime.active=theme_load(runtime.catalog,step["value"]).theme
            theme_lifecycle_selection!(lifecycle;in_memory=true,query=false)
        elseif kind=="direct-colors"
            theme_lifecycle_colors!(lifecycle,TerminalColors(;background=Tuple(Int.(step["background"]))))
        elseif kind=="advance"
            advance!(clock,step["ms"])
        elseif kind=="input"
            theme_lifecycle_input!(lifecycle,step["data"])
        elseif kind in ("setting","fixed")
            runtime.committed=step["value"];runtime.owner_name=something(theme_resolve_setting(runtime.committed,runtime.catalog.appearance),"system")
            theme_preview!(runtime,runtime.committed)
            theme_lifecycle_selection!(lifecycle;query=kind=="setting")
        elseif kind=="preview"
            theme_preview!(runtime,step["value"]);theme_lifecycle_selection!(lifecycle;query=false,preview=true)
        elseif kind=="colors"
            theme_lifecycle_input!(lifecycle,"\e]10;$(step["foreground"])\a")
            theme_lifecycle_input!(lifecycle,"\e]11;$(step["background"])\a")
            theme_lifecycle_input!(lifecycle,"\e[?1;2c")
        else
            theme_lifecycle_close!(lifecycle)
        end
        theme_lifecycle_poll!(lifecycle)
        @test runtime.active.name==expected["active"]
        @test String(runtime.catalog.appearance)==expected["appearance"]
        @test ansi(runtime)==expected["accentAnsi"]
        @test String(take!(copy(output)))==join(expected["writes"])
    end
end
@testset "Native lifecycle real timers, error paths, ownership and teardown" begin
    output=IOBuffer();runtime=ThemeRuntime(theme_catalog(;preserve_extras=false));lifecycle=ThemeLifecycle(;runtime,output,colorfgbg="")
    theme_lifecycle_start!(lifecycle);size=position(output);theme_lifecycle_start!(lifecycle)
    @test position(output)==size
    @test !theme_lifecycle_ready(lifecycle)
    @test timedwait(() -> (theme_lifecycle_poll!(lifecycle);theme_lifecycle_ready(lifecycle)),2;pollint=0.005)==:ok
    @test !runtime.catalog.pending
    @test isnothing(runtime.catalog.background)
    @test !theme_lifecycle_poll!(lifecycle)
    @test !theme_lifecycle_input!(lifecycle,"normal user input")
    @test theme_lifecycle_input!(lifecycle,"\e]11;#111111\a")
    @test theme_lifecycle_input!(lifecycle,"\e[?1;2c")
    @test theme_lifecycle_poll!(lifecycle)
    @test runtime.catalog.background==(17,17,17)
    theme_lifecycle_rebind!(lifecycle)
    @test endswith(String(take!(copy(output))),"\e[?2031h")
    before=runtime.active
    theme_lifecycle_close!(lifecycle)
    @test endswith(String(take!(copy(output))),"\e[?2031l")
    @test !theme_lifecycle_input!(lifecycle,"\e]11;#eeeeee\a")
    sleep(0.12)
    @test !theme_lifecycle_poll!(lifecycle)
    @test runtime.active===before
    @test isempty(lifecycle.queries.queue)
    broken=IOBuffer();close(broken)
    failing=ThemeLifecycle(;runtime=ThemeRuntime(theme_catalog(;preserve_extras=false)),output=broken)
    theme_lifecycle_start!(failing);theme_lifecycle_poll!(failing)
    @test theme_lifecycle_ready(failing)
    @test !isempty(failing.last_error)
    @test !failing.runtime.catalog.pending
    theme_lifecycle_close!(failing)
end
end
