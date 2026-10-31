module JuliaForever2

export greet, Kernel, ComponentSpec, component, install!, remove!, acquire!, release!, Session, Message, Reply, run_turn!, spawn_agent!
export with_component, wrap_component!, evaluate!, submit_turn!, submit_evaluation!, run_child!, cancel!
export ExecutionContext, ExecutionResult, HarnessEvent, ProviderResult, TaskHandle

public respond, execute!, initialize_executor!, fork_executor, close_executor!, JuliaExecutor
public response_reply, response_usage, emit!, cancelled, remaining_time, cancellation_event
public register_cancellation!, unregister_cancellation!
public current_execution_context
public append_message!, clear_history!, replace_message!, history_revision, history_snapshot, message_result
public default_kernel, CodeModePolicy, prompt_instructions, UsageReport, normalize_usage
public reply_schema, reply_format, decode_reply
public ProviderDescriptor, register_provider!, unregister_provider!, provider_descriptors, provider_descriptor
public provider_id, provider_from_name, configured_provider, provider_name, provider_detail, usage_label, main

include("kernel.jl")
include("agent.jl")
include("auth.jl")
include("providers.jl")

"""Run an installed frontend."""
function main end

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
