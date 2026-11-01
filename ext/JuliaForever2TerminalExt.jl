module JuliaForever2TerminalExt

public App, CommandSpec, register_command!, remove_command!
public register_event_handler!, remove_event_handler!, enqueue_event!
public refresh_settings!, terminal_app
public menu_snapshot, menu_action, register_prompt!, register_skill!, remove_skill!, set_skill_commands!, discover_commands, complete_input!

using JuliaForever2
using JuliaForever2: AuthFlow, active_auth, cancel_auth!, config_dir, default_kernel,
    ProviderDescriptor, ProviderRegistry, DEFAULT_PROVIDER_REGISTRY, provider_descriptors, provider_descriptor, provider_from_name,
    provider_id, provider_detail, configured_provider, save_provider!, usage_label,
    provider_settings_snapshot, provider_selection_snapshot, component_snapshot,
    ResponseProgress, operation_id, cancelled,
    TaskHandle, submit_turn!, submit_evaluation!, cancel!, with_component,
    append_message!, clear_history!, replace_message!, history_snapshot
using Tachikoma
using CommonMark
using JSON
import Tachikoma: update!, view, should_quit, task_queue, cleanup!

include("terminal.jl")

end
