import 'dart:async';

import 'runtime_error.dart';

enum MessageRole { system, user, assistant, tool }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
  });

  final MessageRole role;
  final String text;
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
    this.toolDefinitions = const [],
    this.providerStateToken,
    this.cancellationSignal,
  });

  final List<ChatMessage> messages;
  final int maxTurns;
  final String? model;
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
    this.providerStateToken,
  });

  final String output;
  final String? modelUsed;
  final RuntimeError? error;
  final List<QueryToolCall> toolCalls;
  final String? providerStateToken;

  bool get isOk => error == null;

  factory QueryResponse.success({
    required String output,
    String? modelUsed,
    List<QueryToolCall> toolCalls = const [],
    String? providerStateToken,
  }) {
    return QueryResponse(
      output: output,
      modelUsed: modelUsed,
      toolCalls: toolCalls,
      providerStateToken: providerStateToken,
    );
  }

  factory QueryResponse.failure({
    required RuntimeError error,
    String output = '',
    String? modelUsed,
    List<QueryToolCall> toolCalls = const [],
    String? providerStateToken,
  }) {
    return QueryResponse(
      output: output,
      modelUsed: modelUsed,
      error: error,
      toolCalls: toolCalls,
      providerStateToken: providerStateToken,
    );
  }
}
