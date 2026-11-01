module JuliaForever2

export greet, Kernel, ComponentSpec, component, install!, remove!, acquire!, release!, Session, Message, Reply, run_turn!, spawn_agent!
export with_component, wrap_component!, evaluate!, submit_turn!, submit_evaluation!, run_child!, cancel!
export ExecutionContext, ExecutionResult, HarnessEvent, ProviderResult, TaskHandle
export AgentDefinition, Conversation, SessionRuntime, ModelRequest
export Answer, ActionDecision, RunJulia, Failure

public respond, execute!, initialize_executor!, fork_executor, close_executor!, JuliaExecutor
public response_reply, response_usage, emit!, cancelled, remaining_time, cancellation_event
public register_cancellation!, unregister_cancellation!
public current_execution_context
public append_message!, clear_history!, replace_message!, history_revision, history_snapshot, message_result
public default_kernel, CodeModePolicy, prompt_instructions, UsageReport, normalize_usage
public reply_schema, reply_format, decode_reply
public ProviderDescriptor, register_provider!, unregister_provider!, provider_descriptors, provider_descriptor
public ProviderRegistry, builtin_provider_registry
public ModelSpec, ProviderFactory, ModelProvider, respond_model, select_model, provider_models, provider_model
public HTTPModelBackend, OpenAIChatProtocol, AnthropicMessagesProtocol, StreamedCompletion
public MemoryModelStore, read_model_catalog, write_model_catalog!, delete_model_catalog!
public provider_id, provider_from_name, configured_provider, provider_name, provider_detail, usage_label, main
public component_snapshot, provider_selection_snapshot, provider_settings_snapshot, select_provider!
public ResponseProgress, protocol_progress, emit_protocol_progress!, operation_id
public usage_snapshot, model_request, own_resource!
public AgentDecision, agent_decision, action_content, action_kind, action_payload
public BoundComponent, bind_component, bound_dependency, fork_kernel

include("kernel.jl")
include("agent.jl")
include("features/code_mode/streaming.jl")
include("infrastructure/infrastructure.jl")
include("auth.jl")
include("providers.jl")
include("application/presentation.jl")

"""Run an installed frontend."""
function main end

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
