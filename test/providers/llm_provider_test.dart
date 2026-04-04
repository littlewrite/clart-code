import 'package:clart_code/src/core/models.dart';
import 'package:clart_code/src/core/runtime_error.dart';
import 'package:clart_code/src/providers/llm_provider.dart';
import 'package:test/test.dart';

void main() {
  group('LocalEchoProvider', () {
    late LocalEchoProvider provider;

    setUp(() {
      provider = LocalEchoProvider();
    });

    test('run() returns echo of user input', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello world'),
        ],
      );

      final response = await provider.run(request);

      expect(response.isOk, true);
      expect(response.output, contains('hello world'));
      expect(response.modelUsed, 'local-echo');
    });

    test('stream() emits textDelta and done events', () async {
      final request = QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'test'),
        ],
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in provider.stream(request)) {
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
  });

  group('ProviderStreamEvent', () {
    test('textDelta factory creates correct event', () {
      final event = ProviderStreamEvent.textDelta(
        delta: 'hello',
        model: 'test-model',
      );

      expect(event.type, ProviderStreamEventType.textDelta);
      expect(event.delta, 'hello');
      expect(event.model, 'test-model');
    });

    test('done factory creates correct event', () {
      final event = ProviderStreamEvent.done(
        output: 'complete',
        model: 'test-model',
      );

      expect(event.type, ProviderStreamEventType.done);
      expect(event.output, 'complete');
      expect(event.model, 'test-model');
    });

    test('error factory creates correct event', () {
      final error = RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'test error',
        source: 'test',
      );
      final event = ProviderStreamEvent.error(
        error: error,
        output: 'error output',
      );

      expect(event.type, ProviderStreamEventType.error);
      expect(event.error, error);
      expect(event.output, 'error output');
    });
  });
}
