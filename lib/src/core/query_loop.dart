import 'dart:convert';

import 'conversation_session.dart';
import 'models.dart';
import 'process_user_input.dart';
import 'prompt_submitter.dart';
import 'query_events.dart';
import 'query_engine.dart';
import 'transcript.dart';
import 'turn_executor.dart';

class QueryLoopResult {
  const QueryLoopResult({
    required this.turns,
    required this.lastOutput,
    required this.success,
    required this.status,
    required this.history,
    required this.transcript,
    this.modelUsed,
  });

  final int turns;
  final String lastOutput;
  final bool success;
  final String status;
  final String? modelUsed;
  final List<ChatMessage> history;
  final List<TranscriptMessage> transcript;
}

typedef ContinuationPromptBuilder = String? Function(
  QueryResponse response,
  int completedTurn,
  List<ChatMessage> transcript,
);

class QueryLoop {
  QueryLoop(this.engine);

  final QueryEngine engine;

  Future<QueryLoopResult> run({
    required String prompt,
    int maxTurns = 1,
    bool streamJson = false,
    String? model,
    ContinuationPromptBuilder? continuationPromptBuilder,
    void Function(QueryEvent event)? onEvent,
  }) async {
    final conversation = ConversationSession();
    final submitter = PromptSubmitter(conversation: conversation);
    var pendingSubmission = submitter.submit(
      prompt,
      model: model,
    );
    final inputProcessor = const UserInputProcessor();
    var pendingInput = inputProcessor.process(pendingSubmission);
    if (!pendingInput.isQuery) {
      return QueryLoopResult(
        turns: 0,
        lastOutput: '[ERROR] loop only accepts plain prompt text',
        success: false,
        status: 'error',
        modelUsed: model,
        history: const [],
        transcript: const [],
      );
    }

    var turns = 0;
    var lastOutput = '';
    String? lastModelUsed;
    var success = true;
    final executor = TurnExecutor(engine);
    void emitEvent(QueryEvent event) => _emit(
          streamJson,
          event,
          onEvent: onEvent,
        );

    final normalizedMaxTurns = maxTurns < 1 ? 1 : maxTurns;

    for (var turn = 1; turn <= normalizedMaxTurns; turn++) {
      final request = QueryRequest(
        messages: List<ChatMessage>.from(pendingInput.request!.messages),
        maxTurns: normalizedMaxTurns,
        model: model,
      );
      final turnResult = await executor.execute(
        request: request,
        turn: turn,
        onEvent: emitEvent,
      );
      final response = turnResult.toQueryResponse();

      turns = turn;
      lastOutput = turnResult.output;
      lastModelUsed = turnResult.modelUsed ?? lastModelUsed;

      if (turnResult.success) {
        conversation.appendTranscriptMessages([
          ...pendingInput.transcriptMessages,
          ...turnResult.transcriptMessages,
        ]);
        conversation.recordHistoryTurn(
          prompt: pendingInput.submission.raw,
          output: turnResult.displayOutput,
        );
      } else {
        conversation.appendTranscriptMessages([
          ...pendingInput.transcriptMessages,
          ...turnResult.transcriptMessages,
        ]);
        success = false;
        break;
      }

      if (turn >= normalizedMaxTurns) {
        break;
      }

      final nextPrompt = continuationPromptBuilder?.call(
        response,
        turn,
        conversation.history,
      );
      if (nextPrompt == null || nextPrompt.trim().isEmpty) {
        break;
      }

      pendingSubmission = submitter.submit(
        nextPrompt,
        model: model,
      );
      pendingInput = inputProcessor.process(pendingSubmission);
      if (!pendingInput.isQuery) {
        success = false;
        lastOutput = '[ERROR] continuation prompt must be plain query text';
        break;
      }
    }

    _emit(
      streamJson,
      QueryEvent(
        type: QueryEventType.done,
        turns: turns,
        output: lastOutput,
        model: lastModelUsed,
        status: success ? 'ok' : 'error',
      ),
      onEvent: onEvent,
    );

    return QueryLoopResult(
      turns: turns,
      lastOutput: lastOutput,
      success: success,
      status: success ? 'ok' : 'error',
      modelUsed: lastModelUsed,
      history: conversation.history,
      transcript: conversation.transcript,
    );
  }

  void _emit(
    bool streamJson,
    QueryEvent event, {
    void Function(QueryEvent event)? onEvent,
  }) {
    onEvent?.call(event);
    if (streamJson) {
      print(jsonEncode(event.toJson()));
    }
  }
}
