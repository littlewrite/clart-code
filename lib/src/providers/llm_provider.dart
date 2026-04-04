import 'dart:convert';
import 'dart:io';

import 'package:dart_openai/dart_openai.dart';

import '../core/models.dart';
import '../core/runtime_error.dart';

enum ProviderStreamEventType { textDelta, done, error }

class ProviderStreamEvent {
  const ProviderStreamEvent({
    required this.type,
    this.delta,
    this.output,
    this.model,
    this.error,
  });

  final ProviderStreamEventType type;
  final String? delta;
  final String? output;
  final String? model;
  final RuntimeError? error;

  factory ProviderStreamEvent.textDelta({
    required String delta,
    String? model,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.textDelta,
      delta: delta,
      model: model,
    );
  }

  factory ProviderStreamEvent.done({
    required String output,
    String? model,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.done,
      output: output,
      model: model,
    );
  }

  factory ProviderStreamEvent.error({
    required RuntimeError error,
    String? output,
    String? model,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.error,
      error: error,
      output: output,
      model: model,
    );
  }
}

abstract class LlmProvider {
  Future<QueryResponse> run(QueryRequest request);

  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    final response = await run(request);
    if (response.isOk) {
      if (response.output.isNotEmpty) {
        yield ProviderStreamEvent.textDelta(
          delta: response.output,
          model: response.modelUsed,
        );
      }
      yield ProviderStreamEvent.done(
        output: response.output,
        model: response.modelUsed,
      );
      return;
    }

    yield ProviderStreamEvent.error(
      error: response.error ??
          const RuntimeError(
            code: RuntimeErrorCode.unknown,
            message: 'provider stream failed',
            source: 'provider_stream',
            retriable: false,
          ),
      output: response.output,
      model: response.modelUsed,
    );
  }
}

class LocalEchoProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    final text = request.messages
        .where((m) => m.role == MessageRole.user)
        .map((m) => m.text)
        .join('\n');

    return QueryResponse.success(
      output: text.isEmpty ? '[empty-input]' : 'echo: $text',
      modelUsed: 'local-echo',
    );
  }
}

class ClaudeApiProvider extends LlmProvider {
  ClaudeApiProvider({required this.apiKey, this.baseUrl, this.model});

  final String apiKey;
  final String? baseUrl;
  final String? model;

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    final requestedModel = _resolveClaudeModel(request);
    if (apiKey.trim().isEmpty) {
      yield ProviderStreamEvent.error(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'CLAUDE_API_KEY is required for claude provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing CLAUDE_API_KEY for claude provider',
        model: requestedModel,
      );
      return;
    }

    final client = HttpClient();
    final outputBuffer = StringBuffer();
    var modelUsed = requestedModel;
    var emittedTerminalEvent = false;

    try {
      final uri = _buildClaudeUri(baseUrl);
      final body = _buildClaudeRequestBody(request)..['stream'] = true;
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers.set('x-api-key', apiKey);
      httpRequest.headers.set('anthropic-version', _anthropicApiVersion);
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close();
      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        final responseText = await httpResponse.transform(utf8.decoder).join();
        final responseMap = _decodeJsonObject(responseText);
        yield ProviderStreamEvent.error(
          error: RuntimeError(
            code: _mapClaudeHttpCode(httpResponse.statusCode),
            message: _extractClaudeErrorMessage(
              responseMap: responseMap,
              fallbackStatusCode: httpResponse.statusCode,
            ),
            source: 'claude_http',
            retriable: httpResponse.statusCode >= 500,
          ),
          output: '[ERROR] Claude request failed',
          model: modelUsed,
        );
        return;
      }

      String? eventName;
      final dataLines = <String>[];

      await for (final line in httpResponse
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trimRight();
        if (trimmed.isEmpty) {
          if (dataLines.isNotEmpty) {
            final parsed = _parseClaudeStreamPayload(
              rawPayload: dataLines.join('\n').trim(),
              eventName: eventName,
              currentModel: modelUsed,
              outputBuffer: outputBuffer,
            );
            dataLines.clear();
            modelUsed = parsed.modelUsed;
            for (final event in parsed.events) {
              yield event;
            }
            if (parsed.terminal) {
              emittedTerminalEvent = true;
              break;
            }
          }
          eventName = null;
          continue;
        }
        if (trimmed.startsWith('event:')) {
          eventName = trimmed.substring(6).trim();
          continue;
        }
        if (trimmed.startsWith('data:')) {
          dataLines.add(trimmed.substring(5).trim());
        }
      }

      if (!emittedTerminalEvent && dataLines.isNotEmpty) {
        final parsed = _parseClaudeStreamPayload(
          rawPayload: dataLines.join('\n').trim(),
          eventName: eventName,
          currentModel: modelUsed,
          outputBuffer: outputBuffer,
        );
        modelUsed = parsed.modelUsed;
        for (final event in parsed.events) {
          yield event;
        }
        emittedTerminalEvent = parsed.terminal;
      }

      if (!emittedTerminalEvent) {
        final output = outputBuffer.toString();
        yield ProviderStreamEvent.done(
          output: output.isEmpty ? '[empty-output]' : output,
          model: modelUsed,
        );
      }
    } catch (error) {
      yield ProviderStreamEvent.error(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'claude_stream',
          retriable: true,
        ),
        output: '[ERROR] Claude request failed',
        model: modelUsed,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    final requestedModel = _resolveClaudeModel(request);
    if (apiKey.trim().isEmpty) {
      return QueryResponse.failure(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'CLAUDE_API_KEY is required for claude provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing CLAUDE_API_KEY for claude provider',
        modelUsed: requestedModel,
      );
    }

    final client = HttpClient();
    try {
      final uri = _buildClaudeUri(baseUrl);
      final body = _buildClaudeRequestBody(request);
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers.set('x-api-key', apiKey);
      httpRequest.headers.set('anthropic-version', _anthropicApiVersion);
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close();
      final responseText = await httpResponse.transform(utf8.decoder).join();
      final responseMap = _decodeJsonObject(responseText);

      if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
        final output = _extractClaudeOutput(responseMap);
        return QueryResponse.success(
          output: output.isEmpty ? '[empty-output]' : output,
          modelUsed: responseMap['model'] as String? ?? requestedModel,
        );
      }

      return QueryResponse.failure(
        error: RuntimeError(
          code: _mapClaudeHttpCode(httpResponse.statusCode),
          message: _extractClaudeErrorMessage(
            responseMap: responseMap,
            fallbackStatusCode: httpResponse.statusCode,
          ),
          source: 'claude_http',
          retriable: httpResponse.statusCode >= 500,
        ),
        output: '[ERROR] Claude request failed',
        modelUsed: requestedModel,
      );
    } catch (error) {
      return QueryResponse.failure(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'claude_http',
          retriable: true,
        ),
        output: '[ERROR] Claude request failed',
        modelUsed: requestedModel,
      );
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildClaudeUri(String? configuredBaseUrl) {
    final rawBase =
        (configuredBaseUrl == null || configuredBaseUrl.trim().isEmpty)
            ? _defaultClaudeBaseUrl
            : configuredBaseUrl.trim();
    final normalizedBase = rawBase.endsWith('/')
        ? rawBase.substring(0, rawBase.length - 1)
        : rawBase;
    final endpoint =
        normalizedBase.endsWith('/v1') ? '/messages' : '/v1/messages';
    return Uri.parse('$normalizedBase$endpoint');
  }

  Map<String, Object?> _buildClaudeRequestBody(QueryRequest request) {
    final systemMessages = <String>[];
    final messages = <Map<String, Object?>>[];

    for (final message in request.messages) {
      switch (message.role) {
        case MessageRole.system:
          systemMessages.add(message.text);
          break;
        case MessageRole.user:
          messages.add({'role': 'user', 'content': message.text});
          break;
        case MessageRole.assistant:
          messages.add({'role': 'assistant', 'content': message.text});
          break;
        case MessageRole.tool:
          messages.add({'role': 'user', 'content': '[tool] ${message.text}'});
          break;
      }
    }

    if (messages.isEmpty) {
      messages.add({'role': 'user', 'content': ''});
    }

    return {
      'model': _resolveClaudeModel(request),
      'max_tokens': _defaultClaudeMaxTokens,
      if (systemMessages.isNotEmpty) 'system': systemMessages.join('\n'),
      'messages': messages,
    };
  }

  String _resolveClaudeModel(QueryRequest request) {
    return request.model ?? model ?? _defaultClaudeModel;
  }

  Map<String, Object?> _decodeJsonObject(String raw) {
    if (raw.trim().isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return const {};
  }

  String _extractClaudeOutput(Map<String, Object?> responseMap) {
    final content = responseMap['content'];
    if (content is! List) {
      return '';
    }

    return content
        .whereType<Map>()
        .where((block) => block['type'] == 'text' && block['text'] is String)
        .map((block) => block['text'] as String)
        .join('\n')
        .trim();
  }

  String _extractClaudeDeltaText(Map<String, Object?> eventPayload) {
    final type = eventPayload['type'];
    if (type != 'content_block_delta') {
      return '';
    }
    final delta = eventPayload['delta'];
    if (delta is! Map<String, dynamic>) {
      return '';
    }
    final text = delta['text'];
    if (text is! String) {
      return '';
    }
    return text;
  }

  String? _extractClaudeModel(Map<String, Object?> eventPayload) {
    final message = eventPayload['message'];
    if (message is! Map<String, dynamic>) {
      return null;
    }
    final model = message['model'];
    if (model is! String || model.isEmpty) {
      return null;
    }
    return model;
  }

  _ClaudeStreamPayloadParseResult _parseClaudeStreamPayload({
    required String rawPayload,
    required String? eventName,
    required String currentModel,
    required StringBuffer outputBuffer,
  }) {
    if (rawPayload.isEmpty) {
      return _ClaudeStreamPayloadParseResult(
        modelUsed: currentModel,
        events: const [],
        terminal: false,
      );
    }

    final payload = _decodeJsonObject(rawPayload);
    final payloadType = payload['type'] as String?;
    final effectiveType = payloadType ?? eventName;
    var modelUsed = currentModel;
    final events = <ProviderStreamEvent>[];
    var terminal = false;

    if (payloadType == 'error' || eventName == 'error') {
      events.add(
        ProviderStreamEvent.error(
          error: RuntimeError(
            code: RuntimeErrorCode.providerFailure,
            message: _extractClaudeErrorMessage(
              responseMap: payload,
              fallbackStatusCode: 500,
            ),
            source: 'claude_stream',
            retriable: true,
          ),
          output: '[ERROR] Claude request failed',
          model: modelUsed,
        ),
      );
      terminal = true;
      return _ClaudeStreamPayloadParseResult(
        modelUsed: modelUsed,
        events: events,
        terminal: terminal,
      );
    }

    final startedModel = _extractClaudeModel(payload);
    if (startedModel != null && startedModel.isNotEmpty) {
      modelUsed = startedModel;
    }

    final deltaText = _extractClaudeDeltaText(payload);
    if (deltaText.isNotEmpty) {
      outputBuffer.write(deltaText);
      events.add(
        ProviderStreamEvent.textDelta(
          delta: deltaText,
          model: modelUsed,
        ),
      );
    }

    if (effectiveType == 'message_stop') {
      final output = outputBuffer.toString();
      events.add(
        ProviderStreamEvent.done(
          output: output.isEmpty ? '[empty-output]' : output,
          model: modelUsed,
        ),
      );
      terminal = true;
    }

    return _ClaudeStreamPayloadParseResult(
      modelUsed: modelUsed,
      events: events,
      terminal: terminal,
    );
  }

  String _extractClaudeErrorMessage({
    required Map<String, Object?> responseMap,
    required int fallbackStatusCode,
  }) {
    final errorObj = responseMap['error'];
    if (errorObj is Map<String, dynamic>) {
      final message = errorObj['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }
    return 'Claude request failed with status $fallbackStatusCode';
  }

  RuntimeErrorCode _mapClaudeHttpCode(int statusCode) {
    if (statusCode == 400) {
      return RuntimeErrorCode.invalidInput;
    }
    if (statusCode == 401 || statusCode == 403) {
      return RuntimeErrorCode.permissionDenied;
    }
    return RuntimeErrorCode.providerFailure;
  }
}

const String _defaultClaudeBaseUrl = 'https://api.anthropic.com';
const String _anthropicApiVersion = '2023-06-01';
const String _defaultClaudeModel = 'claude-3-5-sonnet-latest';
const int _defaultClaudeMaxTokens = 1024;

class _ClaudeStreamPayloadParseResult {
  const _ClaudeStreamPayloadParseResult({
    required this.modelUsed,
    required this.events,
    required this.terminal,
  });

  final String modelUsed;
  final List<ProviderStreamEvent> events;
  final bool terminal;
}

class OpenAiApiProvider extends LlmProvider {
  OpenAiApiProvider({
    required this.apiKey,
    this.baseUrl,
    this.model,
  });

  final String apiKey;
  final String? baseUrl;
  final String? model;

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    final chosenModel = request.model ?? model ?? 'gpt-4o-mini';
    if (apiKey.trim().isEmpty) {
      yield ProviderStreamEvent.error(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'OPENAI_API_KEY is required for openai provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing OPENAI_API_KEY for openai provider',
        model: chosenModel,
      );
      return;
    }

    OpenAI.apiKey = apiKey;
    OpenAI.showLogs = false;
    OpenAI.showResponsesLogs = false;
    if (baseUrl != null && baseUrl!.trim().isNotEmpty) {
      OpenAI.baseUrl = baseUrl!;
    }

    final messages = request.messages.map(_toOpenAiMessage).toList();
    final outputBuffer = StringBuffer();

    try {
      final stream = OpenAI.instance.chat.createStream(
        model: chosenModel,
        messages: messages,
      );
      await for (final chunk in stream) {
        final deltaText = chunk.choices
            .map((choice) => choice.delta.content ?? const [])
            .expand((items) => items)
            .map((item) => item?.text ?? '')
            .where((text) => text.isNotEmpty)
            .join();

        if (deltaText.isEmpty) {
          continue;
        }

        outputBuffer.write(deltaText);
        yield ProviderStreamEvent.textDelta(
          delta: deltaText,
          model: chosenModel,
        );
      }

      final output = outputBuffer.toString();
      yield ProviderStreamEvent.done(
        output: output.isEmpty ? '[empty-output]' : output,
        model: chosenModel,
      );
    } catch (error) {
      yield ProviderStreamEvent.error(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'openai_sdk_stream',
          retriable: true,
        ),
        output: '[ERROR] OpenAI request failed',
        model: chosenModel,
      );
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    final chosenModel = request.model ?? model ?? 'gpt-4o-mini';
    if (apiKey.trim().isEmpty) {
      return QueryResponse.failure(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'OPENAI_API_KEY is required for openai provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing OPENAI_API_KEY for openai provider',
        modelUsed: chosenModel,
      );
    }

    OpenAI.apiKey = apiKey;
    OpenAI.showLogs = false;
    OpenAI.showResponsesLogs = false;
    if (baseUrl != null && baseUrl!.trim().isNotEmpty) {
      OpenAI.baseUrl = baseUrl!;
    }

    final messages = request.messages.map(_toOpenAiMessage).toList();

    try {
      final completion = await OpenAI.instance.chat.create(
        model: chosenModel,
        messages: messages,
      );
      final text = completion.choices
          .map((choice) => choice.message.content ?? const [])
          .expand((items) => items)
          .map((item) => item.text ?? '')
          .where((text) => text.isNotEmpty)
          .join('\n');

      return QueryResponse.success(
        output: text.isEmpty ? '[empty-output]' : text,
        modelUsed: chosenModel,
      );
    } catch (error) {
      return QueryResponse.failure(
        error: RuntimeError(
          code: RuntimeErrorCode.providerFailure,
          message: '$error',
          source: 'openai_sdk',
          retriable: true,
        ),
        output: '[ERROR] OpenAI request failed',
        modelUsed: chosenModel,
      );
    }
  }

  OpenAIChatCompletionChoiceMessageModel _toOpenAiMessage(ChatMessage message) {
    return OpenAIChatCompletionChoiceMessageModel(
      role: _toOpenAiRole(message.role),
      content: [
        OpenAIChatCompletionChoiceMessageContentItemModel.text(message.text),
      ],
    );
  }

  OpenAIChatMessageRole _toOpenAiRole(MessageRole role) {
    switch (role) {
      case MessageRole.system:
        return OpenAIChatMessageRole.system;
      case MessageRole.user:
        return OpenAIChatMessageRole.user;
      case MessageRole.assistant:
        return OpenAIChatMessageRole.assistant;
      case MessageRole.tool:
        return OpenAIChatMessageRole.tool;
    }
  }
}
