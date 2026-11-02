module JuliaForever2

export greet, Kernel, ComponentSpec, component, install!, remove!, acquire!, release!, Session, Message, Reply, run_turn!, spawn_agent!
export with_component, wrap_component!, evaluate!, submit_turn!, submit_evaluation!, run_child!, cancel!
export ExecutionContext, ExecutionResult, HarnessEvent, ProviderResult, TaskHandle
export AgentDefinition, Conversation, SessionRuntime, ModelRequest
export Answer, ActionDecision, RunJulia, Failure

public respond, execute!, initialize_executor!, fork_executor, close_executor!, JuliaExecutor
public PendingInput, PendingInputs, queue_input!, set_input_queue_mode!, pending_input_snapshot, peek_pending_inputs, clear_pending_inputs!, submit_queued_turn!
public InlineText, InlineImage, InlineContentMetadata, InlineContentFailure, inline_image, inline_message, message_inline_content, native_message_content
public ModelImagePolicy, ModelImagePolicyFailure, model_image_policy, with_model_image_policy, project_model_images, model_image_payload
public response_reply, response_usage, emit!, cancelled, remaining_time, cancellation_event
public register_cancellation!, unregister_cancellation!
public current_execution_context
public append_message!, clear_history!, replace_message!, history_revision, history_snapshot, message_result
public default_kernel, CodeModePolicy, prompt_instructions, UsageReport, normalize_usage
public reply_schema, reply_format, decode_reply
public ProviderDescriptor, register_provider!, unregister_provider!, provider_descriptors, provider_descriptor
public ProviderRegistry, builtin_provider_registry
public ModelSpec, ProviderFactory, ModelProvider, respond_model, select_model, provider_models, provider_model
public APIKeyAuthMethod, APIKeyValidation, api_key_provider_descriptor, submit_api_key!, api_key_request_status
public HTTPModelBackend, OpenAIChatProtocol, AnthropicMessagesProtocol, StreamedCompletion
public FileModelStore, restore_model_catalogs!, MemoryModelStore, read_model_catalog, write_model_catalog!, delete_model_catalog!
public select_provider_model!
public model_context_window, model_output_limit, refresh_pi_model_catalog!
public CompactionSettings, resolved_compaction, compact!, submit_compaction!, context_messages, compaction_snapshot
public provider_id, provider_from_name, configured_provider, provider_name, provider_detail, usage_label, main
public ProviderIdentity, provider_identity
public component_snapshot, provider_selection_snapshot, provider_settings_snapshot, select_provider!
public ResponseProgress, protocol_progress, emit_protocol_progress!, operation_id
public usage_snapshot, model_request, own_resource!
public working_directory, set_working_directory!, workspace_path
public AgentDecision, agent_decision, action_content, action_kind, action_payload
public BoundComponent, bind_component, bound_dependency, fork_kernel
public PluginSpec, PluginRegistry, PluginHost, PluginContext, Profile, ProfileStore, compose_profiles, save_profile!, load_profile, profile_names, ProfilePlan, profile_plan
public Skill, SkillRegistry, SkillRegistration, FilesystemSkillRegistry, register_skill!, unregister_skill!, skill_catalog, skill_catalog_snapshot, load_skill, skill_registry_plugin, filesystem_skill_plugin, skill_request
public register_plugin!, unregister_plugin!, activate!, deactivate!, provide!, effect!, service, plugin_snapshot
public ExtensionScope, on!, dispatch_event!, event_scope_plugin
public ToolSpec, ToolCall, ToolExecutor, ToolBatch, ToolSet, ToolActivationContext, resolve_tool_set, tool_activation, register_tool!, register_tool_guard!, restrict_tools!, tools_snapshot, tool, invoke_tool!, invoke_tool_batch!, tool_concurrency_safe
public CheckedJSONSchema, tool_argument_violations, tool_output_violations, tool_schema_definition, tool_output_text
public AbstractToolApprovalRequest, ToolApprovalRequest, tool_approval_reason, tool_approval_outcome
public ToolResultBlock, ToolResultText, ToolResultValue, tool_completion_decision, apply_tool_completion
public RpcError, RpcResult, JsonRpcPeer, request!, notify!, feed!, start!, drain!
public AbstractRuntimeBackend, JsonRpcRuntime, runtime_request!, runtime_notify!, start_runtime, finish_runtime!
public ProcessFeature, launch_feature, apply_entry_patches, compose_entry_layers
public runtime_transport_plugin, process_launcher_plugin
public SessionStore, save_session!, load_session, session_store_plugin, session_lineage, session_descendants, fork_session, session_summary, session_summaries
public TimelineIdentity, SessionTimeline, TimelineStore, parse_timeline_jsonl, timeline_from_rows, timeline_header, timeline_leaf, timeline_entries, timeline_entry, timeline_branch, timeline_tree, timeline_name, timeline_label, timeline_messages, timeline_append!, timeline_append_message!, timeline_append_custom!, timeline_name!, timeline_label!, timeline_append_compaction!, timeline_append_context_edit!, timeline_branch_summary!, timeline_branch!, timeline_fork, timeline_clone, timeline_export_jsonl, save_timeline!, load_timeline, delete_timeline!, list_timelines, import_timeline!, export_timeline!
public TimelineProjectedEntry, TimelineContextProjection, TimelineMessageMetadata, timeline_projection, timeline_context, timeline_llm_messages, timeline_runtime_mapping, timeline_runtime_messages, timeline_runtime_entry_ids, timeline_native_message, timeline_archive_message
public TimelineDisplayItem, TimelineDisplayProjection, TimelineDisplayRecord, TimelineDisplayTool, TimelineDisplayMetadata, timeline_display_projection, timeline_display_records, timeline_display_native_message, timeline_display_messages
public HistoryJournals, bind_history_journal!, unbind_history_journal!, history_journal_context
public archive_session!, unarchive_session!, session_archived
public pin_session!, unpin_session!, pinned_sessions, session_pinned
public SessionQuery, SessionSearchIndex, refresh_index!, session_query_plugin, search_history, session_names
public SessionTitleService, session_title, rename_session_title!, refresh_session_title!, session_title_plugin
public normalize_session_title, fallback_session_title
public session_markdown, session_markdown_entry
public SessionAPI, session_api_plugin, session_api_request!, session_api_peer, session_workspace_groups
public WorkspaceRegistry, workspace_registry_plugin, workspace_snapshot, workspace_changes
public register_workspace!, rename_workspace!, delete_workspace!, move_workspace!, move_workspace_session!, registered_workspace_groups
public start_web_server, web_server_plugin, web_url, web_launch_url

include("files/search_tool.jl")
include("kernel.jl")
include("agent.jl")
include("core/inline_content.jl")
include("core/plugins.jl")
include("core/skills.jl")
include("core/prompt_templates.jl")
include("core/filesystem_skills.jl")
include("text/word_segmentation.jl")
include("core/profile_store.jl")
include("core/profile_inspection.jl")
include("core/source_syntax.jl")
include("core/julia_source_highlighting.jl")
include("core/session_store.jl")
include("core/session_timeline.jl")
include("core/history_journal.jl")
include("core/session_pins.jl")
include("core/session_titles.jl")
include("core/session_query.jl")
include("core/workspace_registry.jl")
include("infrastructure/infrastructure.jl")
include("infrastructure/terminal_jobs.jl")
include("infrastructure/user_shell_output.jl")
include("infrastructure/user_shell_process.jl")
include("infrastructure/jsonrpc.jl")
include("core/session_markdown.jl")
include("core/session_api.jl")
include("core/tool_schemas.jl")
include("core/extensions.jl")
include("core/tool_batch.jl")
include("core/event_context.jl")
include("features/code_mode/streaming.jl")
include("runtime/backends.jl")
include("core/profile_patches.jl")
include("auth.jl")
include("providers.jl")
include("providers/inline_content_wire.jl")
include("application/model_configuration.jl")
include("application/provider_warning_facts.jl")
include("core/session_context.jl")
include("core/inline_content_archive.jl")
include("core/user_shell_records.jl")
include("core/session_display.jl")
include("core/session_statistics.jl")
include("core/session_cache_misses.jl")
include("core/release_changelog.jl")
include("core/startup_release_state.jl")
include("core/bug_report_bundle.jl")
include("core/compaction.jl")
include("core/inline_content_compaction.jl")
include("application/presentation.jl")

"""Create a session retaining the currently active plugin composition."""
Session(host::PluginHost; kwargs...) = Session(fork_kernel(host); owns_kernel=true, kwargs...)

"""Start an independently implemented Julia web frontend when its optional HTTP extension is installed."""
function start_web_server end
function web_server_plugin end
function web_url end
function web_launch_url end

"""Run an installed frontend."""
function main end

"""Return a greeting for `name`."""
greet(name::AbstractString) = "Hello, $(name)!"

end
