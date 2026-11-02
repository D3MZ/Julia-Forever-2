# Native selector bindings derived from Pi 1.4.0 (MIT), pinned 2c8d1feb; license: licenses/pi-LICENSE.
struct NativeSelectorBindings
    registry::Union{Nothing,NativeKeybindings}
    kitty::Bool
end
NativeSelectorBindings()=NativeSelectorBindings(nothing,false)
const NATIVE_SELECTOR_IDS=(up="tui.select.up",down="tui.select.down",page_up="tui.select.pageUp",page_down="tui.select.pageDown",confirm="tui.select.confirm",cancel="tui.select.cancel")
const NATIVE_SELECTOR_DEFAULTS=(up=("up",),down=("down",),page_up=("pageUp",),page_down=("pageDown",),confirm=("enter",),cancel=("escape","ctrl+c"))

"""Resolve the actual owner registry, preserving standalone component defaults without shared mutable state."""
function native_selector_keys(context::NativeSelectorBindings,action::Symbol)
    isnothing(context.registry) ? getproperty(NATIVE_SELECTOR_DEFAULTS,action) : get(context.registry.effective,getproperty(NATIVE_SELECTOR_IDS,action),())
end

"""Match a semantic action only; the focused component retains effect and conflict ordering."""
function native_selector_matches(context::NativeSelectorBindings,action::Symbol,packet::AbstractString)
    !occursin("\e[200~",packet) && any(key->native_binding_matches(packet,key;kitty=context.kitty),native_selector_keys(context,action))
end

"""Preserve the original extension selector's expand-before-confirm ownership, even without a callback."""
function native_selector_expand_matches(context::NativeSelectorBindings,packet::AbstractString)
    isnothing(context.registry) ? native_binding_matches(packet,"ctrl+o";kitty=context.kitty) :
        native_keybinding_matches(context.registry,"app.tools.expand",packet;kitty=context.kitty)
end

"""Keep exact source key labels and explicit empty-array unbinding in rendered hints."""
function native_selector_text(context::NativeSelectorBindings,action::Symbol;capitalize::Bool=false)
    keys=join(native_selector_keys(context,action),"/")
    join((join(((capitalize ? uppercasefirst : identity)(Sys.isapple() && lowercase(part)=="alt" ? "option" : part) for part in split(key,'+';keepempty=true)),"+") for key in split(keys,'/';keepempty=true)),"/")
end

"""Resolve navigation in the original selector order without inventing select/cancel actions."""
function native_selector_navigation(context::NativeSelectorBindings,packet::AbstractString)
    matched=:none
    for action in (:up,:down,:page_up,:page_down)
        if matched==:none && native_selector_matches(context,action,packet)
            matched=action
        end
    end
    matched
end

"""Own only bounded ordinary menu paste bytes; private authentication input has a separate byte owner."""
Base.@kwdef mutable struct NativeSelectorPaste
    owner::Union{Nothing,Tuple{Symbol,Tuple{Vararg{String}},UInt}}=nothing
    prefix::String=""
    buffer::String=""
    active::Bool=false
    discard::Bool=false
end

function native_selector_paste_reset!(state::NativeSelectorPaste)
    state.owner=nothing;state.prefix="";state.buffer="";state.active=false;state.discard=false
    nothing
end

"""Collect one menu paste before dispatch, discarding embedded actions and closer-packet trailing bytes."""
function native_selector_paste_packet!(state::NativeSelectorPaste,packet::String;escape_key::Bool=false)
    begin_marker="\e[200~";end_marker="\e[201~"
    if state.active
        if state.discard || ncodeunits(state.buffer)+ncodeunits(packet)>65536
            state.discard=true;state.buffer=""
            candidate=state.prefix*packet
        else
            state.buffer*=packet;candidate=state.buffer
        end
        ending=findfirst(end_marker,candidate)
        if !isnothing(ending)
            data=state.discard ? nothing : String(SubString(candidate,1,last(ending)))
            native_selector_paste_reset!(state)
            (handled=true,data)
        else
            state.prefix=""
            for count in 1:ncodeunits(end_marker)-1
                prefix=first(end_marker,count)
                endswith(candidate,prefix) && (state.prefix=prefix)
            end
            (handled=true,data=nothing)
        end
    elseif !isempty(state.prefix)
        combined=state.prefix*packet;state.prefix=""
        if startswith(begin_marker,combined) && combined!=begin_marker
            state.prefix=combined
            (handled=true,data=nothing)
        elseif startswith(combined,begin_marker)
            state.active=true
            native_selector_paste_packet!(state,combined)
        else
            native_selector_paste_reset!(state)
            (handled=true,data=nothing)
        end
    elseif startswith(packet,begin_marker)
        state.active=true
        native_selector_paste_packet!(state,packet)
    elseif !isempty(packet) && startswith(begin_marker,packet) && (packet!="\e" || !escape_key)
        state.prefix=packet
        (handled=true,data=nothing)
    else
        (handled=false,data=nothing)
    end
end

"""Preserve original fixed-label spelling for defaults, but never advertise a replaced shortcut."""
function native_selector_hint(context::NativeSelectorBindings,action::Symbol,original::AbstractString;capitalize::Bool=false)
    Tuple(native_selector_keys(context,action))==getproperty(NATIVE_SELECTOR_DEFAULTS,action) ? String(original) : native_selector_text(context,action;capitalize)
end
function native_selector_move_hint(context::NativeSelectorBindings,original::AbstractString)
    unchanged=all(action->Tuple(native_selector_keys(context,action))==getproperty(NATIVE_SELECTOR_DEFAULTS,action),(:up,:down))
    unchanged ? String(original) : native_selector_text(context,:up)*"/"*native_selector_text(context,:down)
end
