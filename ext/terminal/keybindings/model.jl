# Native binding data derived from Pi 1.4.0 (MIT), pinned 2c8d1feb147f6b3d97e855da803bfe7b19f3c403.
# The reference license is retained at licenses/pi-LICENSE; no reference runtime is loaded.
struct NativeKeybindingDefinition
    id::String
    keys::Vector{String}
end

Base.@kwdef mutable struct NativeKeybindings
    definitions::Vector{NativeKeybindingDefinition} = native_app_keybinding_definitions()
    effective::Dict{String,Vector{String}} = Dict(definition.id=>copy(definition.keys) for definition in native_app_keybinding_definitions())
    configured::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    conflicts::Vector{Pair{String,Vector{String}}} = Pair{String,Vector{String}}[]
    revision::UInt = UInt(0)
    path::String = ""
    error::String = ""
    paste_prefix::String = ""
end

native_windows_keys() = Sys.iswindows() || Sys.islinux() && (!isempty(get(ENV,"WSL_DISTRO_NAME","")) || !isempty(get(ENV,"WSL_INTEROP","")))

"""Define only existing native chat actions; omitted action families cannot masquerade as configurable consumers."""
function native_app_keybinding_definitions(;windows::Bool=native_windows_keys())
    NativeKeybindingDefinition[
        NativeKeybindingDefinition("app.interrupt",["escape"]),
        NativeKeybindingDefinition("app.clear",["ctrl+c"]),
        NativeKeybindingDefinition("app.exit",["ctrl+d"]),
        NativeKeybindingDefinition("app.suspend",["ctrl+z"]),
        NativeKeybindingDefinition("app.thinking.cycle",["shift+tab"]),
        NativeKeybindingDefinition("app.model.cycleForward",["ctrl+p"]),
        NativeKeybindingDefinition("app.model.cycleBackward",[windows ? "alt+p" : "shift+ctrl+p"]),
        NativeKeybindingDefinition("app.model.select",["ctrl+l"]),
        NativeKeybindingDefinition("app.tools.expand",["ctrl+o"]),
        NativeKeybindingDefinition("app.thinking.toggle",["ctrl+t"]),
        NativeKeybindingDefinition("app.editor.external",["ctrl+g"]),
        NativeKeybindingDefinition("app.message.copy",["ctrl+x"]),
        NativeKeybindingDefinition("app.message.followUp",[windows ? "ctrl+q" : "alt+enter"]),
        NativeKeybindingDefinition("app.message.dequeue",[windows ? "alt+q" : "alt+up"]),
        NativeKeybindingDefinition("app.session.new",String[]),
        NativeKeybindingDefinition("app.session.tree",String[]),
        NativeKeybindingDefinition("app.session.fork",String[]),
        NativeKeybindingDefinition("app.session.resume",String[]),
    ]
end

"""Retain original key order, exact duplicate elimination and explicit empty-array unbinding."""
function native_keybinding_plan(state::NativeKeybindings,configured::Dict{String,Vector{String}})
    effective=Dict(definition.id=>copy(get(configured,definition.id,definition.keys)) for definition in state.definitions)
    claims=Dict{String,Vector{String}}();order=String[]
    for definition in state.definitions
        for key in get(configured,definition.id,String[])
            if !haskey(claims,key)
                claims[key]=String[];push!(order,key)
            end
            push!(claims[key],definition.id)
        end
    end
    conflicts=Pair{String,Vector{String}}[key=>claims[key] for key in order if length(claims[key])>1]
    (;effective,configured=deepcopy(configured),conflicts)
end

"""Publish a completely validated local binding snapshot in one UI-owner operation."""
function native_keybinding_install!(state::NativeKeybindings,plan)
    state.effective=plan.effective
    state.configured=plan.configured
    state.conflicts=plan.conflicts
    state.revision+=UInt(1)
    state.error=""
    nothing
end
native_keybinding_keys(state::NativeKeybindings,id::AbstractString)=copy(get(state.effective,String(id),String[]))
