import 'input_processor.dart';
import 'models.dart';
import 'transcript.dart';

class ConversationSession {
  ConversationSession({
    InputProcessor inputProcessor = const InputProcessor(),
    List<ChatMessage> initialMessages = const [],
    List<TranscriptMessage> initialTranscript = const [],
  })  : _inputProcessor = inputProcessor,
        _history = List<ChatMessage>.from(initialMessages),
        _transcript = List<TranscriptMessage>.from(initialTranscript);

  final InputProcessor _inputProcessor;
  final List<ChatMessage> _history;
  final List<TranscriptMessage> _transcript;

  List<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  List<TranscriptMessage> get transcript =>
      List<TranscriptMessage>.unmodifiable(_transcript);

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
    _transcript.add(TranscriptMessage.userPrompt(prompt));
    _transcript.add(TranscriptMessage.assistant(output));
    recordHistoryTurn(prompt: prompt, output: output);
  }

  void recordHistoryTurn({
    required String prompt,
    required String output,
  }) {
    _history.add(ChatMessage(role: MessageRole.user, text: prompt));
    _history.add(ChatMessage(role: MessageRole.assistant, text: output));
  }

  void appendTranscriptMessages(Iterable<TranscriptMessage> messages) {
    _transcript.addAll(messages);
  }

  void clear() {
    _history.clear();
    _transcript.clear();
  }
}
