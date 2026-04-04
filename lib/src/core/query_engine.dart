import 'models.dart';
import 'runtime_error.dart';
import '../runtime/app_runtime.dart';
import '../providers/llm_provider.dart';

class QueryEngine {
  QueryEngine(this.runtime);

  final AppRuntime runtime;

  Future<QueryResponse> run(QueryRequest request) async {
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
    try {
      final result = await runtime.provider.run(request);
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
    }
  }

  Stream<ProviderStreamEvent> runStream(QueryRequest request) async* {
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
    try {
      await for (final event in runtime.provider.stream(request)) {
        yield event;
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
    }
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
