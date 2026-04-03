import 'models.dart';
import 'runtime_error.dart';
import '../runtime/app_runtime.dart';

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
      return QueryResponse.failure(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'provider',
          retriable: true,
        ),
        output: '[ERROR] provider execution failed',
      );
    }
  }
}
