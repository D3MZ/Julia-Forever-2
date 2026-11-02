# Invoked only by theme_input_pty.py on a private local PTY; no network or model calls.
using JSON,Tachikoma
module ThemeInputPTY
using JSON,Tachikoma
for file in ("theme_colors.jl","theme_system.jl","theme_runtime.jl","theme_terminal_query.jl","theme_file_watch.jl","theme_lifecycle.jl","theme_input_bridge.jl")
    include(joinpath(@__DIR__,"..","ext","terminal",file))
end
Base.@kwdef mutable struct Probe <: Tachikoma.Model
    lifecycle::Any = nothing
    input::Any = nothing
    events::Vector{Any} = Any[]
    quit::Bool = false
    started::Float64 = 0.0
    attached::Bool = false
    restored::Bool = false
    observed_background::Any = nothing
end
function Tachikoma.init!(probe::Probe,terminal::Tachikoma.Terminal)
    runtime=ThemeRuntime(theme_catalog(;preserve_extras=false))
    probe.lifecycle=ThemeLifecycle(;runtime,output=terminal.io,colorfgbg="")
    attached=theme_input_attach!(probe.lifecycle)
    probe.attached=attached.ok
    probe.input=attached.input
    theme_lifecycle_start!(probe.lifecycle)
    probe.started=time()
end
function finish!(probe)
    if !probe.quit
        probe.observed_background=probe.lifecycle.runtime.catalog.background
        theme_lifecycle_close!(probe.lifecycle)
        probe.restored=theme_input_detach!(probe.input).restored
        probe.quit=true
    end
    nothing
end
function Tachikoma.update!(probe::Probe,event::Tachikoma.KeyEvent)
    push!(probe.events,Dict("kind"=>"key","key"=>String(event.key),"char"=>string(event.char),"raw"=>String(copy(Tachikoma.last_event_raw()))))
    if event.key==:char && event.char=='q'
        finish!(probe)
    end
    nothing
end
function Tachikoma.update!(probe::Probe,event::Tachikoma.MouseEvent)
    push!(probe.events,Dict("kind"=>"mouse","x"=>event.x,"y"=>event.y,"button"=>string(event.button),"action"=>string(event.action),"raw"=>String(copy(Tachikoma.last_event_raw()))))
    nothing
end
Tachikoma.view(::Probe,::Tachikoma.Frame)=nothing
Tachikoma.should_quit(probe::Probe)=probe.quit
function Tachikoma.pre_render!(probe::Probe)
    theme_input_poll!(probe.input)
    time()-probe.started>5 && finish!(probe)
    nothing
end
Tachikoma.cleanup!(probe::Probe)=finish!(probe)
end
probe=ThemeInputPTY.Probe()
Tachikoma.enable_raw_capture!()
Tachikoma.app(probe;default_bindings=false,io=stdout,input=stdin,tty_size=(rows=24,cols=80),fps=60)
write(ARGS[1],JSON.json(Dict("attached"=>probe.attached,"restored"=>probe.restored,"background"=>probe.observed_background,
    "events"=>probe.events,"inputClosed"=>probe.input.closed,"upstreamOpen"=>isopen(probe.input.source),
    "pendingQueries"=>length(probe.lifecycle.queries.queue),"watcherClosed"=>isnothing(probe.lifecycle.watcher.monitor),"lifecycleClosed"=>probe.lifecycle.closed)))
