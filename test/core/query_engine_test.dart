import 'dart:async';

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

    test('run() forwards cancellation to provider and returns cancelled',
        () async {
      final provider = _CancelableRunProvider();
      final engine = QueryEngine(
        AppRuntime(
          provider: provider,
          telemetry: const TelemetryService(),
          securityGuard: const SecurityGuard(),
        ),
      );
      final controller = QueryCancellationController();

      final pending = engine.run(
        QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'hello'),
          ],
          cancellationSignal: controller.signal,
        ),
      );

      controller.cancel('manual_stop');
      final response = await pending;

      expect(provider.cancelCalled, isTrue);
      expect(response.isOk, isFalse);
      expect(response.error?.code, RuntimeErrorCode.cancelled);
      expect(response.output, contains('STOPPED'));
    });

    test('runStream() emits cancelled error when provider ends after cancel',
        () async {
      final provider = _CancelableStreamProvider();
      final engine = QueryEngine(
        AppRuntime(
          provider: provider,
          telemetry: const TelemetryService(),
          securityGuard: const SecurityGuard(),
        ),
      );
      final controller = QueryCancellationController();

      final events = <ProviderStreamEvent>[];
      final pending = () async {
        await for (final event in engine.runStream(
          QueryRequest(
            messages: [
              ChatMessage(role: MessageRole.user, text: 'hello'),
            ],
            cancellationSignal: controller.signal,
          ),
        )) {
          events.add(event);
        }
      }();

      await provider.started.future;
      controller.cancel('manual_stop');
      await pending;

      expect(provider.cancelCalled, isTrue);
      expect(events, isNotEmpty);
      expect(events.single.type, ProviderStreamEventType.error);
      expect(events.single.error?.code, RuntimeErrorCode.cancelled);
      expect(events.single.output, contains('STOPPED'));
    });
  });
}

class _FailingSecurityGuard extends SecurityGuard {
  const _FailingSecurityGuard() : super();

  @override
  bool allowUserInput(String input) => false;
}

class _CancelableRunProvider extends LlmProvider {
  final Completer<QueryResponse> _response = Completer<QueryResponse>();
  bool cancelCalled = false;

  @override
  Future<void> cancelActiveRequest() async {
    cancelCalled = true;
    if (!_response.isCompleted) {
      _response.complete(
        QueryResponse.success(output: 'late success', modelUsed: 'cancel-run'),
      );
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return _response.future;
  }
}

class _CancelableStreamProvider extends LlmProvider {
  final Completer<void> _done = Completer<void>();
  final Completer<void> started = Completer<void>();
  bool cancelCalled = false;

  @override
  Future<void> cancelActiveRequest() async {
    cancelCalled = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    if (!started.isCompleted) {
      started.complete();
    }
    await _done.future;
  }
}
