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
public working_directory, set_working_directory!, workspace_path
public AgentDecision, agent_decision, action_content, action_kind, action_payload
public BoundComponent, bind_component, bound_dependency, fork_kernel
public PluginSpec, PluginRegistry, PluginHost, PluginContext, Profile, ProfileStore, compose_profiles, save_profile!, load_profile, profile_names
public register_plugin!, unregister_plugin!, activate!, deactivate!, provide!, effect!, service, plugin_snapshot
public ExtensionScope, on!, dispatch_event!, event_scope_plugin
public ToolSpec, ToolCall, ToolExecutor, register_tool!, register_tool_guard!, restrict_tools!, tools_snapshot, tool, invoke_tool!
public CheckedJSONSchema, tool_argument_violations, tool_output_violations, tool_schema_definition
public RpcError, RpcResult, JsonRpcPeer, request!, notify!, feed!, start!, drain!
public AbstractRuntimeBackend, JsonRpcRuntime, runtime_request!, runtime_notify!, start_runtime, finish_runtime!
public ProcessFeature, launch_feature, apply_entry_patches, compose_entry_layers
public runtime_transport_plugin, process_launcher_plugin
public SessionStore, save_session!, load_session, session_store_plugin, session_lineage, session_descendants
public SessionQuery, SessionSearchIndex, refresh_index!, session_query_plugin, search_history, session_names
public SessionAPI, session_api_plugin, session_api_request!, session_api_peer
public start_web_server, web_server_plugin, web_url

include("kernel.jl")
include("agent.jl")
include("core/plugins.jl")
include("core/profile_store.jl")
include("core/session_store.jl")
include("core/session_query.jl")
include("core/session_api.jl")
include("core/tool_schemas.jl")
include("core/extensions.jl")
include("core/event_context.jl")
include("features/code_mode/streaming.jl")
include("infrastructure/infrastructure.jl")
include("infrastructure/jsonrpc.jl")
include("runtime/backends.jl")
include("core/profile_patches.jl")
include("auth.jl")
include("providers.jl")
include("application/presentation.jl")

"""Create a session retaining the currently active plugin composition."""
Session(host::PluginHost; kwargs...) = Session(fork_kernel(host); owns_kernel=true, kwargs...)

"""Start an independently implemented Julia web frontend when its optional HTTP extension is installed."""
function start_web_server end
function web_server_plugin end
function web_url end

"""Run an installed frontend."""
function main end

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
