import 'package:clart_code/src/core/models.dart';
import 'package:clart_code/src/core/query_engine.dart';
import 'package:clart_code/src/core/runtime_error.dart';
import 'package:clart_code/src/providers/llm_provider.dart';
import 'package:clart_code/src/runtime/app_runtime.dart';
import 'package:clart_code/src/services/security_guard.dart';
import 'package:clart_code/src/services/telemetry.dart';
import 'package:test/test.dart';

void main() {
  group('QueryEngine', () {
    late QueryEngine engine;
    late AppRuntime runtime;

    setUp(() {
      runtime = AppRuntime(
        provider: LocalEchoProvider(),
        telemetry: const TelemetryService(),
        securityGuard: const SecurityGuard(),
      );
      engine = QueryEngine(runtime);
    });

    test('run() returns success response for valid query', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      );

      final response = await engine.run(request);

      expect(response.isOk, true);
      expect(response.output, contains('echo'));
      expect(response.modelUsed, 'local-echo');
    });

    test('run() returns empty output for empty input', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: ''),
        ],
      );

      final response = await engine.run(request);

      expect(response.isOk, true);
      expect(response.output, '[empty-input]');
    });

    test('runStream() emits textDelta and done events', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in engine.runStream(request)) {
        events.add(event);
      }

      expect(events, isNotEmpty);
      expect(
        events.any((e) => e.type == ProviderStreamEventType.textDelta),
        true,
      );
      expect(
        events.any((e) => e.type == ProviderStreamEventType.done),
        true,
      );
    });

    test('runStream() emits error event when security check fails', () async {
      final securityGuard = _FailingSecurityGuard();
      final runtime = AppRuntime(
        provider: LocalEchoProvider(),
        securityGuard: securityGuard,
      );
      final engine = QueryEngine(runtime);

      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in engine.runStream(request)) {
        events.add(event);
      }

      expect(
        events.any((e) => e.type == ProviderStreamEventType.error),
        true,
      );
      final errorEvent = events.firstWhere(
        (e) => e.type == ProviderStreamEventType.error,
      );
      expect(
        errorEvent.error?.code,
        RuntimeErrorCode.securityRejected,
      );
    });
  });
}

class _FailingSecurityGuard extends SecurityGuard {
  const _FailingSecurityGuard() : super();

  @override
  bool allowUserInput(String input) => false;
}
