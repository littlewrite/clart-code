import 'dart:async';

import 'runtime_error.dart';

enum MessageRole { system, user, assistant, tool }

enum ClartCodeReasoningEffort { low, medium, high, max }

enum ClartCodeOutputFormatType { text, jsonObject }

ClartCodeReasoningEffort? parseClartCodeReasoningEffort(Object? value) {
  if (value == null) {
    return null;
  }
  final normalized = value.toString().trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  for (final effort in ClartCodeReasoningEffort.values) {
    if (effort.name == normalized) {
      return effort;
    }
  }
  return null;
}

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
  });

  final MessageRole role;
  final String text;
}

class ClartCodeThinkingConfig {
  const ClartCodeThinkingConfig._({
    required this.type,
    this.budgetTokens,
  });

  const ClartCodeThinkingConfig.disabled() : this._(type: 'disabled');

  const ClartCodeThinkingConfig.enabled({
    required int budgetTokens,
  }) : this._(
          type: 'enabled',
          budgetTokens: budgetTokens,
        );

  final String type;
  final int? budgetTokens;

  bool get isEnabled => type == 'enabled';

  Map<String, Object?> toJson() {
    return {
      'type': type,
      if (budgetTokens != null) 'budget_tokens': budgetTokens,
    };
  }
}

class ClartCodeJsonSchema {
  const ClartCodeJsonSchema({
    required this.name,
    required this.schema,
    this.strict = true,
  });

  final String name;
  final Map<String, Object?> schema;
  final bool strict;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'schema': schema,
      'strict': strict,
    };
  }
}

class ClartCodeOutputFormat {
  const ClartCodeOutputFormat._({
    required this.type,
  });

  const ClartCodeOutputFormat.text()
      : this._(type: ClartCodeOutputFormatType.text);

  const ClartCodeOutputFormat.jsonObject()
      : this._(type: ClartCodeOutputFormatType.jsonObject);

  final ClartCodeOutputFormatType type;

  Map<String, Object?> toJson() {
    return {
      'type': type.name,
    };
  }
}

class QueryUsage {
  const QueryUsage({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.reasoningTokens,
    this.cachedInputTokens,
    this.cacheCreationInputTokens,
    this.cacheReadInputTokens,
    this.raw,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int? reasoningTokens;
  final int? cachedInputTokens;
  final int? cacheCreationInputTokens;
  final int? cacheReadInputTokens;
  final Map<String, Object?>? raw;

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      totalTokens == null &&
      reasoningTokens == null &&
      cachedInputTokens == null &&
      cacheCreationInputTokens == null &&
      cacheReadInputTokens == null &&
      (raw == null || raw!.isEmpty);

  QueryUsage merge(QueryUsage? other) {
    if (other == null) {
      return this;
    }
    return QueryUsage(
      inputTokens: _sumNullableInt(inputTokens, other.inputTokens),
      outputTokens: _sumNullableInt(outputTokens, other.outputTokens),
      totalTokens: _sumNullableInt(totalTokens, other.totalTokens),
      reasoningTokens: _sumNullableInt(reasoningTokens, other.reasoningTokens),
      cachedInputTokens:
          _sumNullableInt(cachedInputTokens, other.cachedInputTokens),
      cacheCreationInputTokens: _sumNullableInt(
        cacheCreationInputTokens,
        other.cacheCreationInputTokens,
      ),
      cacheReadInputTokens: _sumNullableInt(
        cacheReadInputTokens,
        other.cacheReadInputTokens,
      ),
      raw: _mergeRawMaps(raw, other.raw),
    );
  }

  static QueryUsage? combine(Iterable<QueryUsage?> items) {
    QueryUsage? combined;
    for (final item in items) {
      if (item == null || item.isEmpty) {
        continue;
      }
      combined = combined == null ? item : combined.merge(item);
    }
    return combined;
  }

  Map<String, Object?> toJson() {
    return {
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      'totalTokens': totalTokens,
      'reasoningTokens': reasoningTokens,
      'cachedInputTokens': cachedInputTokens,
      'cacheCreationInputTokens': cacheCreationInputTokens,
      'cacheReadInputTokens': cacheReadInputTokens,
      'raw': raw,
    };
  }
}

class QueryModelUsage {
  const QueryModelUsage({
    required this.model,
    this.usage,
    this.costUsd,
  });

  final String model;
  final QueryUsage? usage;
  final double? costUsd;

  QueryModelUsage merge({
    QueryUsage? usage,
    double? costUsd,
  }) {
    return QueryModelUsage(
      model: model,
      usage: QueryUsage.combine([this.usage, usage]),
      costUsd: _sumNullableDouble(this.costUsd, costUsd),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'model': model,
      'usage': usage?.toJson(),
      'costUsd': costUsd,
    };
  }
}

class QueryRateLimitInfo {
  const QueryRateLimitInfo({
    this.provider,
    this.status,
    this.requestsLimit,
    this.requestsRemaining,
    this.requestsReset,
    this.tokensLimit,
    this.tokensRemaining,
    this.tokensReset,
    this.retryAfter,
    this.raw = const {},
  });

  final String? provider;
  final String? status;
  final String? requestsLimit;
  final String? requestsRemaining;
  final String? requestsReset;
  final String? tokensLimit;
  final String? tokensRemaining;
  final String? tokensReset;
  final String? retryAfter;
  final Map<String, Object?> raw;

  bool get hasData =>
      (provider?.isNotEmpty ?? false) ||
      (status?.isNotEmpty ?? false) ||
      (requestsLimit?.isNotEmpty ?? false) ||
      (requestsRemaining?.isNotEmpty ?? false) ||
      (requestsReset?.isNotEmpty ?? false) ||
      (tokensLimit?.isNotEmpty ?? false) ||
      (tokensRemaining?.isNotEmpty ?? false) ||
      (tokensReset?.isNotEmpty ?? false) ||
      (retryAfter?.isNotEmpty ?? false) ||
      raw.isNotEmpty;

  Map<String, Object?> toJson() {
    return {
      'provider': provider,
      'status': status,
      'requestsLimit': requestsLimit,
      'requestsRemaining': requestsRemaining,
      'requestsReset': requestsReset,
      'tokensLimit': tokensLimit,
      'tokensRemaining': tokensRemaining,
      'tokensReset': tokensReset,
      'retryAfter': retryAfter,
      'raw': raw,
    };
  }
}

class QueryToolDefinition {
  const QueryToolDefinition({
    required this.name,
    required this.description,
    this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?>? inputSchema;
}

class QueryToolCall {
  const QueryToolCall({
    required this.id,
    required this.name,
    this.input = const {},
  });

  final String id;
  final String name;
  final Map<String, Object?> input;
}

class QueryCancellationSignal {
  QueryCancellationSignal._(this._controller);

  final StreamController<void> _controller;

  bool _isCancelled = false;
  String? _reason;

  bool get isCancelled => _isCancelled;

  String? get reason => _reason;

  Stream<void> get onCancel => _controller.stream;
}

class QueryCancellationController {
  QueryCancellationController._(this._controller)
      : signal = QueryCancellationSignal._(_controller);

  factory QueryCancellationController() {
    return QueryCancellationController._(
      StreamController<void>.broadcast(sync: true),
    );
  }

  final QueryCancellationSignal signal;
  final StreamController<void> _controller;

  bool get isCancelled => signal.isCancelled;

  void cancel([String reason = 'request cancelled']) {
    if (signal._isCancelled) {
      return;
    }
    signal._isCancelled = true;
    signal._reason = reason;
    _controller.add(null);
    unawaited(_controller.close());
  }

  void close() {
    if (_controller.isClosed) {
      return;
    }
    unawaited(_controller.close());
  }
}

class QueryRequest {
  const QueryRequest({
    required this.messages,
    this.maxTurns = 1,
    this.model,
    this.effort,
    this.systemPrompt,
    this.appendSystemPrompt,
    this.maxTokens,
    this.maxBudgetUsd,
    this.thinking,
    this.jsonSchema,
    this.outputFormat,
    this.includePartialMessages = true,
    this.includeObservabilityMessages = false,
    this.toolDefinitions = const [],
    this.providerStateToken,
    this.cancellationSignal,
  });

  final List<ChatMessage> messages;
  final int maxTurns;
  final String? model;
  final ClartCodeReasoningEffort? effort;
  final String? systemPrompt;
  final String? appendSystemPrompt;
  final int? maxTokens;
  final double? maxBudgetUsd;
  final ClartCodeThinkingConfig? thinking;
  final ClartCodeJsonSchema? jsonSchema;
  final ClartCodeOutputFormat? outputFormat;
  final bool includePartialMessages;
  final bool includeObservabilityMessages;
  final List<QueryToolDefinition> toolDefinitions;
  final String? providerStateToken;
  final QueryCancellationSignal? cancellationSignal;
}

class QueryResponse {
  const QueryResponse({
    required this.output,
    this.modelUsed,
    this.error,
    this.toolCalls = const [],
    this.usage,
    this.costUsd,
    this.providerStateToken,
  });

  final String output;
  final String? modelUsed;
  final RuntimeError? error;
  final List<QueryToolCall> toolCalls;
  final QueryUsage? usage;
  final double? costUsd;
  final String? providerStateToken;

  bool get isOk => error == null;

  factory QueryResponse.success({
    required String output,
    String? modelUsed,
    List<QueryToolCall> toolCalls = const [],
    QueryUsage? usage,
    double? costUsd,
    String? providerStateToken,
  }) {
    return QueryResponse(
      output: output,
      modelUsed: modelUsed,
      toolCalls: toolCalls,
      usage: usage,
      costUsd: costUsd,
      providerStateToken: providerStateToken,
    );
  }

  factory QueryResponse.failure({
    required RuntimeError error,
    String output = '',
    String? modelUsed,
    List<QueryToolCall> toolCalls = const [],
    QueryUsage? usage,
    double? costUsd,
    String? providerStateToken,
  }) {
    return QueryResponse(
      output: output,
      modelUsed: modelUsed,
      error: error,
      toolCalls: toolCalls,
      usage: usage,
      costUsd: costUsd,
      providerStateToken: providerStateToken,
    );
  }
}

int? _sumNullableInt(int? left, int? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left + right;
}

double? _sumNullableDouble(double? left, double? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left + right;
}

Map<String, Object?>? _mergeRawMaps(
  Map<String, Object?>? left,
  Map<String, Object?>? right,
) {
  if ((left == null || left.isEmpty) && (right == null || right.isEmpty)) {
    return null;
  }
  return {
    ...?left,
    ...?right,
  };
}
