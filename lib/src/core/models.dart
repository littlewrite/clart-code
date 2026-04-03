import 'runtime_error.dart';

enum MessageRole { system, user, assistant, tool }

class ChatMessage {
  const ChatMessage({required this.role, required this.text});

  final MessageRole role;
  final String text;
}

class QueryRequest {
  const QueryRequest({
    required this.messages,
    this.maxTurns = 1,
    this.model,
  });

  final List<ChatMessage> messages;
  final int maxTurns;
  final String? model;
}

class QueryResponse {
  const QueryResponse({
    required this.output,
    this.modelUsed,
    this.error,
  });

  final String output;
  final String? modelUsed;
  final RuntimeError? error;

  bool get isOk => error == null;

  factory QueryResponse.success({
    required String output,
    String? modelUsed,
  }) {
    return QueryResponse(output: output, modelUsed: modelUsed);
  }

  factory QueryResponse.failure({
    required RuntimeError error,
    String output = '',
    String? modelUsed,
  }) {
    return QueryResponse(output: output, modelUsed: modelUsed, error: error);
  }
}
