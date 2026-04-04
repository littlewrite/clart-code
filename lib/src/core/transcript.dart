enum TranscriptMessageKind {
  userPrompt,
  localCommand,
  localCommandStdout,
  localCommandStderr,
  assistant,
  toolResult,
  system,
}

class TranscriptMessage {
  const TranscriptMessage._({
    required this.kind,
    required this.text,
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

  final TranscriptMessageKind kind;
  final String text;
}
