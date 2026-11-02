# Native selection behavior derived from Pi (MIT), copyright (c) 2025 Mario Zechner.
# Pinned upstream: 2c8d1feb147f6b3d97e855da803bfe7b19f3c403; license: licenses/pi-LICENSE.
"""Bind selection to the current document owner without discarding selection during appended output."""
function terminal_selection_publish!(control::TerminalSelectionControl,view::TerminalSelectionView;
        owner::AbstractString,fullscreen::Bool,copy_on_select::Bool)
    if !control.closed
        replaced=control.owner!=owner || control.fullscreen!=fullscreen
        if replaced
            terminal_selection_clear!(control.state;clicks=true)
            control.generation+=1
            empty!(control.flashes.entries)
        end
        control.owner=String(owner);control.fullscreen=fullscreen;control.view=view
        control.state.copy_on_select=copy_on_select
        replaced && terminal_selection_schedule!(control)
    end
    nothing
end

selection_copy_outcome(::Val{:native})=(confirmed=true,text="Copied!",duration=1000)
selection_copy_outcome(::Val{:osc52})=(confirmed=false,text="Clipboard transfer sent to terminal; confirmation unavailable",duration=5000)
selection_copy_outcome(::Val{:none})=(confirmed=false,text="No supported clipboard destination",duration=5000)
selection_copy_outcome(::Val)=(confirmed=false,text="Clipboard transfer failed.",duration=5000)

"""Report confirmation only from the real native clipboard result; OSC writes are explicitly unconfirmed."""
function terminal_selection_copy!(control::TerminalSelectionControl,text::AbstractString;now::Real=time_ns()/1e6)
    accepted=!control.closed && control.fullscreen && !isempty(text)
    confirmed=false
    if accepted
        generation=control.generation
        operation=Task(()->Base.invokelatest(control.copy,String(text)))
        schedule(operation);wait(operation;throw=false)
        result=if istaskfailed(operation)
            selection_copy_outcome(Val(:failed))
        else
            outcome=fetch(operation)
            selection_copy_outcome(Val(outcome isa Symbol ? outcome : :failed))
        end
        if !control.closed && control.generation==generation
            terminal_selection_flash!(control.flashes,result.text;duration=result.duration,now)
            terminal_selection_schedule!(control;now)
            Base.invokelatest(control.on_change)
            confirmed=result.confirmed
        end
    end
    confirmed
end
function terminal_selection_copy_active!(control::TerminalSelectionControl;now::Real=time_ns()/1e6)
    text=terminal_selection_text(control.state,control.view)
    isnothing(text) ? false : terminal_selection_copy!(control,text;now)
end

"""Consume only an unclaimed gesture after real menus, editor controls and scrollbars receive precedence."""
function terminal_selection_handle!(control::TerminalSelectionControl,event::Tachikoma.MouseEvent;now::Real=time_ns()/1e6)
    handled=false
    if !control.closed && control.fullscreen
        action=event.action==Tachikoma.mouse_press ? :press : event.action==Tachikoma.mouse_release ? :release :
            event.button==Tachikoma.mouse_left ? :drag : :move
        button=event.button==Tachikoma.mouse_left ? :left : event.button==Tachikoma.mouse_none ? :none : :other
        result=terminal_selection_mouse!(control.state,control.view,action,button,event.x,event.y;now)
        isnothing(result.copy_text) || terminal_selection_copy!(control,result.copy_text;now)
        handled=result.handled
        terminal_selection_schedule!(control;now)
        handled && Base.invokelatest(control.on_change)
    end
    handled
end
function terminal_selection_component_press!(control::TerminalSelectionControl)
    terminal_selection_clear!(control.state)
    terminal_selection_schedule!(control)
    nothing
end
function terminal_selection_control_lines(control::TerminalSelectionControl;now::Real=time_ns()/1e6)
    terminal_selection_flash_expire!(control.flashes;now)
    lines=control.fullscreen && !control.closed ? terminal_selection_lines(control.state,control.view) : control.view.screen
    control.fullscreen && !control.closed ? terminal_selection_flash_lines(control.flashes,lines,control.view.area.width,control.view.area.height) : lines
end
function terminal_selection_close!(control::TerminalSelectionControl)
    control.closed=true;control.generation+=1
    control.timer_epoch+=1
    timer=control.timer
    isnothing(timer) || close(timer)
    control.timer=nothing
    terminal_selection_clear!(control.state;clicks=true)
    empty!(control.flashes.entries)
    nothing
end

"""Use only the App's current owned terminal handle; never assume a desktop clipboard exists."""
function terminal_selection_clipboard(app::App,text::String)
    terminal=app.settings.terminal
    isnothing(terminal) ? :none : Tachikoma.clipboard_copy!(terminal,text)
end

"""A timer only posts an immutable epoch; selection and drawing change on the UI owner's event handler."""
function terminal_selection_schedule!(control::TerminalSelectionControl;now::Real=time_ns()/1e6)
    control.timer_epoch+=1
    timer=control.timer
    isnothing(timer) || close(timer)
    control.timer=nothing
    deadline=min(control.state.next_scroll,minimum((entry.expires for entry in control.flashes.entries);init=Inf))
    if !control.closed && control.fullscreen && isfinite(deadline)
        epoch=control.timer_epoch;callback=control.on_timer
        control.timer=Timer(timer->Base.invokelatest(callback,epoch),max(0.001,(deadline-now)/1000))
    end
    nothing
end
function terminal_selection_poll!(control::TerminalSelectionControl,epoch::UInt,scroll::Function;now::Real=time_ns()/1e6)
    changed=false
    if !control.closed && control.fullscreen && epoch==control.timer_epoch
        changed=terminal_selection_flash_expire!(control.flashes;now)
        changed=terminal_selection_tick!(control.state,control.view,scroll;now) || changed
        terminal_selection_schedule!(control;now)
        changed && Base.invokelatest(control.on_change)
    end
    changed
end
