const TranscriptContent = Union{String,Vector{Tachikoma.Span}}
const TranscriptLine = Tuple{TranscriptContent,Symbol}

Base.@kwdef struct CommandSpec{F}
    name::String
    description::String
    action::F
    visible::Bool=true
    origin::Symbol=:extension
    argument_completions::Union{Nothing,Function}=nothing
end
CommandSpec(name, description, action, visible, origin) =
    CommandSpec(name, description, action, visible, origin, nothing)
CommandSpec{F}(name, description, action, visible, origin) where {F} =
    CommandSpec{F}(name, description, action, visible, origin, nothing)
CommandSpec(name::AbstractString, description::AbstractString, action; visible=true, origin=:extension, argument_completions=nothing) =
    CommandSpec(String(name), String(description), action, Bool(visible), Symbol(origin), argument_completions)

struct RegisteredSkill
    name::String
    path::String
    description::String
end

struct RegisteredPrompt
    name::String
    description::String
    content::Union{Nothing,String}
    path::Union{Nothing,String}
    argument_hint::Union{Nothing,String}
end
RegisteredPrompt(name::String,description::String) = RegisteredPrompt(name,description,nothing,nothing,nothing)

Base.@kwdef mutable struct MenusState
    keybindings::NativeKeybindings=NativeKeybindings()
    selector_paste::NativeSelectorPaste=NativeSelectorPaste()
    project_trust::Union{Nothing,ProjectTrustState}=nothing
    viewport::Union{Nothing,TerminalViewport}=nothing
    bug_report::Union{Nothing,BugReportControl} = nothing
    auth_menu_control::Union{Nothing,AuthMenuControl}=nothing
    startup::Union{Nothing,StartupControls}=nothing
    chat_press::Union{Nothing,Tuple{Int,Int}}=nothing
    preference_error::Union{Nothing,Tuple{String,String}}=nothing
    chat_editor::Union{Nothing,ChatEditorState}=nothing
    chat_completion::Union{Nothing,ChatCompletionState}=nothing
    last_sigint_ms::Int=0
    preferences::Dict{String,String} = Dict{String,String}()
    prompts::Vector{RegisteredPrompt} = RegisteredPrompt[]
    resource_warnings::Vector{String} = String[]
    resource_revisions::Dict{Tuple{Symbol,String},UInt} = Dict{Tuple{Symbol,String},UInt}()
    skills::Vector{RegisteredSkill} = RegisteredSkill[]
    skill_commands_enabled::Bool = true
    path::Vector{String} = String[]
    cursor::Int = 1
    images::Bool = false
    scoped_models::Set{String} = Set{String}()
    search::MenuSearchInput = MenuSearchInput()
    parents::Vector{Tuple{Vector{String},Int,String}} = Tuple{Vector{String},Int,String}[]
    pressed::Union{Nothing,Int} = nothing
    model_command::Union{Nothing,ModelCommandLookup} = nothing
    model_command_request::UInt = UInt(0)
    model_menu::Union{Nothing,ModelMenu} = nothing
    scoped_menu::Union{Nothing,ScopedModelMenu} = nothing
    thinking_menu::Union{Nothing,ThinkingMenu} = nothing
    enabled_models::Union{Nothing,Vector{String}} = nothing
    model_preferences::Dict{String,Any} = Dict{String,Any}()
    configuration_path::Vector{String} = String[]
    model_preferences_digest::Union{Nothing,String} = nothing
    generation::UInt = UInt(0)
    configuration_generation::UInt = UInt(0)
    configuration_page::Symbol = :chat
    scoped_save_owner::Union{Nothing,ScopedModelMenu} = nothing
    theme_runtime::Union{Nothing,ThemeRuntime} = nothing
    theme_menu::Union{Nothing,ThemeMenu} = nothing
    settings_cursor_style::Union{Nothing,Tachikoma.Style} = nothing
    tree_menu::Union{Nothing,TreeMenu} = nothing
    thinking_defaults_menu::Union{Nothing,ThinkingDefaultsMenu} = nothing
    resume_menu::Union{Nothing,ResumeMenu} = nothing
    fork_menu::Union{Nothing,ForkMenu} = nothing
    resume_revisions::Dict{String,String} = Dict{String,String}()
    logout_revisions::Dict{String,String} = Dict{String,String}()
end

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
    workspace::String = ""
    terminal::Union{Nothing,Tachikoma.Terminal} = nothing
    output::TerminalOutputState = TerminalOutputState()
    presentation::TerminalPresentation = TerminalPresentation()
    theme_input::Union{Nothing,ThemeTerminalInput} = nothing
end
SettingsState(directory::AbstractString, registry::ProviderRegistry) = SettingsState(; directory=String(directory), registry)

"""Bind a background result to the permission and check generations that produced it."""
struct BackgroundUpdateResult
    permission::UInt64
    manual::UInt64
    sequence::UInt64
    check::UpdateCheck
end

"""A stopped monitor carries the task and authority of its failed check."""
struct BackgroundMonitorFailure
    task::Task
    permission::UInt64
    manual::UInt64
    sequence::UInt64
end

"""A manual check completion carries the exact task that produced it."""
struct ManualUpdateCompletion
    task::Task
end

"""An installation completion carries its task and selected-check generation."""
struct InstallUpdateCompletion
    task::Task
    latest_generation::UInt64
end

Base.@kwdef mutable struct UpdateState
    automatic::Bool = false
    monitor_enabled::Threads.Atomic{Bool} = Threads.Atomic{Bool}(automatic)
    permission_generation::Threads.Atomic{UInt64} = Threads.Atomic{UInt64}(0)
    manual_generation::Threads.Atomic{UInt64} = Threads.Atomic{UInt64}(0)
    background_sequence::Threads.Atomic{UInt64} = Threads.Atomic{UInt64}(0)
    accepted_background::UInt64 = UInt64(0)
    latest::Union{UpdateCheck,Nothing} = nothing
    checking::Bool = false
    installing::Bool = false
    requested_install::Bool = false
    monitor::Union{Task,Nothing} = nothing
    check_task::Union{Task,Nothing} = nothing
    install_task::Union{Task,Nothing} = nothing
    latest_generation::UInt64 = UInt64(0)
    check_tasks::WeakKeyDict{Task,Nothing} = WeakKeyDict{Task,Nothing}()
    install_tasks::WeakKeyDict{Task,UInt64} = WeakKeyDict{Task,UInt64}()
end
UpdateState(automatic, monitor_enabled, latest, checking, installing, requested_install, monitor) =
    UpdateState(; automatic, monitor_enabled, latest, checking, installing, requested_install, monitor)
UpdateState(automatic, monitor_enabled, permission_generation, manual_generation, background_sequence,
        accepted_background, latest, checking, installing, requested_install, monitor) =
    UpdateState(; automatic, monitor_enabled, permission_generation, manual_generation, background_sequence,
        accepted_background, latest, checking, installing, requested_install, monitor)
UpdateState(directory::AbstractString) = UpdateState(; automatic=auto_updates_enabled(directory))

Base.@kwdef mutable struct TranscriptState
    prompts::TerminalPromptRows = TerminalPromptRows()
    notices::FrontendNoticeState = FrontendNoticeState()
    documents::CommandDocumentState = CommandDocumentState()
    footer::Any=nothing
    width::Int = 0
    revision::UInt = typemax(UInt)
    messages::Vector{Message} = Message[]
    chunks::Vector{Vector{TranscriptLine}} = Vector{TranscriptLine}[]
    offsets::Vector{Int} = Int[]
    lines::Vector{TranscriptLine} = TranscriptLine[]
    preview::Union{ResponseProgress,Nothing} = nothing
    preview_owner::Union{PreviewOwnership,Nothing} = nothing
    interrupted_responses::Vector{InterruptedResponseView} = InterruptedResponseView[]
    preview_operation_id::UInt64 = UInt64(0)
    preview_width::Int = 0
    preview_dirty::Bool = false
    preview_lines::Vector{TranscriptLine} = TranscriptLine[]
    display::SessionDisplayState = SessionDisplayState()
    display_key::Any = nothing
    display_rows::SessionDisplayRows = SessionDisplayRows()
    display_plan::Union{Nothing,SessionDisplayPlan} = nothing
end

Base.@kwdef mutable struct OperationState
    shell::UserShellState=UserShellState()
    active::Union{TaskHandle,Nothing} = nothing
    closing::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    event_lock::ReentrantLock = ReentrantLock()
    watchers::Vector{Task} = Task[]
    active_kind::Symbol = :none
    pending_start_ids::Vector{UInt64} = UInt64[]
    pending_continuation::Bool = false
end

"""A frontend session's durable archive and active runtime-to-entry mapping."""
Base.@kwdef mutable struct TerminalArchive
    store::JuliaForever2.TimelineStore
    timeline::Union{Nothing,JuliaForever2.SessionTimeline} = nothing
    entry_ids::Vector{String} = String[]
    sessions::Vector{NamedTuple} = NamedTuple[]
end

TerminalArchive(directory::AbstractString) = TerminalArchive(; store=JuliaForever2.TimelineStore(joinpath(directory, "sessions")))

"""Own a prepared runtime so unrelated operation values cannot trigger session cleanup."""
Base.@kwdef struct SessionTransition
    session::Session
    archive::TerminalArchive
    editor::String = ""
    status::String
end


mutable struct App <: Model
    session::Session
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
    menus::MenusState
    archive::TerminalArchive
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
