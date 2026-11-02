# Native wheel algorithm derived from Pi wheel-scroll.ts at 2c8d1feb; MIT, see licenses/pi-LICENSE.
public TerminalWheelScroll, terminal_wheel_setting!, terminal_wheel_lines!, terminal_wheel_delta!, terminal_scroll_control_wheel!

"""Local macOS terminals already accelerate; any declared SSH environment leaves acceleration native."""
terminal_wheel_accelerates(;platform::Symbol=Sys.isapple() ? :darwin : :other,environment=ENV) =
    !(platform==:darwin && all(key->!haskey(environment,key),("SSH_CONNECTION","SSH_CLIENT","SSH_TTY")))

"""Keep the original velocity average and fractional carry independent of scrollbar geometry."""
Base.@kwdef mutable struct TerminalWheelScroll
    lines::Union{Symbol,Int} = :auto
    accelerate::Bool = terminal_wheel_accelerates()
    last_time::Float64 = -Inf
    last_direction::Int = 0
    average_gap::Union{Nothing,Float64} = nothing
    carry::Float64 = 0.0
end

function terminal_wheel_setting!(wheel::TerminalWheelScroll,value::AbstractString)
    parsed=value=="auto" ? :auto : tryparse(Int,value)
    valid=parsed===:auto || parsed isa Int && parsed in (1,2,3,5,10)
    if parsed===:auto || parsed isa Int && parsed in (1,2,3,5,10)
        wheel.lines=parsed
        wheel.last_time=-Inf;wheel.last_direction=0;wheel.average_gap=nothing;wheel.carry=0.0
    end
    (ok=valid,reason=valid ? "" : "Invalid fullscreen wheel setting")
end

"""Convert one direction/time into source-equivalent lines; times are monotonic milliseconds."""
function terminal_wheel_lines!(wheel::TerminalWheelScroll,direction::Integer,now_ms::Real)
    count=1
    if wheel.lines isa Int
        count=max(1,wheel.lines)
    elseif wheel.accelerate
        gap=Float64(now_ms)-wheel.last_time
        same=direction==wheel.last_direction && gap<=200
        wheel.last_time=Float64(now_ms);wheel.last_direction=Int(direction)
        if !same
            wheel.average_gap=nothing;wheel.carry=0.0
        elseif gap>=5
            previous=wheel.average_gap
            average=isnothing(previous) ? gap : (previous+gap)/2
            wheel.average_gap=average
            lines=min(6.0,max(1.0,100/average))+wheel.carry
            count=floor(Int,lines)
            wheel.carry=lines-count
        end
    end
    count
end

"""Compute velocity before menu dispatch, even when a component consumes this wheel event."""
function terminal_wheel_delta!(wheel::TerminalWheelScroll,event::Tachikoma.MouseEvent;now::Real=time_ns()/1e9)
    delta=0
    if event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
        direction=event.button==Tachikoma.mouse_scroll_up ? -1 : 1
        delta=direction*terminal_wheel_lines!(wheel,direction,1000now)*(event.alt ? 5 : 1)
    end
    delta
end

"""Consume a previously computed wheel delta only after fullscreen component dispatch declines it."""
function terminal_scroll_control_wheel!(control::TerminalScrollControl,event::Tachikoma.MouseEvent,
        delta::Integer;now::Real=time_ns()/1e9)
    handled=!control.closed && control.snapshot.fullscreen && event.button in (Tachikoma.mouse_scroll_up,Tachikoma.mouse_scroll_down)
    remaining=0
    if handled
        remaining=terminal_scroll_control_by!(control,delta;now)
        # Source routeWheel refreshes hover without treating the wheel as a thumb drag.
        viewport=control.snapshot
        geometry=terminal_scroll_geometry(control.scroll,viewport.rect.width;include_hidden=true,now)
        clip=viewport.clip
        hover=!isnothing(geometry) && event.x==viewport.rect.x+geometry.column-1 &&
            clip.x<=event.x<clip.x+clip.width && clip.y<=event.y<clip.y+clip.height
        terminal_scroll_active!(control.scroll,hover;now)
        terminal_scroll_control_timer!(control;now)
    end
    (handled,delta,remaining,snapshot=control.snapshot)
end

"""Convenience path for an already unhandled wheel event; hosts with menus compute velocity before dispatch."""
function terminal_scroll_control_wheel!(control::TerminalScrollControl,wheel::TerminalWheelScroll,
        event::Tachikoma.MouseEvent;now::Real=time_ns()/1e9)
    delta=!control.closed && control.snapshot.fullscreen ? terminal_wheel_delta!(wheel,event;now) : 0
    terminal_scroll_control_wheel!(control,event,delta;now)
end
