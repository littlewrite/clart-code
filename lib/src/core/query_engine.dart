import 'dart:async';

import 'models.dart';
import 'runtime_error.dart';
import '../runtime/app_runtime.dart';
import '../providers/llm_provider.dart';

/// Query execution engine that coordinates LLM provider calls with security
/// checks and telemetry.
///
/// Handles both synchronous and streaming query execution, applying security
/// policies and error recovery logic.
class QueryEngine {
  QueryEngine(this.runtime);

  final AppRuntime runtime;

  /// Executes a query synchronously and returns the complete response.
  ///
  /// Applies security checks before execution and handles provider errors
  /// with automatic retry classification.
  Future<QueryResponse> run(QueryRequest request) async {
    if (_isRequestCancelled(request)) {
      runtime.telemetry.logEvent('query_cancelled');
      return QueryResponse.failure(
        error: _buildCancelledRuntimeError(request),
        output: _formatCancelledOutput(request),
      );
    }

    final userText = request.messages
        .where((m) => m.role == MessageRole.user)
        .map((m) => m.text)
        .join('\n');

    if (!runtime.securityGuard.allowUserInput(userText)) {
      runtime.telemetry.logEvent('query_rejected_by_security');
      return QueryResponse.failure(
        error: const RuntimeError(
          code: RuntimeErrorCode.securityRejected,
          message: 'blocked by security policy',
          source: 'security_guard',
          retriable: false,
        ),
        output: '[REJECTED] blocked by security policy',
      );
    }

    runtime.telemetry.logEvent('query_started');
    StreamSubscription<void>? cancelSub;
    if (request.cancellationSignal != null) {
      cancelSub = request.cancellationSignal!.onCancel.listen((_) {
        unawaited(runtime.provider.cancelActiveRequest());
      });
    }
    try {
      final result = await runtime.provider.run(request);
      if (_isRequestCancelled(request)) {
        runtime.telemetry.logEvent('query_cancelled');
        return QueryResponse.failure(
          error: _buildCancelledRuntimeError(request),
          output: _formatCancelledOutput(request),
          modelUsed: result.modelUsed,
          toolCalls: result.toolCalls,
          providerStateToken: result.providerStateToken,
        );
      }
      runtime.telemetry.logEvent('query_completed');
      return result;
    } catch (error, stackTrace) {
      runtime.telemetry.logError(error, stackTrace);
      runtime.telemetry.logEvent('query_failed', {'error': '$error'});

      // Determine if error is retriable based on error type
      final isRetriable = _isRetriableError(error);

      return QueryResponse.failure(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'provider',
          retriable: isRetriable,
        ),
        output: '[ERROR] provider execution failed',
      );
    } finally {
      await cancelSub?.cancel();
    }
  }

  /// Executes a query with streaming output, yielding events as they arrive.
  ///
  /// Applies security checks and emits [ProviderStreamEvent]s for incremental
  /// text deltas, completion, or errors.
  Stream<ProviderStreamEvent> runStream(QueryRequest request) async* {
    if (_isRequestCancelled(request)) {
      runtime.telemetry.logEvent('query_cancelled');
      yield ProviderStreamEvent.error(
        error: _buildCancelledRuntimeError(request),
        output: _formatCancelledOutput(request),
      );
      return;
    }

    final userText = request.messages
        .where((m) => m.role == MessageRole.user)
        .map((m) => m.text)
        .join('\n');

    if (!runtime.securityGuard.allowUserInput(userText)) {
      runtime.telemetry.logEvent('query_rejected_by_security');
      yield ProviderStreamEvent.error(
        error: const RuntimeError(
          code: RuntimeErrorCode.securityRejected,
          message: 'blocked by security policy',
          source: 'security_guard',
          retriable: false,
        ),
        output: '[REJECTED] blocked by security policy',
      );
      return;
    }

    runtime.telemetry.logEvent('query_started');
    StreamSubscription<void>? cancelSub;
    if (request.cancellationSignal != null) {
      cancelSub = request.cancellationSignal!.onCancel.listen((_) {
        unawaited(runtime.provider.cancelActiveRequest());
      });
    }
    try {
      var emittedTerminalEvent = false;
      await for (final event in runtime.provider.stream(request)) {
        if (event.type == ProviderStreamEventType.done ||
            event.type == ProviderStreamEventType.error) {
          emittedTerminalEvent = true;
        }
        yield event;
      }
      if (!emittedTerminalEvent && _isRequestCancelled(request)) {
        runtime.telemetry.logEvent('query_cancelled');
        yield ProviderStreamEvent.error(
          error: _buildCancelledRuntimeError(request),
          output: _formatCancelledOutput(request),
        );
        return;
      }
      runtime.telemetry.logEvent('query_completed');
    } catch (error, stackTrace) {
      runtime.telemetry.logError(error, stackTrace);
      runtime.telemetry.logEvent('query_failed', {'error': '$error'});

      final isRetriable = _isRetriableError(error);

      yield ProviderStreamEvent.error(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'provider',
          retriable: isRetriable,
        ),
        output: '[ERROR] provider execution failed',
      );
    } finally {
      await cancelSub?.cancel();
    }
  }

  bool _isRequestCancelled(QueryRequest request) {
    return request.cancellationSignal?.isCancelled ?? false;
  }

  RuntimeError _buildCancelledRuntimeError(QueryRequest request) {
    final reason = request.cancellationSignal?.reason?.trim();
    return RuntimeError(
      code: RuntimeErrorCode.cancelled,
      message: reason == null || reason.isEmpty ? 'request cancelled' : reason,
      source: 'query_engine',
      retriable: false,
    );
  }

  String _formatCancelledOutput(QueryRequest request) {
    return '[STOPPED] request cancelled';
  }

  bool _isRetriableError(Object error) {
    final errorStr = error.toString().toLowerCase();

    // Network errors are retriable
    if (errorStr.contains('socket') ||
        errorStr.contains('connection') ||
        errorStr.contains('timeout') ||
        errorStr.contains('network')) {
      return true;
    }

    // Rate limit errors are retriable
    if (errorStr.contains('429') ||
        errorStr.contains('rate limit') ||
        errorStr.contains('throttle')) {
      return true;
    }

    // Server errors (5xx) are retriable
    if (errorStr.contains('500') ||
        errorStr.contains('502') ||
        errorStr.contains('503') ||
        errorStr.contains('504')) {
      return true;
    }

    // Authentication errors are not retriable
    if (errorStr.contains('401') ||
        errorStr.contains('403') ||
        errorStr.contains('unauthorized') ||
        errorStr.contains('forbidden')) {
      return false;
    }

    // Default: assume retriable for transient failures
    return true;
  }
}
