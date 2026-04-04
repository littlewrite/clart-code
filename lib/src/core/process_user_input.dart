import 'input_processor.dart';
import 'models.dart';
import 'prompt_submitter.dart';
import 'transcript.dart';

enum ProcessUserInputKind { ignore, exit, localCommand, query, invalid }

class LocalCommandResult {
  const LocalCommandResult({
    required this.status,
    this.messages = const [],
    this.clearScreen = false,
    this.clearTranscript = false,
    this.recordCommandInput = true,
  });

  final String status;
  final List<TranscriptMessage> messages;
  final bool clearScreen;
  final bool clearTranscript;
  final bool recordCommandInput;
}

typedef SlashCommandExecutor = LocalCommandResult? Function(
  PromptSubmission submission,
);

class ProcessUserInputResult {
  const ProcessUserInputResult._({
    required this.kind,
    required this.submission,
    this.request,
    this.transcriptMessages = const [],
    this.localCommandResult,
    this.errorText,
    this.status,
  });

  factory ProcessUserInputResult.ignore({
    required PromptSubmission submission,
  }) {
    return ProcessUserInputResult._(
      kind: ProcessUserInputKind.ignore,
      submission: submission,
    );
  }

  factory ProcessUserInputResult.exit({
    required PromptSubmission submission,
  }) {
    return ProcessUserInputResult._(
      kind: ProcessUserInputKind.exit,
      submission: submission,
      status: 'Exiting.',
    );
  }

  factory ProcessUserInputResult.localCommand({
    required PromptSubmission submission,
    required LocalCommandResult localCommandResult,
  }) {
    return ProcessUserInputResult._(
      kind: ProcessUserInputKind.localCommand,
      submission: submission,
      localCommandResult: localCommandResult,
      transcriptMessages: [
        if (localCommandResult.recordCommandInput)
          TranscriptMessage.localCommand(submission.raw),
        ...localCommandResult.messages,
      ],
      status: localCommandResult.status,
    );
  }

  factory ProcessUserInputResult.query({
    required PromptSubmission submission,
    required QueryRequest request,
  }) {
    return ProcessUserInputResult._(
      kind: ProcessUserInputKind.query,
      submission: submission,
      request: request,
      transcriptMessages: [
        TranscriptMessage.userPrompt(submission.raw),
      ],
    );
  }

  factory ProcessUserInputResult.invalid({
    required PromptSubmission submission,
    required String errorText,
  }) {
    final isSlashCommand = submission.kind == ParsedInputKind.slashCommand;
    return ProcessUserInputResult._(
      kind: ProcessUserInputKind.invalid,
      submission: submission,
      errorText: errorText,
      status: errorText,
      transcriptMessages: [
        if (isSlashCommand) TranscriptMessage.localCommand(submission.raw),
        if (isSlashCommand)
          TranscriptMessage.localCommandStderr(errorText)
        else
          TranscriptMessage.system(errorText),
      ],
    );
  }

  final ProcessUserInputKind kind;
  final PromptSubmission submission;
  final QueryRequest? request;
  final List<TranscriptMessage> transcriptMessages;
  final LocalCommandResult? localCommandResult;
  final String? errorText;
  final String? status;

  bool get isQuery => kind == ProcessUserInputKind.query && request != null;
}

class UserInputProcessor {
  const UserInputProcessor();

  ProcessUserInputResult process(
    PromptSubmission submission, {
    SlashCommandExecutor? onSlashCommand,
  }) {
    switch (submission.kind) {
      case ParsedInputKind.empty:
        return ProcessUserInputResult.ignore(submission: submission);
      case ParsedInputKind.exit:
        return ProcessUserInputResult.exit(submission: submission);
      case ParsedInputKind.slashCommand:
        final localCommandResult = onSlashCommand?.call(submission);
        if (localCommandResult != null) {
          return ProcessUserInputResult.localCommand(
            submission: submission,
            localCommandResult: localCommandResult,
          );
        }
        return ProcessUserInputResult.invalid(
          submission: submission,
          errorText: 'Unknown command: ${submission.raw}',
        );
      case ParsedInputKind.query:
        final request = submission.request;
        if (request == null) {
          return ProcessUserInputResult.invalid(
            submission: submission,
            errorText: 'Unable to build query request.',
          );
        }
        return ProcessUserInputResult.query(
          submission: submission,
          request: request,
        );
    }
  }
}
