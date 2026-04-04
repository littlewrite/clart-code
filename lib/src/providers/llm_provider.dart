import 'dart:convert';
import 'dart:io';

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

Map<String, Object?> buildClaudeRequestBodyForTest({
  required QueryRequest request,
  String? fallbackModel,
}) {
  return _buildClaudeRequestBodyPayload(
    request: request,
    fallbackModel: fallbackModel,
  );
}

Map<String, Object?> buildOpenAiResponsesRequestBodyForTest({
  required QueryRequest request,
  String? fallbackModel,
}) {
  return _buildOpenAiResponsesRequestBodyPayload(
    request: request,
    fallbackModel: fallbackModel,
  );
}

String extractOpenAiResponsesOutputForTest(Map<String, Object?> responseMap) {
  return _extractOpenAiResponsesOutput(responseMap);
}

List<ProviderStreamEvent> parseOpenAiResponsesStreamPayloadEventsForTest({
  required String rawPayload,
  String? eventName,
  String currentModel = 'test-model',
}) {
  final result = _parseOpenAiResponsesStreamPayload(
    rawPayload: rawPayload,
    eventName: eventName,
    currentModel: currentModel,
    outputBuffer: StringBuffer(),
  );
  return result.events;
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
        final runtimeError = RuntimeError(
          code: _mapClaudeHttpCode(httpResponse.statusCode),
          message: _extractClaudeErrorMessage(
            responseMap: responseMap,
            fallbackStatusCode: httpResponse.statusCode,
          ),
          source: 'claude_http',
          retriable: httpResponse.statusCode >= 500,
        );
        yield ProviderStreamEvent.error(
          error: runtimeError,
          output: _formatClaudeErrorOutput(
            runtimeError,
            statusCode: httpResponse.statusCode,
          ),
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
      final runtimeError = _mapClaudeTransportError(
        error,
        source: 'claude_stream',
      );
      yield ProviderStreamEvent.error(
        error: runtimeError,
        output: _formatClaudeErrorOutput(runtimeError),
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

      final runtimeError = RuntimeError(
        code: _mapClaudeHttpCode(httpResponse.statusCode),
        message: _extractClaudeErrorMessage(
          responseMap: responseMap,
          fallbackStatusCode: httpResponse.statusCode,
        ),
        source: 'claude_http',
        retriable: httpResponse.statusCode >= 500,
      );
      return QueryResponse.failure(
        error: runtimeError,
        output: _formatClaudeErrorOutput(
          runtimeError,
          statusCode: httpResponse.statusCode,
        ),
        modelUsed: requestedModel,
      );
    } catch (error) {
      final runtimeError = _mapClaudeTransportError(
        error,
        source: 'claude_http',
      );
      return QueryResponse.failure(
        error: runtimeError,
        output: _formatClaudeErrorOutput(runtimeError),
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
    return _buildClaudeRequestBodyPayload(
      request: request,
      fallbackModel: model,
    );
  }

  String _resolveClaudeModel(QueryRequest request) {
    return request.model ?? model ?? _defaultClaudeModel;
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
      final runtimeError = RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: _extractClaudeErrorMessage(
          responseMap: payload,
          fallbackStatusCode: 500,
        ),
        source: 'claude_stream',
        retriable: true,
      );
      events.add(
        ProviderStreamEvent.error(
          error: runtimeError,
          output: _formatClaudeErrorOutput(runtimeError),
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

  RuntimeError _mapClaudeTransportError(
    Object error, {
    required String source,
  }) {
    if (error is SocketException) {
      return RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message:
            'Network error while reaching Claude API. Check your base URL, proxy, or internet connection.',
        source: source,
        retriable: true,
      );
    }
    if (error is HandshakeException) {
      return RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message:
            'TLS handshake failed while reaching Claude API. Check HTTPS certificates or the configured base URL.',
        source: source,
        retriable: true,
      );
    }
    return RuntimeError(
      code: RuntimeErrorCode.providerFailure,
      message: '$error',
      source: source,
      retriable: true,
    );
  }

  String _formatClaudeErrorOutput(
    RuntimeError error, {
    int? statusCode,
  }) {
    if (error.message.contains('thinking type should be enabled or disabled')) {
      return '[ERROR] Claude-compatible endpoint rejected the request thinking mode. Clart now sends thinking=disabled by default; re-check the selected model/base URL if this continues.';
    }
    if (statusCode != null) {
      if (statusCode == 400) {
        return '[ERROR] Claude request was rejected (HTTP 400): ${error.message}';
      }
      if (statusCode == 401 || statusCode == 403) {
        return '[ERROR] Claude authentication failed (HTTP $statusCode). Check your API key and base URL.';
      }
      if (statusCode == 404) {
        return '[ERROR] Claude endpoint not found (HTTP 404). Check whether the configured base URL points to a Claude-compatible /v1/messages endpoint.';
      }
      if (statusCode == 405) {
        return '[ERROR] Claude endpoint rejected the HTTP method (HTTP 405). Check whether the configured base URL is correct.';
      }
      if (statusCode == 408 || statusCode == 429) {
        return '[ERROR] Claude request was throttled or timed out (HTTP $statusCode): ${error.message}';
      }
      if (statusCode >= 500) {
        return '[ERROR] Claude API/network error (HTTP $statusCode): ${error.message}';
      }
      return '[ERROR] Claude request failed (HTTP $statusCode): ${error.message}';
    }
    if (error.code == RuntimeErrorCode.permissionDenied) {
      return '[ERROR] Claude authentication failed. Check your API key and base URL.';
    }
    if (error.message.contains('invalid x-api-key')) {
      return '[ERROR] Claude authentication failed. Check your API key.';
    }
    if (error.message.contains('Network error while reaching Claude API') ||
        error.message
            .contains('TLS handshake failed while reaching Claude API')) {
      return '[ERROR] Could not reach Claude API. Check your network and base URL.';
    }
    return '[ERROR] Could not reach Claude API. Check your network and base URL.';
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
const String _defaultClaudeModel = 'claude-sonnet-4-6';
const int _defaultClaudeMaxTokens = 1024;

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

Map<String, Object?> _buildClaudeRequestBodyPayload({
  required QueryRequest request,
  String? fallbackModel,
}) {
  final resolvedModel = request.model ?? fallbackModel ?? _defaultClaudeModel;
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
    'model': resolvedModel,
    'max_tokens': _defaultClaudeMaxTokens,
    'thinking': const {'type': 'disabled'},
    if (systemMessages.isNotEmpty) 'system': systemMessages.join('\n'),
    'messages': messages,
  };
}

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

    final client = HttpClient();
    final outputBuffer = StringBuffer();
    var modelUsed = chosenModel;
    var emittedTerminalEvent = false;

    try {
      final uri = _buildOpenAiResponsesUri(baseUrl);
      final body = _buildOpenAiResponsesRequestBody(request)..['stream'] = true;
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close();
      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        final responseText = await httpResponse.transform(utf8.decoder).join();
        final responseMap = _decodeJsonObject(responseText);
        final runtimeError = RuntimeError(
          code: _mapOpenAiHttpCode(httpResponse.statusCode),
          message: _extractOpenAiErrorMessage(
            responseMap: responseMap,
            fallbackStatusCode: httpResponse.statusCode,
          ),
          source: 'openai_http',
          retriable: httpResponse.statusCode >= 500,
        );
        yield ProviderStreamEvent.error(
          error: runtimeError,
          output: _formatOpenAiErrorOutput(
            runtimeError,
            statusCode: httpResponse.statusCode,
          ),
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
            final parsed = _parseOpenAiResponsesStreamPayload(
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
        final parsed = _parseOpenAiResponsesStreamPayload(
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
      final runtimeError = _mapOpenAiTransportError(
        error,
        source: 'openai_stream',
      );
      yield ProviderStreamEvent.error(
        error: runtimeError,
        output: _formatOpenAiErrorOutput(runtimeError),
        model: modelUsed,
      );
    } finally {
      client.close(force: true);
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

    final client = HttpClient();

    try {
      final uri = _buildOpenAiResponsesUri(baseUrl);
      final body = _buildOpenAiResponsesRequestBody(request);
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close();
      final responseText = await httpResponse.transform(utf8.decoder).join();
      final responseMap = _decodeJsonObject(responseText);

      if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
        final output = _extractOpenAiResponsesOutput(responseMap);
        return QueryResponse.success(
          output: output.isEmpty ? '[empty-output]' : output,
          modelUsed: responseMap['model'] as String? ?? chosenModel,
        );
      }

      final runtimeError = RuntimeError(
        code: _mapOpenAiHttpCode(httpResponse.statusCode),
        message: _extractOpenAiErrorMessage(
          responseMap: responseMap,
          fallbackStatusCode: httpResponse.statusCode,
        ),
        source: 'openai_http',
        retriable: httpResponse.statusCode >= 500,
      );

      return QueryResponse.failure(
        error: runtimeError,
        output: _formatOpenAiErrorOutput(
          runtimeError,
          statusCode: httpResponse.statusCode,
        ),
        modelUsed: chosenModel,
      );
    } catch (error) {
      final runtimeError = _mapOpenAiTransportError(
        error,
        source: 'openai_http',
      );
      return QueryResponse.failure(
        error: runtimeError,
        output: _formatOpenAiErrorOutput(runtimeError),
        modelUsed: chosenModel,
      );
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildOpenAiResponsesUri(String? configuredBaseUrl) {
    final rawBase =
        (configuredBaseUrl == null || configuredBaseUrl.trim().isEmpty)
            ? _defaultOpenAiBaseUrl
            : configuredBaseUrl.trim();
    final normalizedBase = rawBase.endsWith('/')
        ? rawBase.substring(0, rawBase.length - 1)
        : rawBase;
    final endpoint =
        normalizedBase.endsWith('/v1') ? '/responses' : '/v1/responses';
    return Uri.parse('$normalizedBase$endpoint');
  }

  Map<String, Object?> _buildOpenAiResponsesRequestBody(QueryRequest request) {
    return _buildOpenAiResponsesRequestBodyPayload(
      request: request,
      fallbackModel: model,
    );
  }
}

const String _defaultOpenAiBaseUrl = 'https://api.openai.com';

class _OpenAiResponsesStreamPayloadParseResult {
  const _OpenAiResponsesStreamPayloadParseResult({
    required this.modelUsed,
    required this.events,
    required this.terminal,
  });

  final String modelUsed;
  final List<ProviderStreamEvent> events;
  final bool terminal;
}

Map<String, Object?> _buildOpenAiResponsesRequestBodyPayload({
  required QueryRequest request,
  String? fallbackModel,
}) {
  final resolvedModel = request.model ?? fallbackModel ?? 'gpt-4o-mini';
  final input = <Map<String, Object?>>[];

  for (final message in request.messages) {
    final text = switch (message.role) {
      MessageRole.tool => '[tool] ${message.text}',
      _ => message.text,
    };

    input.add({
      'role': _toOpenAiResponsesRole(message.role),
      'content': [
        {
          'type': _toOpenAiResponsesContentType(message.role),
          'text': text,
        },
      ],
    });
  }

  if (input.isEmpty) {
    input.add({
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': ''},
      ],
    });
  }

  return {
    'model': resolvedModel,
    'input': input,
  };
}

String _toOpenAiResponsesRole(MessageRole role) {
  switch (role) {
    case MessageRole.system:
      return 'system';
    case MessageRole.user:
      return 'user';
    case MessageRole.assistant:
      return 'assistant';
    case MessageRole.tool:
      return 'user';
  }
}

String _toOpenAiResponsesContentType(MessageRole role) {
  switch (role) {
    case MessageRole.assistant:
      return 'output_text';
    case MessageRole.system:
    case MessageRole.user:
    case MessageRole.tool:
      return 'input_text';
  }
}

String _extractOpenAiResponsesOutput(Map<String, Object?> responseMap) {
  final nestedResponse = responseMap['response'];
  if (nestedResponse is Map<String, dynamic>) {
    final nestedOutput = _extractOpenAiResponsesOutput(
      Map<String, Object?>.from(nestedResponse),
    );
    if (nestedOutput.isNotEmpty) {
      return nestedOutput;
    }
  }

  final directText = responseMap['output_text'];
  if (directText is String && directText.trim().isNotEmpty) {
    return directText.trim();
  }

  final output = responseMap['output'];
  if (output is! List) {
    return '';
  }

  final chunks = <String>[];
  for (final item in output.whereType<Map>()) {
    final content = item['content'];
    if (content is! List) {
      continue;
    }
    for (final part in content.whereType<Map>()) {
      final text = part['text'];
      if (text is String && text.isNotEmpty) {
        chunks.add(text);
        continue;
      }
      final refusal = part['refusal'];
      if (refusal is String && refusal.isNotEmpty) {
        chunks.add(refusal);
      }
    }
  }
  return chunks.join('\n').trim();
}

String? _extractOpenAiResponsesModel(Map<String, Object?> responseMap) {
  final response = responseMap['response'];
  if (response is Map<String, dynamic>) {
    final model = response['model'];
    if (model is String && model.isNotEmpty) {
      return model;
    }
  }
  final model = responseMap['model'];
  if (model is String && model.isNotEmpty) {
    return model;
  }
  return null;
}

String _extractOpenAiResponsesDeltaText(Map<String, Object?> responseMap) {
  final delta = responseMap['delta'];
  if (delta is String && delta.isNotEmpty) {
    return delta;
  }
  return '';
}

_OpenAiResponsesStreamPayloadParseResult _parseOpenAiResponsesStreamPayload({
  required String rawPayload,
  required String? eventName,
  required String currentModel,
  required StringBuffer outputBuffer,
}) {
  if (rawPayload.isEmpty || rawPayload == '[DONE]') {
    return _OpenAiResponsesStreamPayloadParseResult(
      modelUsed: currentModel,
      events: const [],
      terminal: rawPayload == '[DONE]',
    );
  }

  final payload = _decodeJsonObject(rawPayload);
  final effectiveType = eventName ?? payload['type'] as String?;
  var modelUsed = _extractOpenAiResponsesModel(payload) ?? currentModel;
  final events = <ProviderStreamEvent>[];
  var terminal = false;

  if (effectiveType == 'error' ||
      effectiveType == 'response.failed' ||
      effectiveType == 'response.incomplete') {
    final runtimeError = RuntimeError(
      code: RuntimeErrorCode.providerFailure,
      message: _extractOpenAiErrorMessage(
        responseMap: payload,
        fallbackStatusCode: 500,
      ),
      source: 'openai_stream',
      retriable: true,
    );
    events.add(
      ProviderStreamEvent.error(
        error: runtimeError,
        output: _formatOpenAiErrorOutput(runtimeError),
        model: modelUsed,
      ),
    );
    terminal = true;
    return _OpenAiResponsesStreamPayloadParseResult(
      modelUsed: modelUsed,
      events: events,
      terminal: terminal,
    );
  }

  if (effectiveType == 'response.output_text.delta') {
    final deltaText = _extractOpenAiResponsesDeltaText(payload);
    if (deltaText.isNotEmpty) {
      outputBuffer.write(deltaText);
      events.add(
        ProviderStreamEvent.textDelta(
          delta: deltaText,
          model: modelUsed,
        ),
      );
    }
  }

  if (effectiveType == 'response.refusal.delta') {
    final deltaText = _extractOpenAiResponsesDeltaText(payload);
    if (deltaText.isNotEmpty) {
      outputBuffer.write(deltaText);
      events.add(
        ProviderStreamEvent.textDelta(
          delta: deltaText,
          model: modelUsed,
        ),
      );
    }
  }

  if (effectiveType == 'response.completed') {
    final completedOutput = _extractOpenAiResponsesOutput(payload);
    final output =
        completedOutput.isNotEmpty ? completedOutput : outputBuffer.toString();
    events.add(
      ProviderStreamEvent.done(
        output: output.isEmpty ? '[empty-output]' : output,
        model: modelUsed,
      ),
    );
    terminal = true;
  }

  return _OpenAiResponsesStreamPayloadParseResult(
    modelUsed: modelUsed,
    events: events,
    terminal: terminal,
  );
}

String _extractOpenAiErrorMessage({
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
  return 'OpenAI request failed with status $fallbackStatusCode';
}

RuntimeErrorCode _mapOpenAiHttpCode(int statusCode) {
  if (statusCode == 400) {
    return RuntimeErrorCode.invalidInput;
  }
  if (statusCode == 401 || statusCode == 403) {
    return RuntimeErrorCode.permissionDenied;
  }
  return RuntimeErrorCode.providerFailure;
}

RuntimeError _mapOpenAiTransportError(
  Object error, {
  required String source,
}) {
  if (error is SocketException) {
    return RuntimeError(
      code: RuntimeErrorCode.providerFailure,
      message:
          'Network error while reaching OpenAI API. Check your base URL, proxy, or internet connection.',
      source: source,
      retriable: true,
    );
  }
  if (error is HandshakeException) {
    return RuntimeError(
      code: RuntimeErrorCode.providerFailure,
      message:
          'TLS handshake failed while reaching OpenAI API. Check HTTPS certificates or the configured base URL.',
      source: source,
      retriable: true,
    );
  }
  return RuntimeError(
    code: RuntimeErrorCode.providerFailure,
    message: '$error',
    source: source,
    retriable: true,
  );
}

String _formatOpenAiErrorOutput(
  RuntimeError error, {
  int? statusCode,
}) {
  if (statusCode != null) {
    if (statusCode == 400) {
      return '[ERROR] OpenAI request was rejected (HTTP 400): ${error.message}';
    }
    if (statusCode == 401 || statusCode == 403) {
      return '[ERROR] OpenAI authentication failed (HTTP $statusCode). Check your API key and base URL.';
    }
    if (statusCode == 404) {
      return '[ERROR] OpenAI endpoint not found (HTTP 404). Check whether the configured base URL points to an OpenAI-compatible /v1/responses endpoint.';
    }
    if (statusCode == 405) {
      return '[ERROR] OpenAI endpoint rejected the HTTP method (HTTP 405). Check whether the configured base URL is correct.';
    }
    if (statusCode == 408 || statusCode == 429) {
      return '[ERROR] OpenAI request was throttled or timed out (HTTP $statusCode): ${error.message}';
    }
    if (statusCode >= 500) {
      return '[ERROR] OpenAI API/network error (HTTP $statusCode): ${error.message}';
    }
    return '[ERROR] OpenAI request failed (HTTP $statusCode): ${error.message}';
  }
  if (error.code == RuntimeErrorCode.permissionDenied) {
    return '[ERROR] OpenAI authentication failed. Check your API key and base URL.';
  }
  if (error.message.contains('Network error while reaching OpenAI API') ||
      error.message
          .contains('TLS handshake failed while reaching OpenAI API')) {
    return '[ERROR] Could not reach OpenAI API. Check your network and base URL.';
  }
  return '[ERROR] OpenAI request failed: ${error.message}';
}
