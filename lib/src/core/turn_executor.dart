import 'dart:async';

import 'models.dart';
import 'query_engine.dart';
import 'query_events.dart';
import 'runtime_error.dart';
import 'transcript.dart';
import '../providers/llm_provider.dart';

enum TurnExecutionStatus { success, error, interrupted }

class TurnExecutionResult {
  const TurnExecutionResult({
    required this.status,
    required this.output,
    required this.displayOutput,
    required this.rawOutput,
    required this.transcriptMessages,
    this.modelUsed,
    this.error,
  });

  final TurnExecutionStatus status;
  final String output;
  final String displayOutput;
  final String rawOutput;
  final List<TranscriptMessage> transcriptMessages;
  final String? modelUsed;
  final RuntimeError? error;

  bool get success => status == TurnExecutionStatus.success;

  bool get interrupted => status == TurnExecutionStatus.interrupted;

  bool get failed => status == TurnExecutionStatus.error;

  QueryResponse toQueryResponse() {
    switch (status) {
      case TurnExecutionStatus.success:
        return QueryResponse.success(
          output: output,
          modelUsed: modelUsed,
        );
      case TurnExecutionStatus.error:
        return QueryResponse.failure(
          error: error ??
              const RuntimeError(
                code: RuntimeErrorCode.providerFailure,
                message: 'turn execution failed',
                source: 'turn_executor',
                retriable: true,
              ),
          output: output,
          modelUsed: modelUsed,
        );
      case TurnExecutionStatus.interrupted:
        throw StateError(
            'Interrupted turn cannot be converted to QueryResponse');
    }
  }
}

class TurnExecutor {
  TurnExecutor(this.engine);

  final QueryEngine engine;

  Future<TurnExecutionResult> execute({
    required QueryRequest request,
    required int turn,
    void Function(QueryEvent event)? onEvent,
    void Function(String delta, String? modelUsed)? onDelta,
    Stream<void>? interruptSignals,
    void Function()? onInterrupt,
    bool emitTurnStart = true,
  }) async {
    if (emitTurnStart) {
      onEvent?.call(QueryEvent(type: QueryEventType.turnStart, turn: turn));
    }

    final outputBuffer = StringBuffer();
    final completer = Completer<TurnExecutionResult>();
    var completed = false;
    var modelUsed = request.model;
    late final StreamSubscription<ProviderStreamEvent> streamSub;
    StreamSubscription<void>? interruptSub;

    void complete(TurnExecutionResult result) {
      if (completed) {
        return;
      }
      completed = true;
      completer.complete(result);
    }

    TurnExecutionResult buildSuccess({
      required String rawOutput,
      String? resolvedModel,
    }) {
      final normalizedOutput = rawOutput.isEmpty ? '[empty-output]' : rawOutput;
      final nextModel = resolvedModel ?? modelUsed;
      return TurnExecutionResult(
        status: TurnExecutionStatus.success,
        output: normalizedOutput,
        displayOutput: normalizedOutput,
        rawOutput: rawOutput,
        modelUsed: nextModel,
        transcriptMessages: [
          TranscriptMessage.assistant(normalizedOutput),
        ],
      );
    }

    TurnExecutionResult buildError({
      required RuntimeError error,
      required String output,
      String? resolvedModel,
    }) {
      final nextModel = resolvedModel ?? modelUsed;
      return TurnExecutionResult(
        status: TurnExecutionStatus.error,
        output: output,
        displayOutput: output,
        rawOutput: outputBuffer.toString(),
        modelUsed: nextModel,
        error: error,
        transcriptMessages: [
          TranscriptMessage.system(output),
        ],
      );
    }

    TurnExecutionResult buildInterrupted() {
      final rawOutput = outputBuffer.toString();
      final displayOutput = rawOutput.isEmpty ? '[interrupted]' : rawOutput;
      return TurnExecutionResult(
        status: TurnExecutionStatus.interrupted,
        output: rawOutput,
        displayOutput: displayOutput,
        rawOutput: rawOutput,
        modelUsed: modelUsed,
        transcriptMessages: [
          TranscriptMessage.assistant(displayOutput),
        ],
      );
    }

    streamSub = engine.runStream(request).listen(
      (event) {
        if (event.model != null && event.model!.isNotEmpty) {
          modelUsed = event.model;
        }

        switch (event.type) {
          case ProviderStreamEventType.textDelta:
            final delta = event.delta ?? '';
            if (delta.isEmpty) {
              return;
            }
            outputBuffer.write(delta);
            onDelta?.call(delta, modelUsed);
            onEvent?.call(
              QueryEvent(
                type: QueryEventType.providerDelta,
                turn: turn,
                delta: delta,
                model: modelUsed,
              ),
            );
            break;
          case ProviderStreamEventType.done:
            final result = buildSuccess(
              rawOutput: event.output ?? outputBuffer.toString(),
              resolvedModel: event.model ?? modelUsed,
            );
            onEvent?.call(
              QueryEvent(
                type: QueryEventType.assistant,
                turn: turn,
                output: result.output,
                model: result.modelUsed,
              ),
            );
            complete(result);
            break;
          case ProviderStreamEventType.error:
            final result = buildError(
              error: event.error ??
                  const RuntimeError(
                    code: RuntimeErrorCode.providerFailure,
                    message: 'provider stream failed',
                    source: 'turn_executor',
                    retriable: true,
                  ),
              output: normalizeProviderErrorOutput(event),
              resolvedModel: event.model ?? modelUsed,
            );
            onEvent?.call(
              QueryEvent(
                type: QueryEventType.error,
                turn: turn,
                error: result.error,
                output: result.output,
                model: result.modelUsed,
              ),
            );
            complete(result);
            break;
        }
      },
      onError: (Object error) {
        final result = buildError(
          error: RuntimeError(
            code: RuntimeErrorCode.providerFailure,
            message: '$error',
            source: 'turn_executor',
            retriable: true,
          ),
          output: '[ERROR] provider stream failed: $error',
        );
        onEvent?.call(
          QueryEvent(
            type: QueryEventType.error,
            turn: turn,
            error: result.error,
            output: result.output,
            model: result.modelUsed,
          ),
        );
        complete(result);
      },
      onDone: () {
        if (completed) {
          return;
        }

        final rawOutput = outputBuffer.toString();
        if (rawOutput.isNotEmpty) {
          final result = buildSuccess(rawOutput: rawOutput);
          onEvent?.call(
            QueryEvent(
              type: QueryEventType.assistant,
              turn: turn,
              output: result.output,
              model: result.modelUsed,
            ),
          );
          complete(result);
          return;
        }

        final result = buildError(
          error: const RuntimeError(
            code: RuntimeErrorCode.providerFailure,
            message: 'provider stream ended without terminal event',
            source: 'turn_executor',
            retriable: false,
          ),
          output: '[ERROR] provider stream ended unexpectedly',
        );
        onEvent?.call(
          QueryEvent(
            type: QueryEventType.error,
            turn: turn,
            error: result.error,
            output: result.output,
            model: result.modelUsed,
          ),
        );
        complete(result);
      },
      cancelOnError: false,
    );

    if (interruptSignals != null) {
      interruptSub = interruptSignals.listen((_) {
        onInterrupt?.call();
        complete(buildInterrupted());
        unawaited(streamSub.cancel());
      });
    }

    final result = await completer.future;
    await interruptSub?.cancel();
    await streamSub.cancel();
    return result;
  }
}

String normalizeProviderErrorOutput(ProviderStreamEvent event) {
  if (event.error?.source == 'provider_config') {
    return 'Provider is not configured. Run /init or clart_code init.';
  }
  if (event.output?.trim().isNotEmpty == true) {
    return event.output!;
  }
  return event.error?.message ?? '[ERROR] provider stream failed';
}
