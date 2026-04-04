import 'dart:convert';

import 'models.dart';
import 'query_events.dart';
import 'query_engine.dart';
import 'runtime_error.dart';
import '../providers/llm_provider.dart';

class QueryLoopResult {
  const QueryLoopResult({
    required this.turns,
    required this.lastOutput,
    required this.success,
    required this.status,
    this.modelUsed,
  });

  final int turns;
  final String lastOutput;
  final bool success;
  final String status;
  final String? modelUsed;
}

class QueryLoop {
  QueryLoop(this.engine);

  final QueryEngine engine;

  Future<QueryLoopResult> run({
    required String prompt,
    int maxTurns = 1,
    bool streamJson = false,
    String? model,
    void Function(QueryEvent event)? onEvent,
  }) async {
    final messages = <ChatMessage>[
      ChatMessage(role: MessageRole.user, text: prompt)
    ];

    var turns = 0;
    var lastOutput = '';
    String? lastModelUsed;
    var success = true;

    final normalizedMaxTurns = maxTurns < 1 ? 1 : maxTurns;

    for (var turn = 1; turn <= normalizedMaxTurns; turn++) {
      _emit(
        streamJson,
        QueryEvent(type: QueryEventType.turnStart, turn: turn),
        onEvent: onEvent,
      );

      final request = QueryRequest(
        messages: List<ChatMessage>.from(messages),
        maxTurns: normalizedMaxTurns,
        model: model,
      );
      final response = await _runStreamTurn(
        request: request,
        turn: turn,
        streamJson: streamJson,
        onEvent: onEvent,
      );

      turns = turn;
      lastOutput = response.output;
      lastModelUsed = response.modelUsed ?? lastModelUsed;

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
          onEvent: onEvent,
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
          onEvent: onEvent,
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
    );
  }

  Future<QueryResponse> _runStreamTurn({
    required QueryRequest request,
    required int turn,
    required bool streamJson,
    void Function(QueryEvent event)? onEvent,
  }) async {
    var modelUsed = request.model;
    QueryResponse? terminalResponse;
    final outputBuffer = StringBuffer();

    await for (final event in engine.runStream(request)) {
      if (event.model != null && event.model!.isNotEmpty) {
        modelUsed = event.model;
      }

      switch (event.type) {
        case ProviderStreamEventType.textDelta:
          final delta = event.delta ?? '';
          if (delta.isNotEmpty) {
            outputBuffer.write(delta);
            _emit(
              streamJson,
              QueryEvent(
                type: QueryEventType.providerDelta,
                turn: turn,
                delta: delta,
                model: modelUsed,
              ),
              onEvent: onEvent,
            );
          }
          break;
        case ProviderStreamEventType.done:
          final output = event.output ?? outputBuffer.toString();
          terminalResponse = QueryResponse.success(
            output: output.isEmpty ? '[empty-output]' : output,
            modelUsed: event.model ?? modelUsed,
          );
          break;
        case ProviderStreamEventType.error:
          terminalResponse = QueryResponse.failure(
            error: event.error ??
                const RuntimeError(
                  code: RuntimeErrorCode.providerFailure,
                  message: 'provider stream failed',
                  source: 'query_loop',
                  retriable: true,
                ),
            output: event.output ?? '[ERROR] provider stream failed',
            modelUsed: event.model ?? modelUsed,
          );
          break;
      }

      if (terminalResponse != null) {
        break;
      }
    }

    if (terminalResponse != null) {
      return terminalResponse;
    }

    final output = outputBuffer.toString();
    if (output.isNotEmpty) {
      return QueryResponse.success(
        output: output,
        modelUsed: modelUsed,
      );
    }

    return QueryResponse.failure(
      error: const RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'provider stream ended without terminal event',
        source: 'query_loop',
        retriable: false,
      ),
      output: '[ERROR] provider stream ended unexpectedly',
      modelUsed: modelUsed,
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
