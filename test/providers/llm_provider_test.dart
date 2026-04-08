import 'dart:convert';
import 'dart:io';

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
          effort: ClartCodeReasoningEffort.high,
        ),
      );

      expect(body['model'], 'gpt-5.3-codex');
      expect(body['reasoning'], {'effort': 'high'});
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

    test('builds native tool request and continuation payload', () {
      final body = buildOpenAiResponsesRequestBodyForTest(
        request: QueryRequest(
          messages: [
            ChatMessage(
              role: MessageRole.tool,
              text: jsonEncode({
                'tool_call_id': 'call_read_1',
                'tool': 'read',
                'ok': true,
                'output': 'file body',
              }),
            ),
          ],
          model: 'gpt-5.4',
          providerStateToken: 'resp_123',
          toolDefinitions: const [
            QueryToolDefinition(
              name: 'read',
              description: 'Read a file',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
                'required': ['path'],
              },
            ),
          ],
        ),
      );

      expect(body['model'], 'gpt-5.4');
      expect(body['previous_response_id'], 'resp_123');
      expect(body['tools'], isA<List>());
      final tools = body['tools'] as List;
      expect((tools.first as Map)['type'], 'function');
      expect((tools.first as Map)['name'], 'read');

      final input = body['input'] as List;
      expect(input, hasLength(1));
      expect((input.first as Map)['type'], 'function_call_output');
      expect((input.first as Map)['call_id'], 'call_read_1');
      expect((input.first as Map)['output'], 'file body');
    });

    test('builds responses api body with max tokens and json schema output',
        () {
      final body = buildOpenAiResponsesRequestBodyForTest(
        request: const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'return json'),
          ],
          model: 'gpt-5.4',
          maxTokens: 256,
          jsonSchema: ClartCodeJsonSchema(
            name: 'reply_schema',
            schema: {
              'type': 'object',
              'properties': {
                'answer': {'type': 'string'},
              },
              'required': ['answer'],
            },
          ),
        ),
      );

      expect(body['max_output_tokens'], 256);
      expect(body['text'], {
        'format': {
          'type': 'json_schema',
          'name': 'reply_schema',
          'schema': {
            'type': 'object',
            'properties': {
              'answer': {'type': 'string'},
            },
            'required': ['answer'],
          },
          'strict': true,
        },
      });
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

    test('parses responses stream completed event with native tool call', () {
      final events = parseOpenAiResponsesStreamPayloadEventsForTest(
        eventName: 'response.completed',
        rawPayload:
            '{"type":"response.completed","response":{"id":"resp_456","model":"gpt-5.4","output":[{"type":"function_call","id":"fc_1","call_id":"call_read_1","name":"read","arguments":"{\\"path\\":\\"/tmp/demo.txt\\"}"}]}}',
      );

      expect(events, hasLength(1));
      expect(events.first.type, ProviderStreamEventType.done);
      expect(events.first.output, '');
      expect(events.first.providerStateToken, 'resp_456');
      expect(events.first.toolCalls, hasLength(1));
      expect(events.first.toolCalls.first.id, 'call_read_1');
      expect(events.first.toolCalls.first.name, 'read');
      expect(events.first.toolCalls.first.input, {'path': '/tmp/demo.txt'});
    });

    test('parses responses stream completed event usage and cost', () {
      final events = parseOpenAiResponsesStreamPayloadEventsForTest(
        eventName: 'response.completed',
        rawPayload:
            '{"type":"response.completed","response":{"model":"gpt-5.4","usage":{"input_tokens":11,"output_tokens":5,"total_tokens":16,"input_tokens_details":{"cached_tokens":3},"output_tokens_details":{"reasoning_tokens":2},"total_cost":0.75},"output":[{"type":"message","content":[{"type":"output_text","text":"done text"}]}]}}',
      );

      expect(events, hasLength(1));
      expect(events.first.type, ProviderStreamEventType.done);
      expect(events.first.usage?.inputTokens, 11);
      expect(events.first.usage?.outputTokens, 5);
      expect(events.first.usage?.totalTokens, 16);
      expect(events.first.usage?.cachedInputTokens, 3);
      expect(events.first.usage?.reasoningTokens, 2);
      expect(events.first.costUsd, 0.75);
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

    test('stream falls back to non-stream responses when SSE fails', () async {
      HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      } on SocketException {
        return;
      }
      addTearDown(() async {
        await server.close(force: true);
      });

      var requestCount = 0;
      server.listen((request) async {
        requestCount += 1;
        final rawBody = await utf8.decoder.bind(request).join();
        final body = jsonDecode(rawBody) as Map<String, Object?>;
        final wantsStream = body['stream'] == true;

        request.response.statusCode = 200;
        if (wantsStream) {
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'text/event-stream',
          );
          request.response.write('event: response.failed\n');
          request.response.write(
            'data: {"type":"response.failed","response":{"model":"gpt-4o-mini-stream"}}\n\n',
          );
          await request.response.close();
          return;
        }

        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'model': 'gpt-4o-mini-run',
            'output': [
              {
                'type': 'message',
                'content': [
                  {
                    'type': 'output_text',
                    'text': 'fallback output',
                  },
                ],
              },
            ],
          }),
        );
        await request.response.close();
      });

      final provider = OpenAiApiProvider(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        model: 'gpt-4o-mini',
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in provider.stream(
        const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'hello'),
          ],
        ),
      )) {
        events.add(event);
      }

      expect(requestCount, 2);
      expect(events.map((event) => event.type), [
        ProviderStreamEventType.textDelta,
        ProviderStreamEventType.done,
      ]);
      expect(events.first.delta, 'fallback output');
      expect(events.last.output, 'fallback output');
      expect(events.last.model, 'gpt-4o-mini-run');
    });
  });

  group('Claude Messages helpers', () {
    test('builds native tool request body with assistant tool use and result',
        () {
      final body = buildClaudeRequestBodyForTest(
        request: QueryRequest(
          messages: [
            const ChatMessage(role: MessageRole.system, text: 'be concise'),
            const ChatMessage(role: MessageRole.user, text: 'read the file'),
            ChatMessage(
              role: MessageRole.assistant,
              text: jsonEncode({
                'text': 'using a tool',
                'tool_calls': [
                  {
                    'id': 'toolu_1',
                    'name': 'read',
                    'input': {'path': '/tmp/demo.txt'},
                  },
                ],
              }),
            ),
            ChatMessage(
              role: MessageRole.tool,
              text: jsonEncode({
                'tool_call_id': 'toolu_1',
                'tool': 'read',
                'ok': true,
                'output': 'demo body',
              }),
            ),
          ],
          model: 'claude-sonnet-4-6',
          toolDefinitions: const [
            QueryToolDefinition(
              name: 'read',
              description: 'Read a file',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
                'required': ['path'],
              },
            ),
          ],
        ),
      );

      expect(body['model'], 'claude-sonnet-4-6');
      expect(body['tools'], isA<List>());
      expect((body['tools'] as List).single, containsPair('name', 'read'));
      expect(body['system'], 'be concise');

      final messages = body['messages'] as List;
      expect(messages, hasLength(3));
      expect((messages[0] as Map)['role'], 'user');
      expect((messages[1] as Map)['role'], 'assistant');
      expect((messages[2] as Map)['role'], 'user');

      final assistantContent = (messages[1] as Map)['content'] as List;
      expect((assistantContent[0] as Map)['type'], 'text');
      expect((assistantContent[1] as Map)['type'], 'tool_use');
      expect((assistantContent[1] as Map)['id'], 'toolu_1');

      final toolResultContent = (messages[2] as Map)['content'] as List;
      expect((toolResultContent.single as Map)['type'], 'tool_result');
      expect((toolResultContent.single as Map)['tool_use_id'], 'toolu_1');
      expect((toolResultContent.single as Map)['content'], 'demo body');
    });

    test('claude request body honors max tokens thinking and system prompts',
        () {
      final body = buildClaudeRequestBodyForTest(
        request: const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'hello'),
          ],
          systemPrompt: 'prepend system',
          appendSystemPrompt: 'append system',
          maxTokens: 2048,
          thinking: ClartCodeThinkingConfig.enabled(budgetTokens: 512),
        ),
      );

      expect(body['max_tokens'], 2048);
      expect(body['thinking'], {
        'type': 'enabled',
        'budget_tokens': 512,
      });
      expect(body['system'], 'prepend system\nappend system');
    });

    test('run extracts native tool calls from Claude response', () async {
      HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      } on SocketException {
        return;
      }
      addTearDown(() async {
        await server.close(force: true);
      });

      Map<String, Object?>? capturedBody;
      server.listen((request) async {
        final rawBody = await utf8.decoder.bind(request).join();
        capturedBody = Map<String, Object?>.from(
          jsonDecode(rawBody) as Map<String, Object?>,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'msg_123',
            'model': 'claude-sonnet-4-6',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'read',
                'input': {'path': '/tmp/demo.txt'},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final provider = ClaudeApiProvider(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        model: 'claude-sonnet-4-6',
      );

      final response = await provider.run(
        const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'read the file'),
          ],
          toolDefinitions: [
            QueryToolDefinition(
              name: 'read',
              description: 'Read a file',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
              },
            ),
          ],
        ),
      );

      expect(response.isOk, isTrue);
      expect(response.output, '');
      expect(response.toolCalls, hasLength(1));
      expect(response.toolCalls.single.id, 'toolu_1');
      expect(response.toolCalls.single.name, 'read');
      expect(response.toolCalls.single.input, {'path': '/tmp/demo.txt'});
      expect(capturedBody, isNotNull);
      expect(capturedBody!['tools'], isA<List>());
    });

    test('stream parses native tool calls from Claude SSE events', () async {
      HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      } on SocketException {
        return;
      }
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream',
        );

        void writeEvent(String event, Map<String, Object?> data) {
          request.response.write('event: $event\n');
          request.response.write('data: ${jsonEncode(data)}\n\n');
        }

        writeEvent('message_start', {
          'type': 'message_start',
          'message': {
            'id': 'msg_stream_1',
            'model': 'claude-sonnet-4-6',
          },
        });
        writeEvent('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'text',
            'text': '',
          },
        });
        writeEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'text_delta',
            'text': 'using tool',
          },
        });
        writeEvent('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        });
        writeEvent('content_block_start', {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_stream_1',
            'name': 'read',
            'input': <String, Object?>{},
          },
        });
        writeEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"path":"',
          },
        });
        writeEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '/tmp/demo.txt"}',
          },
        });
        writeEvent('content_block_stop', {
          'type': 'content_block_stop',
          'index': 1,
        });
        writeEvent('message_delta', {
          'type': 'message_delta',
          'delta': {
            'stop_reason': 'tool_use',
          },
        });
        writeEvent('message_stop', {
          'type': 'message_stop',
        });
        await request.response.close();
      });

      final provider = ClaudeApiProvider(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        model: 'claude-sonnet-4-6',
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in provider.stream(
        const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'read the file'),
          ],
          toolDefinitions: [
            QueryToolDefinition(
              name: 'read',
              description: 'Read a file',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
              },
            ),
          ],
        ),
      )) {
        events.add(event);
      }

      expect(events.map((event) => event.type), [
        ProviderStreamEventType.textDelta,
        ProviderStreamEventType.done,
      ]);
      expect(events.first.delta, 'using tool');
      expect(events.last.output, 'using tool');
      expect(events.last.model, 'claude-sonnet-4-6');
      expect(events.last.toolCalls, hasLength(1));
      expect(events.last.toolCalls.single.id, 'toolu_stream_1');
      expect(events.last.toolCalls.single.name, 'read');
      expect(events.last.toolCalls.single.input, {'path': '/tmp/demo.txt'});
    });

    test('Claude stream can emit rate-limit and raw stream events', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream',
        );
        request.response.headers.set(
          'anthropic-ratelimit-requests-remaining',
          '17',
        );

        void writeEvent(String event, Map<String, Object?> data) {
          request.response.write('event: $event\n');
          request.response.write('data: ${jsonEncode(data)}\n\n');
        }

        writeEvent('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {
            'type': 'text_delta',
            'text': 'hello',
          },
        });
        writeEvent('message_stop', {
          'type': 'message_stop',
        });
        await request.response.close();
      });

      final provider = ClaudeApiProvider(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        model: 'claude-sonnet-4-6',
      );

      final events = <ProviderStreamEvent>[];
      await for (final event in provider.stream(
        const QueryRequest(
          messages: [
            ChatMessage(role: MessageRole.user, text: 'hello'),
          ],
          includeObservabilityMessages: true,
        ),
      )) {
        events.add(event);
      }

      expect(events.map((event) => event.type), [
        ProviderStreamEventType.rateLimit,
        ProviderStreamEventType.streamEvent,
        ProviderStreamEventType.textDelta,
        ProviderStreamEventType.streamEvent,
        ProviderStreamEventType.done,
      ]);
      expect(events.first.rateLimitInfo?.provider, 'claude');
      expect(events.first.rateLimitInfo?.requestsRemaining, '17');
      expect(events[1].event?['type'], 'content_block_delta');
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

    test('streamEvent and rateLimit factories create correct events', () {
      final streamEvent = ProviderStreamEvent.streamEvent(
        event: const {'type': 'delta'},
        model: 'test-model',
      );
      final rateLimitEvent = ProviderStreamEvent.rateLimit(
        rateLimitInfo: const QueryRateLimitInfo(
          provider: 'test',
          status: 'ok',
          requestsRemaining: '8',
        ),
      );

      expect(streamEvent.type, ProviderStreamEventType.streamEvent);
      expect(streamEvent.event, {'type': 'delta'});
      expect(streamEvent.model, 'test-model');
      expect(rateLimitEvent.type, ProviderStreamEventType.rateLimit);
      expect(rateLimitEvent.rateLimitInfo?.requestsRemaining, '8');
    });
  });
}
