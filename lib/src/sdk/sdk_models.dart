import 'dart:async';

import '../core/app_config.dart';
import '../core/runtime_error.dart';
import '../mcp/mcp_manager.dart';
import '../providers/llm_provider.dart';
import '../services/security_guard.dart';
import '../services/telemetry.dart';
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

class ClartCodeToolContext {
  const ClartCodeToolContext({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.turn,
    this.model,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final int turn;
  final String? model;
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
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final List<String> availableTools;
  final List<ClartCodeToolDefinition> toolDefinitions;
  final String? model;
}

class ClartCodeSessionEndEvent {
  const ClartCodeSessionEndEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.prompt,
    required this.result,
    this.model,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final ClartCodePromptResult result;
  final String? model;
}

class ClartCodeStopEvent {
  const ClartCodeStopEvent({
    required this.sessionId,
    required this.cwd,
    required this.provider,
    required this.reason,
    this.model,
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String reason;
  final String? model;
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
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final int turn;
  final List<String> availableTools;
  final String? model;
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
}

enum ClartCodeToolPermissionSource { resolveToolPermission, canUseTool }

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
  });

  final String sessionId;
  final String cwd;
  final ProviderKind provider;
  final String prompt;
  final ClartCodePromptResult result;
  final String reason;
  final String? model;
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
  });

  final String? registryPath;
  final List<String>? serverNames;
  final bool includeResourceTools;
}

class ClartCodeAgentOptions {
  const ClartCodeAgentOptions({
    this.provider = ProviderKind.local,
    this.model,
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
    this.permissionPolicy = const ToolPermissionPolicy(),
    this.telemetry = const TelemetryService(),
    this.securityGuard = const SecurityGuard(),
    this.canUseTool,
    this.resolveToolPermission,
    this.hooks = const ClartCodeAgentHooks(),
    this.mcp,
    this.mcpManagerOverride,
  });

  final ProviderKind provider;
  final String? model;
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
  final ToolPermissionPolicy permissionPolicy;
  final TelemetryService telemetry;
  final SecurityGuard securityGuard;
  final ClartCodeCanUseTool? canUseTool;
  final ClartCodeResolveToolPermission? resolveToolPermission;
  final ClartCodeAgentHooks hooks;
  final ClartCodeMcpOptions? mcp;
  final McpManager? mcpManagerOverride;

  ClartCodeAgentOptions copyWith({
    ProviderKind? provider,
    String? model,
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
    ToolPermissionPolicy? permissionPolicy,
    TelemetryService? telemetry,
    SecurityGuard? securityGuard,
    ClartCodeCanUseTool? canUseTool,
    ClartCodeResolveToolPermission? resolveToolPermission,
    ClartCodeAgentHooks? hooks,
    ClartCodeMcpOptions? mcp,
    McpManager? mcpManagerOverride,
  }) {
    return ClartCodeAgentOptions(
      provider: provider ?? this.provider,
      model: model ?? this.model,
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
      permissionPolicy: permissionPolicy ?? this.permissionPolicy,
      telemetry: telemetry ?? this.telemetry,
      securityGuard: securityGuard ?? this.securityGuard,
      canUseTool: canUseTool ?? this.canUseTool,
      resolveToolPermission:
          resolveToolPermission ?? this.resolveToolPermission,
      hooks: hooks ?? this.hooks,
      mcp: mcp ?? this.mcp,
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
  });

  final String type;
  final String sessionId;
  final String? subtype;
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
    );
  }

  Map<String, Object?> toJson() {
    return {
      'type': type,
      'subtype': subtype,
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
  });

  final String sessionId;
  final String text;
  final int turns;
  final bool isError;
  final List<ClartCodeSdkMessage> messages;
  final String? model;
  final RuntimeError? error;
  final int? durationMs;
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
