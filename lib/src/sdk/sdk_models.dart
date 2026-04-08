import 'dart:async';

import '../core/app_config.dart';
import '../core/models.dart';
import '../core/transcript.dart';
import '../core/runtime_error.dart';
import '../agents/agent_registry.dart';
import '../mcp/mcp_manager.dart';
import '../mcp/sdk_mcp_server.dart';
import '../providers/llm_provider.dart';
import '../services/security_guard.dart';
import '../services/telemetry.dart';
import '../skills/skill_models.dart';
import '../skills/skill_registry.dart';
import '../tools/tool_executor.dart';
import '../tools/tool_models.dart';
import '../tools/tool_permissions.dart';

typedef ClartCodeCanUseTool = FutureOr<bool> Function(
  ClartCodeToolCall toolCall,
  ClartCodeToolContext context,
);

typedef ClartCodeResolveToolPermission
    = FutureOr<ClartCodeToolPermissionOutcome> Function(
  ClartCodeToolCall toolCall,
  ClartCodeToolContext context,
);

typedef ClartCodeSessionStartHook = FutureOr<void> Function(
    ClartCodeSessionStartEvent event);

typedef ClartCodeSessionEndHook = FutureOr<void> Function(
    ClartCodeSessionEndEvent event);

typedef ClartCodeStopHook = FutureOr<void> Function(ClartCodeStopEvent event);

typedef ClartCodeModelTurnStartHook = FutureOr<void> Function(
  ClartCodeModelTurnStartEvent event,
);

typedef ClartCodeModelTurnEndHook = FutureOr<void> Function(
  ClartCodeModelTurnEndEvent event,
);

typedef ClartCodePreToolUseHook = FutureOr<void> Function(
    ClartCodeToolEvent event);

typedef ClartCodePostToolUseHook = FutureOr<void> Function(
    ClartCodeToolResultEvent event);

typedef ClartCodePostToolUseFailureHook = FutureOr<void> Function(
    ClartCodeToolResultEvent event);

typedef ClartCodeToolPermissionDecisionHook = FutureOr<void> Function(
  ClartCodeToolPermissionEvent event,
);

typedef ClartCodeCancelledTerminalHook = FutureOr<void> Function(
  ClartCodeCancelledTerminalEvent event,
);

typedef ClartCodeSubagentStartHook = FutureOr<void> Function(
  ClartCodeSubagentStartEvent event,
);

typedef ClartCodeSubagentEndHook = FutureOr<void> Function(
  ClartCodeSubagentEndEvent event,
);

typedef ClartCodeSkillActivationHook = FutureOr<void> Function(
  ClartCodeSkillActivationEvent event,
);

typedef ClartCodeSkillEndHook = FutureOr<void> Function(
  ClartCodeSkillEndEvent event,
);

class ClartCodeToolContext {
  const ClartCodeToolContext({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.turn,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final int turn;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeToolEvent {
  const ClartCodeToolEvent({
    required this.context,
    required this.toolCall,
  });

  final ClartCodeToolContext context;
  final ClartCodeToolCall toolCall;
}

class ClartCodeToolResultEvent extends ClartCodeToolEvent {
  const ClartCodeToolResultEvent({
    required super.context,
    required super.toolCall,
    required this.toolResult,
  });

  final ClartCodeToolResult toolResult;
}

class ClartCodeSessionStartEvent {
  const ClartCodeSessionStartEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.availableTools,
    required this.toolDefinitions,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final List<String> availableTools;
  final List<ClartCodeToolDefinition> toolDefinitions;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeSessionEndEvent {
  const ClartCodeSessionEndEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.result,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final ClartCodePromptResult result;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeStopEvent {
  const ClartCodeStopEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.reason,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String reason;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeModelTurnStartEvent {
  const ClartCodeModelTurnStartEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.turn,
    required this.availableTools,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final int turn;
  final List<String> availableTools;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeModelTurnEndEvent {
  const ClartCodeModelTurnEndEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.turn,
    required this.rawOutput,
    required this.output,
    required this.toolCalls,
    required this.durationMs,
    this.model,
    this.error,
    this.usage,
    this.costUsd,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final int turn;
  final String rawOutput;
  final String output;
  final List<ClartCodeToolCall> toolCalls;
  final int durationMs;
  final String? model;
  final RuntimeError? error;
  final QueryUsage? usage;
  final double? costUsd;
  final String? parentSessionId;
}

enum ClartCodeToolPermissionSource {
  skill,
  resolveToolPermission,
  canUseTool,
}

class ClartCodeToolPermissionEvent extends ClartCodeToolEvent {
  const ClartCodeToolPermissionEvent({
    required super.context,
    required super.toolCall,
    required this.decision,
    required this.source,
    this.message,
    this.updatedInput,
  });

  final ClartCodeToolPermissionDecision decision;
  final ClartCodeToolPermissionSource source;
  final String? message;
  final Map<String, Object?>? updatedInput;
}

class ClartCodeCancelledTerminalEvent {
  const ClartCodeCancelledTerminalEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.result,
    required this.reason,
    this.model,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final ClartCodePromptResult result;
  final String reason;
  final String? model;
  final String? parentSessionId;
}

class ClartCodeSubagentStartEvent {
  const ClartCodeSubagentStartEvent({
    required this.parentSessionId,
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    this.name,
    this.model,
  });

  final String parentSessionId;
  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final String? name;
  final String? model;
}

class ClartCodeSubagentEndEvent {
  const ClartCodeSubagentEndEvent({
    required this.parentSessionId,
    required this.result,
    required this.provider,
    this.name,
    this.reason,
  });

  final String parentSessionId;
  final ClartCodeSubagentResult result;
  final ProviderKind provider;
  final String? name;
  final String? reason;
}

class ClartCodeSkillActivationEvent {
  const ClartCodeSkillActivationEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.turn,
    required this.name,
    required this.runtimeScope,
    required this.cleanupBoundary,
    this.model,
    this.effort,
    this.allowedTools,
    this.disallowedTools,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final int turn;
  final String name;
  final String runtimeScope;
  final String cleanupBoundary;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final List<String>? allowedTools;
  final List<String>? disallowedTools;
  final String? parentSessionId;
}

class ClartCodeSkillEndEvent {
  const ClartCodeSkillEndEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.name,
    required this.activatedTurn,
    required this.endedTurn,
    required this.reason,
    required this.runtimeScope,
    required this.cleanupBoundary,
    this.model,
    this.effort,
    this.allowedTools,
    this.disallowedTools,
    this.parentSessionId,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final String name;
  final int activatedTurn;
  final int endedTurn;
  final String reason;
  final String runtimeScope;
  final String cleanupBoundary;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final List<String>? allowedTools;
  final List<String>? disallowedTools;
  final String? parentSessionId;
}

class ClartCodeAgentHooks {
  const ClartCodeAgentHooks({
    this.onSessionStart,
    this.onSessionEnd,
    this.onStop,
    this.onModelTurnStart,
    this.onModelTurnEnd,
    this.onPreToolUse,
    this.onPostToolUse,
    this.onPostToolUseFailure,
    this.onToolPermissionDecision,
    this.onCancelledTerminal,
    this.onSubagentStart,
    this.onSubagentEnd,
    this.onSkillActivation,
    this.onSkillEnd,
  });

  final ClartCodeSessionStartHook? onSessionStart;
  final ClartCodeSessionEndHook? onSessionEnd;
  final ClartCodeStopHook? onStop;
  final ClartCodeModelTurnStartHook? onModelTurnStart;
  final ClartCodeModelTurnEndHook? onModelTurnEnd;
  final ClartCodePreToolUseHook? onPreToolUse;
  final ClartCodePostToolUseHook? onPostToolUse;
  final ClartCodePostToolUseFailureHook? onPostToolUseFailure;
  final ClartCodeToolPermissionDecisionHook? onToolPermissionDecision;
  final ClartCodeCancelledTerminalHook? onCancelledTerminal;
  final ClartCodeSubagentStartHook? onSubagentStart;
  final ClartCodeSubagentEndHook? onSubagentEnd;
  final ClartCodeSkillActivationHook? onSkillActivation;
  final ClartCodeSkillEndHook? onSkillEnd;
}

class ClartCodeRequestOptions {
  const ClartCodeRequestOptions({
    this.effort,
    this.systemPrompt,
    this.appendSystemPrompt,
    this.maxTokens,
    this.maxBudgetUsd,
    this.thinking,
    this.jsonSchema,
    this.outputFormat,
    this.includePartialMessages,
    this.includeObservabilityMessages,
  });

  final ClartCodeReasoningEffort? effort;
  final String? systemPrompt;
  final String? appendSystemPrompt;
  final int? maxTokens;
  final double? maxBudgetUsd;
  final ClartCodeThinkingConfig? thinking;
  final ClartCodeJsonSchema? jsonSchema;
  final ClartCodeOutputFormat? outputFormat;
  final bool? includePartialMessages;
  final bool? includeObservabilityMessages;

  ClartCodeRequestOptions copyWith({
    ClartCodeReasoningEffort? effort,
    String? systemPrompt,
    String? appendSystemPrompt,
    int? maxTokens,
    double? maxBudgetUsd,
    ClartCodeThinkingConfig? thinking,
    ClartCodeJsonSchema? jsonSchema,
    ClartCodeOutputFormat? outputFormat,
    bool? includePartialMessages,
    bool? includeObservabilityMessages,
  }) {
    return ClartCodeRequestOptions(
      effort: effort ?? this.effort,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      appendSystemPrompt: appendSystemPrompt ?? this.appendSystemPrompt,
      maxTokens: maxTokens ?? this.maxTokens,
      maxBudgetUsd: maxBudgetUsd ?? this.maxBudgetUsd,
      thinking: thinking ?? this.thinking,
      jsonSchema: jsonSchema ?? this.jsonSchema,
      outputFormat: outputFormat ?? this.outputFormat,
      includePartialMessages:
          includePartialMessages ?? this.includePartialMessages,
      includeObservabilityMessages:
          includeObservabilityMessages ?? this.includeObservabilityMessages,
    );
  }
}

enum ClartCodeToolPermissionDecision { allow, deny }

class ClartCodeToolPermissionOutcome {
  const ClartCodeToolPermissionOutcome._({
    required this.decision,
    this.message,
    this.updatedInput,
  });

  factory ClartCodeToolPermissionOutcome.allow({
    String? message,
    Map<String, Object?>? updatedInput,
  }) {
    return ClartCodeToolPermissionOutcome._(
      decision: ClartCodeToolPermissionDecision.allow,
      message: message,
      updatedInput: updatedInput == null
          ? null
          : Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(updatedInput),
            ),
    );
  }

  factory ClartCodeToolPermissionOutcome.deny({
    String? message,
  }) {
    return ClartCodeToolPermissionOutcome._(
      decision: ClartCodeToolPermissionDecision.deny,
      message: message,
    );
  }

  final ClartCodeToolPermissionDecision decision;
  final String? message;
  final Map<String, Object?>? updatedInput;

  bool get isAllowed => decision == ClartCodeToolPermissionDecision.allow;
}

class ClartCodeMcpOptions {
  const ClartCodeMcpOptions({
    this.registryPath,
    this.serverNames,
    this.includeResourceTools = true,
    this.sdkServers = const [],
  });

  final String? registryPath;
  final List<String>? serverNames;
  final bool includeResourceTools;
  final List<McpSdkServerConfig> sdkServers;
}

class ClartCodeSkillsOptions {
  const ClartCodeSkillsOptions({
    this.registry,
    this.skills = const [],
    this.directories = const [],
    this.includeBundledSkills = true,
    this.enableTool = true,
  });

  final ClartCodeSkillRegistry? registry;
  final List<ClartCodeSkillDefinition> skills;
  final List<String> directories;
  final bool includeBundledSkills;
  final bool enableTool;
}

class ClartCodeAgentDefinition {
  const ClartCodeAgentDefinition({
    required this.name,
    required this.description,
    required this.prompt,
    this.allowedTools,
    this.disallowedTools = const [],
    this.model,
    this.effort,
    this.inheritMcp = true,
    this.cascadeAssistantDeltas = false,
  });

  final String name;
  final String description;
  final String prompt;
  final List<String>? allowedTools;
  final List<String> disallowedTools;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final bool inheritMcp;
  final bool cascadeAssistantDeltas;

  Map<String, Object?> toSummaryJson() {
    return {
      'name': name,
      'description': description,
      'prompt': prompt,
      if (allowedTools != null) 'allowedTools': allowedTools,
      'disallowedTools': disallowedTools,
      'model': model,
      'effort': effort?.name,
      'inheritMcp': inheritMcp,
      'cascadeAssistantDeltas': cascadeAssistantDeltas,
    };
  }
}

class ClartCodeAgentsOptions {
  const ClartCodeAgentsOptions({
    this.registry,
    this.agents = const [],
    this.directories = const [],
    this.enableTool = true,
  });

  final ClartCodeAgentRegistry? registry;
  final List<ClartCodeAgentDefinition> agents;
  final List<String> directories;
  final bool enableTool;
}

class ClartCodeSubagentOptions {
  const ClartCodeSubagentOptions({
    this.name,
    this.model,
    this.effort,
    this.allowedTools,
    this.disallowedTools,
    this.promptPrefix,
    this.inheritMcp = true,
    this.inheritAgents = false,
    this.inheritSkills = false,
    this.inheritHooks = false,
    this.cascadeAssistantDeltas = false,
  });

  final String? name;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final List<String>? allowedTools;
  final List<String>? disallowedTools;
  final String? promptPrefix;
  final bool inheritMcp;
  final bool inheritAgents;
  final bool inheritSkills;
  final bool inheritHooks;
  final bool cascadeAssistantDeltas;
}

class ClartCodeAgentOptions {
  const ClartCodeAgentOptions({
    this.provider = ProviderKind.local,
    this.model,
    this.effort,
    this.claudeApiKey,
    this.claudeBaseUrl,
    this.openAiApiKey,
    this.openAiBaseUrl,
    this.cwd,
    this.sessionId,
    this.resumeSessionId,
    this.persistSession = true,
    this.providerOverride,
    this.toolExecutor,
    this.tools,
    this.allowedTools,
    this.disallowedTools,
    this.permissionMode,
    this.maxTurns = 8,
    this.systemPrompt,
    this.appendSystemPrompt,
    this.maxTokens,
    this.maxBudgetUsd,
    this.thinking,
    this.jsonSchema,
    this.outputFormat,
    this.includePartialMessages = true,
    this.includeObservabilityMessages = false,
    this.permissionPolicy = const ToolPermissionPolicy(),
    this.telemetry = const TelemetryService(),
    this.securityGuard = const SecurityGuard(),
    this.canUseTool,
    this.resolveToolPermission,
    this.hooks = const ClartCodeAgentHooks(),
    this.mcp,
    this.agents,
    this.skills,
    this.mcpManagerOverride,
  });

  final ProviderKind provider;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final String? claudeApiKey;
  final String? claudeBaseUrl;
  final String? openAiApiKey;
  final String? openAiBaseUrl;
  final String? cwd;
  final String? sessionId;
  final String? resumeSessionId;
  final bool persistSession;
  final LlmProvider? providerOverride;
  final ToolExecutor? toolExecutor;
  final List<Tool>? tools;
  final List<String>? allowedTools;
  final List<String>? disallowedTools;
  final ToolPermissionMode? permissionMode;
  final int maxTurns;
  final String? systemPrompt;
  final String? appendSystemPrompt;
  final int? maxTokens;
  final double? maxBudgetUsd;
  final ClartCodeThinkingConfig? thinking;
  final ClartCodeJsonSchema? jsonSchema;
  final ClartCodeOutputFormat? outputFormat;
  final bool includePartialMessages;
  final bool includeObservabilityMessages;
  final ToolPermissionPolicy permissionPolicy;
  final TelemetryService telemetry;
  final SecurityGuard securityGuard;
  final ClartCodeCanUseTool? canUseTool;
  final ClartCodeResolveToolPermission? resolveToolPermission;
  final ClartCodeAgentHooks hooks;
  final ClartCodeMcpOptions? mcp;
  final ClartCodeAgentsOptions? agents;
  final ClartCodeSkillsOptions? skills;
  final McpManager? mcpManagerOverride;

  ClartCodeAgentOptions copyWith({
    ProviderKind? provider,
    String? model,
    ClartCodeReasoningEffort? effort,
    String? claudeApiKey,
    String? claudeBaseUrl,
    String? openAiApiKey,
    String? openAiBaseUrl,
    String? cwd,
    String? sessionId,
    String? resumeSessionId,
    bool? persistSession,
    LlmProvider? providerOverride,
    ToolExecutor? toolExecutor,
    List<Tool>? tools,
    List<String>? allowedTools,
    List<String>? disallowedTools,
    ToolPermissionMode? permissionMode,
    int? maxTurns,
    String? systemPrompt,
    String? appendSystemPrompt,
    int? maxTokens,
    double? maxBudgetUsd,
    ClartCodeThinkingConfig? thinking,
    ClartCodeJsonSchema? jsonSchema,
    ClartCodeOutputFormat? outputFormat,
    bool? includePartialMessages,
    bool? includeObservabilityMessages,
    ToolPermissionPolicy? permissionPolicy,
    TelemetryService? telemetry,
    SecurityGuard? securityGuard,
    ClartCodeCanUseTool? canUseTool,
    ClartCodeResolveToolPermission? resolveToolPermission,
    ClartCodeAgentHooks? hooks,
    ClartCodeMcpOptions? mcp,
    ClartCodeAgentsOptions? agents,
    ClartCodeSkillsOptions? skills,
    McpManager? mcpManagerOverride,
  }) {
    return ClartCodeAgentOptions(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      effort: effort ?? this.effort,
      claudeApiKey: claudeApiKey ?? this.claudeApiKey,
      claudeBaseUrl: claudeBaseUrl ?? this.claudeBaseUrl,
      openAiApiKey: openAiApiKey ?? this.openAiApiKey,
      openAiBaseUrl: openAiBaseUrl ?? this.openAiBaseUrl,
      cwd: cwd ?? this.cwd,
      sessionId: sessionId ?? this.sessionId,
      resumeSessionId: resumeSessionId ?? this.resumeSessionId,
      persistSession: persistSession ?? this.persistSession,
      providerOverride: providerOverride ?? this.providerOverride,
      toolExecutor: toolExecutor ?? this.toolExecutor,
      tools: tools ?? this.tools,
      allowedTools: allowedTools ?? this.allowedTools,
      disallowedTools: disallowedTools ?? this.disallowedTools,
      permissionMode: permissionMode ?? this.permissionMode,
      maxTurns: maxTurns ?? this.maxTurns,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      appendSystemPrompt: appendSystemPrompt ?? this.appendSystemPrompt,
      maxTokens: maxTokens ?? this.maxTokens,
      maxBudgetUsd: maxBudgetUsd ?? this.maxBudgetUsd,
      thinking: thinking ?? this.thinking,
      jsonSchema: jsonSchema ?? this.jsonSchema,
      outputFormat: outputFormat ?? this.outputFormat,
      includePartialMessages:
          includePartialMessages ?? this.includePartialMessages,
      includeObservabilityMessages:
          includeObservabilityMessages ?? this.includeObservabilityMessages,
      permissionPolicy: permissionPolicy ?? this.permissionPolicy,
      telemetry: telemetry ?? this.telemetry,
      securityGuard: securityGuard ?? this.securityGuard,
      canUseTool: canUseTool ?? this.canUseTool,
      resolveToolPermission:
          resolveToolPermission ?? this.resolveToolPermission,
      hooks: hooks ?? this.hooks,
      mcp: mcp ?? this.mcp,
      agents: agents ?? this.agents,
      skills: skills ?? this.skills,
      mcpManagerOverride: mcpManagerOverride ?? this.mcpManagerOverride,
    );
  }
}

class ClartCodeToolDefinition {
  const ClartCodeToolDefinition({
    required this.name,
    required this.description,
    required this.executionHint,
    this.title,
    this.inputSchema,
    this.annotations,
  });

  final String name;
  final String description;
  final String executionHint;
  final String? title;
  final Map<String, Object?>? inputSchema;
  final Map<String, Object?>? annotations;

  factory ClartCodeToolDefinition.fromTool(Tool tool) {
    return ClartCodeToolDefinition(
      name: tool.name,
      description: tool.description,
      executionHint: tool.executionHint.name,
      title: tool.title,
      inputSchema: tool.inputSchema == null
          ? null
          : Map<String, Object?>.from(tool.inputSchema!),
      annotations: tool.annotations == null
          ? null
          : Map<String, Object?>.from(tool.annotations!),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'description': description,
      'executionHint': executionHint,
      'title': title,
      'inputSchema': inputSchema,
      'annotations': annotations,
    };
  }
}

class ClartCodeToolCall {
  const ClartCodeToolCall({
    required this.id,
    required this.name,
    this.input = const {},
  });

  final String id;
  final String name;
  final Map<String, Object?> input;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'input': input,
    };
  }
}

class ClartCodeToolResult {
  const ClartCodeToolResult({
    required this.callId,
    required this.tool,
    required this.ok,
    required this.output,
    this.errorCode,
    this.errorMessage,
    this.metadata,
  });

  final String callId;
  final String tool;
  final bool ok;
  final String output;
  final String? errorCode;
  final String? errorMessage;
  final Map<String, Object?>? metadata;

  Map<String, Object?> toJson() {
    return {
      'callId': callId,
      'tool': tool,
      'ok': ok,
      'output': output,
      'errorCode': errorCode,
      'errorMessage': errorMessage,
      if (metadata != null) 'metadata': metadata,
    };
  }
}

class ClartCodeSdkMessage {
  const ClartCodeSdkMessage({
    required this.type,
    required this.sessionId,
    this.subtype,
    this.terminalSubtype,
    this.text,
    this.delta,
    this.model,
    this.turn,
    this.turns,
    this.isError,
    this.error,
    this.cwd,
    this.tools,
    this.toolDefinitions,
    this.toolCall,
    this.toolResult,
    this.durationMs,
    this.usage,
    this.costUsd,
    this.modelUsage,
    this.parentSessionId,
    this.subagentName,
    this.skillName,
    this.event,
    this.status,
    this.rateLimitInfo,
    this.compactMetadata,
  });

  final String type;
  final String sessionId;
  final String? subtype;
  final String? terminalSubtype;
  final String? text;
  final String? delta;
  final String? model;
  final int? turn;
  final int? turns;
  final bool? isError;
  final RuntimeError? error;
  final String? cwd;
  final List<String>? tools;
  final List<ClartCodeToolDefinition>? toolDefinitions;
  final ClartCodeToolCall? toolCall;
  final ClartCodeToolResult? toolResult;
  final int? durationMs;
  final QueryUsage? usage;
  final double? costUsd;
  final List<QueryModelUsage>? modelUsage;
  final String? parentSessionId;
  final String? subagentName;
  final String? skillName;
  final Map<String, Object?>? event;
  final String? status;
  final QueryRateLimitInfo? rateLimitInfo;
  final Map<String, Object?>? compactMetadata;

  factory ClartCodeSdkMessage.systemInit({
    required String sessionId,
    required String cwd,
    required String? model,
    required List<String> tools,
    required List<ClartCodeToolDefinition> toolDefinitions,
  }) {
    return ClartCodeSdkMessage(
      type: 'system',
      subtype: 'init',
      sessionId: sessionId,
      cwd: cwd,
      model: model,
      tools: List<String>.unmodifiable(tools),
      toolDefinitions: List<ClartCodeToolDefinition>.unmodifiable(
        toolDefinitions,
      ),
    );
  }

  factory ClartCodeSdkMessage.assistantDelta({
    required String sessionId,
    required String delta,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'assistant_delta',
      sessionId: sessionId,
      delta: delta,
      model: model,
      turn: turn,
    );
  }

  factory ClartCodeSdkMessage.assistant({
    required String sessionId,
    required String text,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'assistant',
      sessionId: sessionId,
      text: text,
      model: model,
      turn: turn,
    );
  }

  factory ClartCodeSdkMessage.streamEvent({
    required String sessionId,
    required Map<String, Object?> event,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'stream_event',
      sessionId: sessionId,
      event: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(event),
      ),
      model: model,
      turn: turn,
    );
  }

  factory ClartCodeSdkMessage.toolCall({
    required String sessionId,
    required ClartCodeToolCall toolCall,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'tool_call',
      sessionId: sessionId,
      model: model,
      turn: turn,
      toolCall: toolCall,
    );
  }

  factory ClartCodeSdkMessage.toolResult({
    required String sessionId,
    required ClartCodeToolResult toolResult,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'tool_result',
      sessionId: sessionId,
      model: model,
      turn: turn,
      toolResult: toolResult,
    );
  }

  factory ClartCodeSdkMessage.result({
    required String sessionId,
    required String subtype,
    required String text,
    required bool isError,
    String? model,
    int turns = 1,
    RuntimeError? error,
    int? durationMs,
    QueryUsage? usage,
    double? costUsd,
    List<QueryModelUsage>? modelUsage,
  }) {
    return ClartCodeSdkMessage(
      type: 'result',
      subtype: subtype,
      sessionId: sessionId,
      text: text,
      model: model,
      turns: turns,
      isError: isError,
      error: error,
      durationMs: durationMs,
      usage: usage,
      costUsd: costUsd,
      modelUsage: modelUsage == null
          ? null
          : List<QueryModelUsage>.unmodifiable(modelUsage),
    );
  }

  factory ClartCodeSdkMessage.rateLimitEvent({
    required String sessionId,
    required QueryRateLimitInfo rateLimitInfo,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'rate_limit_event',
      sessionId: sessionId,
      model: model,
      turn: turn,
      rateLimitInfo: rateLimitInfo,
    );
  }

  factory ClartCodeSdkMessage.systemStatus({
    required String sessionId,
    String? status,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'system',
      subtype: 'status',
      sessionId: sessionId,
      status: status,
      model: model,
      turn: turn,
    );
  }

  factory ClartCodeSdkMessage.compactBoundary({
    required String sessionId,
    Map<String, Object?>? compactMetadata,
    String? model,
    int? turn,
  }) {
    return ClartCodeSdkMessage(
      type: 'system',
      subtype: 'compact_boundary',
      sessionId: sessionId,
      compactMetadata: compactMetadata == null
          ? null
          : Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(compactMetadata),
            ),
      model: model,
      turn: turn,
    );
  }

  factory ClartCodeSdkMessage.subagent({
    required String sessionId,
    required String parentSessionId,
    required String subtype,
    String? terminalSubtype,
    String? text,
    String? model,
    String? subagentName,
    int? turns,
    bool? isError,
    RuntimeError? error,
    int? durationMs,
  }) {
    return ClartCodeSdkMessage(
      type: 'subagent',
      subtype: subtype,
      terminalSubtype: terminalSubtype,
      sessionId: sessionId,
      text: text,
      model: model,
      turns: turns,
      isError: isError,
      error: error,
      durationMs: durationMs,
      parentSessionId: parentSessionId,
      subagentName: subagentName,
    );
  }

  factory ClartCodeSdkMessage.skill({
    required String sessionId,
    required String subtype,
    required String skillName,
    String? terminalSubtype,
    String? text,
    String? model,
    int? turn,
    bool? isError,
    RuntimeError? error,
    int? durationMs,
  }) {
    // Dart-only synthetic lifecycle surface for inline skills. Keep this
    // intentionally narrower than the TS SDK base stream protocol.
    return ClartCodeSdkMessage(
      type: 'skill',
      subtype: subtype,
      terminalSubtype: terminalSubtype,
      sessionId: sessionId,
      text: text,
      model: model,
      turn: turn,
      isError: isError,
      error: error,
      durationMs: durationMs,
      skillName: skillName,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'type': type,
      'subtype': subtype,
      'terminalSubtype': terminalSubtype,
      'sessionId': sessionId,
      'text': text,
      'delta': delta,
      'model': model,
      'turn': turn,
      'turns': turns,
      'isError': isError,
      'error': error?.toJson(),
      'cwd': cwd,
      'tools': tools,
      'toolDefinitions': toolDefinitions?.map((tool) => tool.toJson()).toList(),
      'toolCall': toolCall?.toJson(),
      'toolResult': toolResult?.toJson(),
      'durationMs': durationMs,
      'usage': usage?.toJson(),
      'costUsd': costUsd,
      'modelUsage': modelUsage?.map((item) => item.toJson()).toList(),
      'parentSessionId': parentSessionId,
      'subagentName': subagentName,
      'skillName': skillName,
      'event': event,
      'status': status,
      'rateLimitInfo': rateLimitInfo?.toJson(),
      'compactMetadata': compactMetadata,
    };
  }
}

class ClartCodePromptResult {
  const ClartCodePromptResult({
    required this.sessionId,
    required this.text,
    required this.turns,
    required this.isError,
    required this.messages,
    this.model,
    this.error,
    this.durationMs,
    this.usage,
    this.costUsd,
    this.modelUsage,
  });

  final String sessionId;
  final String text;
  final int turns;
  final bool isError;
  final List<ClartCodeSdkMessage> messages;
  final String? model;
  final RuntimeError? error;
  final int? durationMs;
  final QueryUsage? usage;
  final double? costUsd;
  final List<QueryModelUsage>? modelUsage;
}

class ClartCodeSubagentResult {
  const ClartCodeSubagentResult({
    required this.parentSessionId,
    required this.sessionId,
    required this.cwd,
    required this.prompt,
    required this.text,
    required this.turns,
    required this.isError,
    required this.messages,
    required this.cascadedMessages,
    required this.transcriptMessages,
    this.name,
    this.model,
    this.error,
    this.durationMs,
    this.usage,
    this.costUsd,
    this.modelUsage,
  });

  final String parentSessionId;
  final String sessionId;
  final String cwd;
  final String prompt;
  final String text;
  final int turns;
  final bool isError;
  final List<ClartCodeSdkMessage> messages;
  final List<ClartCodeSdkMessage> cascadedMessages;
  final List<TranscriptMessage> transcriptMessages;
  final String? name;
  final String? model;
  final RuntimeError? error;
  final int? durationMs;
  final QueryUsage? usage;
  final double? costUsd;
  final List<QueryModelUsage>? modelUsage;
}

@Deprecated('Use ClartCodeAgentOptions instead.')
typedef ClatCodeAgentOptions = ClartCodeAgentOptions;

@Deprecated('Use ClartCodeToolDefinition instead.')
typedef ClatCodeToolDefinition = ClartCodeToolDefinition;

@Deprecated('Use ClartCodeToolCall instead.')
typedef ClatCodeToolCall = ClartCodeToolCall;

@Deprecated('Use ClartCodeToolResult instead.')
typedef ClatCodeToolResult = ClartCodeToolResult;

@Deprecated('Use ClartCodeSdkMessage instead.')
typedef ClatCodeSdkMessage = ClartCodeSdkMessage;

@Deprecated('Use ClartCodePromptResult instead.')
typedef ClatCodePromptResult = ClartCodePromptResult;
