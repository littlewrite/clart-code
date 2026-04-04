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

  group('OpenAI Responses helpers', () {
    test('builds responses api body from transcript messages', () {
      final body = buildOpenAiResponsesRequestBodyForTest(
        request: const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.system, text: 'be concise'),
            ChatMessage(role: MessageRole.user, text: 'hello'),
            ChatMessage(role: MessageRole.assistant, text: 'hi'),
            ChatMessage(role: MessageRole.tool, text: 'tool result'),
          ],
          model: 'gpt-5.3-codex',
        ),
      );

      expect(body['model'], 'gpt-5.3-codex');
      expect(body['input'], isA<List>());
      final input = body['input'] as List;
      expect(input, hasLength(4));
      expect((input[0] as Map)['role'], 'system');
      expect((((input[0] as Map)['content'] as List).first as Map)['text'],
          'be concise');
      expect((((input[0] as Map)['content'] as List).first as Map)['type'],
          'input_text');
      expect((input[2] as Map)['role'], 'assistant');
      expect((((input[2] as Map)['content'] as List).first as Map)['type'],
          'output_text');
      expect((input[3] as Map)['role'], 'user');
      expect((((input[3] as Map)['content'] as List).first as Map)['text'],
          '[tool] tool result');
    });

    test('extracts text from responses api output array', () {
      final text = extractOpenAiResponsesOutputForTest({
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'hello'},
              {'type': 'output_text', 'text': 'world'},
            ],
          },
        ],
      });

      expect(text, 'hello\nworld');
    });

    test('prefers top-level output_text when present', () {
      final text = extractOpenAiResponsesOutputForTest({
        'output_text': 'top level text',
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'ignored'},
            ],
          },
        ],
      });

      expect(text, 'top level text');
    });

    test('extracts refusal text from responses api output array', () {
      final text = extractOpenAiResponsesOutputForTest({
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'refusal', 'refusal': 'cannot comply'},
            ],
          },
        ],
      });

      expect(text, 'cannot comply');
    });

    test('parses responses stream delta event', () {
      final events = parseOpenAiResponsesStreamPayloadEventsForTest(
        eventName: 'response.output_text.delta',
        rawPayload: '{"type":"response.output_text.delta","delta":"hel"}',
      );

      expect(events, hasLength(1));
      expect(events.first.type, ProviderStreamEventType.textDelta);
      expect(events.first.delta, 'hel');
    });

    test('parses responses stream completed event', () {
      final events = parseOpenAiResponsesStreamPayloadEventsForTest(
        eventName: 'response.completed',
        rawPayload:
            '{"type":"response.completed","response":{"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"done text"}]}]}}',
      );

      expect(events, hasLength(1));
      expect(events.first.type, ProviderStreamEventType.done);
      expect(events.first.output, 'done text');
      expect(events.first.model, 'gpt-5.4');
    });

    test('parses responses refusal delta event', () {
      final events = parseOpenAiResponsesStreamPayloadEventsForTest(
        eventName: 'response.refusal.delta',
        rawPayload: '{"type":"response.refusal.delta","delta":"cannot"}',
      );

      expect(events, hasLength(1));
      expect(events.first.type, ProviderStreamEventType.textDelta);
      expect(events.first.delta, 'cannot');
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
