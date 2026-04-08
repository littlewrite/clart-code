enum TranscriptMessageKind {
  userPrompt,
  localCommand,
  localCommandStdout,
  localCommandStderr,
  assistant,
  toolResult,
  subagent,
  system,
}

class TranscriptMessage {
  const TranscriptMessage._({
    required this.kind,
    required this.text,
    this.sessionId,
    this.parentSessionId,
    this.name,
  });

  const TranscriptMessage.userPrompt(String text)
      : this._(kind: TranscriptMessageKind.userPrompt, text: text);

  const TranscriptMessage.user(String text) : this.userPrompt(text);

  const TranscriptMessage.assistant(String text)
      : this._(kind: TranscriptMessageKind.assistant, text: text);

  const TranscriptMessage.system(String text)
      : this._(kind: TranscriptMessageKind.system, text: text);

  const TranscriptMessage.localCommand(String text)
      : this._(kind: TranscriptMessageKind.localCommand, text: text);

  const TranscriptMessage.localCommandStdout(String text)
      : this._(kind: TranscriptMessageKind.localCommandStdout, text: text);

  const TranscriptMessage.localCommandStderr(String text)
      : this._(kind: TranscriptMessageKind.localCommandStderr, text: text);

  const TranscriptMessage.toolResult(String text)
      : this._(kind: TranscriptMessageKind.toolResult, text: text);

  const TranscriptMessage.subagent(
    String text, {
    String? sessionId,
    String? parentSessionId,
    String? name,
  }) : this._(
          kind: TranscriptMessageKind.subagent,
          text: text,
          sessionId: sessionId,
          parentSessionId: parentSessionId,
          name: name,
        );

  final TranscriptMessageKind kind;
  final String text;
  final String? sessionId;
  final String? parentSessionId;
  final String? name;

  Map<String, Object?> toJson() {
    return {
      'kind': kind.name,
      'text': text,
      if (sessionId != null) 'sessionId': sessionId,
      if (parentSessionId != null) 'parentSessionId': parentSessionId,
      if (name != null) 'name': name,
    };
  }

  factory TranscriptMessage.fromJson(Map<String, Object?> json) {
    final text = json['text'] as String? ?? '';
    switch (json['kind'] as String?) {
      case 'userPrompt':
        return TranscriptMessage.userPrompt(text);
      case 'localCommand':
        return TranscriptMessage.localCommand(text);
      case 'localCommandStdout':
        return TranscriptMessage.localCommandStdout(text);
      case 'localCommandStderr':
        return TranscriptMessage.localCommandStderr(text);
      case 'assistant':
        return TranscriptMessage.assistant(text);
      case 'toolResult':
        return TranscriptMessage.toolResult(text);
      case 'subagent':
        return TranscriptMessage.subagent(
          text,
          sessionId: json['sessionId'] as String?,
          parentSessionId: json['parentSessionId'] as String?,
          name: json['name'] as String?,
        );
      case 'system':
      default:
        return TranscriptMessage.system(text);
    }
  }
}
