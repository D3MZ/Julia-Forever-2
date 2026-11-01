const TranscriptContent = Union{String,Vector{Tachikoma.Span}}
const TranscriptLine = Tuple{TranscriptContent,Symbol}

struct CommandSpec{F}
    name::String
    description::String
    action::F
end
CommandSpec(name::AbstractString, description::AbstractString, action) = CommandSpec(String(name), String(description), action)

mutable struct EventHandler{F}
    action::F
end

mutable struct SettingsState
    directory::String
    registry::ProviderRegistry
    providers::Vector{ProviderDescriptor}
    labels::Vector{String}
    auth_flow::Union{AuthFlow,Nothing}
    auth_task::Union{Task,Nothing}
    auth_url::String
    auth_provider::Symbol
end
SettingsState(directory::AbstractString, registry::ProviderRegistry) = SettingsState(String(directory), registry, ProviderDescriptor[], String[], nothing, nothing, "", :none)

mutable struct UpdateState
    automatic::Bool
    latest::Union{UpdateCheck,Nothing}
    checking::Bool
    installing::Bool
    requested_install::Bool
    monitor::Union{Task,Nothing}
end
UpdateState(directory::AbstractString) = UpdateState(auto_updates_enabled(directory), nothing, false, false, false, nothing)

mutable struct TranscriptState
    width::Int
    revision::UInt
    messages::Vector{Message}
    chunks::Vector{Vector{TranscriptLine}}
    offsets::Vector{Int}
    lines::Vector{TranscriptLine}
    preview::Union{ResponseProgress,Nothing}
    preview_operation_id::UInt64
    preview_width::Int
    preview_dirty::Bool
    preview_lines::Vector{TranscriptLine}
end
TranscriptState() = TranscriptState(0, typemax(UInt), Message[], Vector{TranscriptLine}[], Int[], TranscriptLine[], nothing, UInt64(0), 0, false, TranscriptLine[])

mutable struct OperationState
    active::Union{TaskHandle,Nothing}
    closing::Threads.Atomic{Bool}
    event_lock::ReentrantLock
    watchers::Vector{Task}
end
OperationState() = OperationState(nothing, Threads.Atomic{Bool}(false), ReentrantLock(), Task[])

mutable struct App{S<:Session} <: Model
    session::S
    input::TextInput
    page::Symbol
    menu::Bool
    selected::Int
    quit::Bool
    busy::Bool
    queue::TaskQueue
    status::String
    scroll::Int
    area::Rect
    directory::String
    commands::Vector{CommandSpec}
    event_handlers::Dict{Symbol,Vector{EventHandler}}
    settings::SettingsState
    updates::UpdateState
    transcript::TranscriptState
    operations::OperationState
end

const APP_COMPATIBILITY_PROPERTIES = (
    settings_dir=(:settings, :directory), providers=(:settings, :providers), provider_labels=(:settings, :labels),
    auth_flow=(:settings, :auth_flow), auth_task=(:settings, :auth_task),
    auth_url=(:settings, :auth_url), auth_provider=(:settings, :auth_provider),
    active_turn=(:operations, :active), closing=(:operations, :closing),
    event_lock=(:operations, :event_lock), watchers=(:operations, :watchers),
    transcript_width=(:transcript, :width), transcript_revision=(:transcript, :revision),
    transcript_messages=(:transcript, :messages), transcript_chunks=(:transcript, :chunks),
    transcript_offsets=(:transcript, :offsets), transcript_lines=(:transcript, :lines),
)

"""Keep existing frontend field access compatible while each feature owns its state."""
function Base.getproperty(app::App, name::Symbol)
    if hasproperty(APP_COMPATIBILITY_PROPERTIES, name)
        owner, property = getproperty(APP_COMPATIBILITY_PROPERTIES, name)
        getfield(getfield(app, owner), property)
    else
        getfield(app, name)
    end
end

function Base.setproperty!(app::App, name::Symbol, value)
    if hasproperty(APP_COMPATIBILITY_PROPERTIES, name)
        owner, property = getproperty(APP_COMPATIBILITY_PROPERTIES, name)
        state = getfield(app, owner)
        setfield!(state, property, convert(fieldtype(typeof(state), property), value))
    else
        setfield!(app, name, convert(fieldtype(typeof(app), name), value))
    end
end

Base.propertynames(app::App, private::Bool=false) = (fieldnames(typeof(app))..., keys(APP_COMPATIBILITY_PROPERTIES)...)
