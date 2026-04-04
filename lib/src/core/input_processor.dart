import 'models.dart';

enum ParsedInputKind { empty, exit, slashCommand, query }

class ParsedInput {
  const ParsedInput._({
    required this.kind,
    required this.raw,
    this.commandName,
    this.commandArgs = const [],
    this.request,
  });

  factory ParsedInput.empty(String raw) =>
      ParsedInput._(kind: ParsedInputKind.empty, raw: raw);

  factory ParsedInput.exit(String raw) =>
      ParsedInput._(kind: ParsedInputKind.exit, raw: raw);

  factory ParsedInput.slashCommand({
    required String raw,
    required String commandName,
    required List<String> commandArgs,
  }) {
    return ParsedInput._(
      kind: ParsedInputKind.slashCommand,
      raw: raw,
      commandName: commandName,
      commandArgs: List.unmodifiable(commandArgs),
    );
  }

  factory ParsedInput.query({
    required String raw,
    required QueryRequest request,
  }) {
    return ParsedInput._(
      kind: ParsedInputKind.query,
      raw: raw,
      request: request,
    );
  }

  final ParsedInputKind kind;
  final String raw;
  final String? commandName;
  final List<String> commandArgs;
  final QueryRequest? request;

  bool get isQuery => kind == ParsedInputKind.query;
}

class InputProcessor {
  const InputProcessor();

  ParsedInput parse(
    String raw, {
    String? model,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return ParsedInput.empty(raw);
    }

    if (_isExitCommand(trimmed)) {
      return ParsedInput.exit(trimmed);
    }

    if (trimmed.startsWith('/')) {
      final tokens = trimmed.split(RegExp(r'\s+'));
      final commandName = tokens.first.substring(1);
      final commandArgs = tokens.length > 1 ? tokens.sublist(1) : <String>[];
      return ParsedInput.slashCommand(
        raw: trimmed,
        commandName: commandName,
        commandArgs: commandArgs,
      );
    }

    return ParsedInput.query(
      raw: trimmed,
      request: buildQueryRequest(trimmed, model: model),
    );
  }

  QueryRequest buildQueryRequest(
    String prompt, {
    String? model,
    List<ChatMessage> precedingMessages = const [],
  }) {
    return QueryRequest(
      messages: [
        ...precedingMessages,
        ChatMessage(role: MessageRole.user, text: prompt),
      ],
      maxTurns: 1,
      model: model,
    );
  }

  bool _isExitCommand(String value) {
    final input = value.trim().toLowerCase();
    return input == '/exit' ||
        input == '/quit' ||
        input == 'exit' ||
        input == 'quit';
  }
}
