const TranscriptContent = Union{String,Vector{Tachikoma.Span}}
const TranscriptLine = Tuple{TranscriptContent,Symbol}

struct CommandSpec{F}
    name::String
    description::String
    action::F
    visible::Bool
    origin::Symbol
end
CommandSpec(name::AbstractString, description::AbstractString, action; visible=true, origin=:extension) =
    CommandSpec(String(name), String(description), action, Bool(visible), Symbol(origin))

struct RegisteredSkill
    name::String
    path::String
    description::String
end

struct RegisteredPrompt
    name::String
    description::String
end

mutable struct MenusState
    preferences::Dict{String,String}
    prompts::Vector{RegisteredPrompt}
    skills::Vector{RegisteredSkill}
    skill_commands_enabled::Bool
    path::Vector{String}
    cursor::Int
    images::Bool
    scoped_models::Set{String}
end
MenusState() = MenusState(Dict{String,String}(), RegisteredPrompt[], RegisteredSkill[],
    true, String[], 1, false, Set{String}())

mutable struct EventHandler{F}
    action::F
end

Base.@kwdef mutable struct SettingsState
    directory::String
    registry::ProviderRegistry
    providers::Vector{ProviderDescriptor} = ProviderDescriptor[]
    labels::Vector{String} = String[]
    auth_flow::Union{AuthFlow,Nothing} = nothing
    auth_task::Union{Task,Nothing} = nothing
    auth_url::String = ""
    auth_provider::Symbol = :none
end
SettingsState(directory::AbstractString, registry::ProviderRegistry) = SettingsState(; directory=String(directory), registry)

Base.@kwdef mutable struct TranscriptState
    width::Int = 0
    revision::UInt = typemax(UInt)
    messages::Vector{Message} = Message[]
    chunks::Vector{Vector{TranscriptLine}} = Vector{TranscriptLine}[]
    offsets::Vector{Int} = Int[]
    lines::Vector{TranscriptLine} = TranscriptLine[]
    preview::Union{ResponseProgress,Nothing} = nothing
    preview_operation_id::UInt64 = UInt64(0)
    preview_width::Int = 0
    preview_dirty::Bool = false
    preview_lines::Vector{TranscriptLine} = TranscriptLine[]
end

Base.@kwdef mutable struct OperationState
    active::Union{TaskHandle,Nothing} = nothing
    closing::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    event_lock::ReentrantLock = ReentrantLock()
    watchers::Vector{Task} = Task[]
end

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
    transcript::TranscriptState
    operations::OperationState
    menus::MenusState
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
