import 'input_processor.dart';
import 'models.dart';

class ConversationSession {
  ConversationSession({
    InputProcessor inputProcessor = const InputProcessor(),
    List<ChatMessage> initialMessages = const [],
  })  : _inputProcessor = inputProcessor,
        _history = List<ChatMessage>.from(initialMessages);

  final InputProcessor _inputProcessor;
  final List<ChatMessage> _history;

  List<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  ParsedInput prepareInput(
    String raw, {
    String? model,
  }) {
    final parsed = _inputProcessor.parse(raw, model: model);
    if (parsed.kind != ParsedInputKind.query) {
      return parsed;
    }

    return ParsedInput.query(
      raw: parsed.raw,
      request: _inputProcessor.buildQueryRequest(
        parsed.raw,
        model: model,
        precedingMessages: history,
      ),
    );
  }

  void recordTurn({
    required String prompt,
    required String output,
  }) {
    _history.add(ChatMessage(role: MessageRole.user, text: prompt));
    _history.add(ChatMessage(role: MessageRole.assistant, text: output));
  }

  void clear() {
    _history.clear();
  }
}
