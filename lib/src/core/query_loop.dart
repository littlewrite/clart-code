import 'dart:convert';

import 'models.dart';
import 'query_events.dart';
import 'query_engine.dart';

class QueryLoopResult {
  const QueryLoopResult({
    required this.turns,
    required this.lastOutput,
    required this.success,
  });

  final int turns;
  final String lastOutput;
  final bool success;
}

class QueryLoop {
  QueryLoop(this.engine);

  final QueryEngine engine;

  Future<QueryLoopResult> run({
    required String prompt,
    int maxTurns = 1,
    bool streamJson = false,
  }) async {
    final messages = <ChatMessage>[
      ChatMessage(role: MessageRole.user, text: prompt)
    ];

    var turns = 0;
    var lastOutput = '';
    var success = true;

    final normalizedMaxTurns = maxTurns < 1 ? 1 : maxTurns;

    for (var turn = 1; turn <= normalizedMaxTurns; turn++) {
      _emit(
        streamJson,
        QueryEvent(type: QueryEventType.turnStart, turn: turn),
      );

      final response = await engine.run(
        QueryRequest(
            messages: List<ChatMessage>.from(messages),
            maxTurns: normalizedMaxTurns),
      );

      turns = turn;
      lastOutput = response.output;

      if (response.isOk) {
        messages.add(
          ChatMessage(role: MessageRole.assistant, text: response.output),
        );

        _emit(
          streamJson,
          QueryEvent(
            type: QueryEventType.assistant,
            turn: turn,
            output: response.output,
            model: response.modelUsed,
          ),
        );
      } else {
        success = false;
        _emit(
          streamJson,
          QueryEvent(
            type: QueryEventType.error,
            turn: turn,
            error: response.error,
            output: response.output,
            model: response.modelUsed,
          ),
        );
        break;
      }

      if (turn >= normalizedMaxTurns) {
        break;
      }

      // Placeholder continuation strategy for migration stage:
      // use a synthetic user message to keep a runnable multi-turn loop.
      messages.add(
        const ChatMessage(
          role: MessageRole.user,
          text: '[AUTO_CONTINUE] continue',
        ),
      );
    }

    _emit(
      streamJson,
      QueryEvent(
        type: QueryEventType.done,
        turns: turns,
        output: lastOutput,
        status: success ? 'ok' : 'error',
      ),
    );

    return QueryLoopResult(
      turns: turns,
      lastOutput: lastOutput,
      success: success,
    );
  }

  void _emit(bool streamJson, QueryEvent event) {
    if (streamJson) {
      print(jsonEncode(event.toJson()));
    }
  }
}
