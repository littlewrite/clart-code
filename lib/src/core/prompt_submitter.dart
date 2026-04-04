import 'conversation_session.dart';
import 'input_processor.dart';
import 'models.dart';

class PromptSubmission {
  const PromptSubmission._({
    required this.kind,
    required this.raw,
    this.commandName,
    this.commandArgs = const [],
    this.request,
  });

  factory PromptSubmission.fromParsedInput(ParsedInput parsed) {
    return PromptSubmission._(
      kind: parsed.kind,
      raw: parsed.raw,
      commandName: parsed.commandName,
      commandArgs: parsed.commandArgs,
      request: parsed.request,
    );
  }

  final ParsedInputKind kind;
  final String raw;
  final String? commandName;
  final List<String> commandArgs;
  final QueryRequest? request;

  bool get isEmpty => kind == ParsedInputKind.empty;

  bool get isExit => kind == ParsedInputKind.exit;

  bool get isSlashCommand => kind == ParsedInputKind.slashCommand;

  bool get isQuery => kind == ParsedInputKind.query && request != null;
}

class PromptSubmitter {
  PromptSubmitter({
    InputProcessor inputProcessor = const InputProcessor(),
    ConversationSession? conversation,
  })  : _inputProcessor = inputProcessor,
        _conversation = conversation;

  final InputProcessor _inputProcessor;
  final ConversationSession? _conversation;

  PromptSubmission submit(
    String raw, {
    String? model,
  }) {
    final parsed = _conversation?.prepareInput(raw, model: model) ??
        _inputProcessor.parse(raw, model: model);
    return PromptSubmission.fromParsedInput(parsed);
  }
}
