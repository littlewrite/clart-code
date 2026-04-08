import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import '../core/runtime_error.dart';
import 'http_retry.dart';
import 'sse_parser.dart';

/// Types of events emitted during streaming provider execution.
enum ProviderStreamEventType { textDelta, done, error, streamEvent, rateLimit }

/// Event emitted during streaming LLM provider execution.
///
/// Represents incremental text deltas, completion, or errors during streaming.
class ProviderStreamEvent {
  const ProviderStreamEvent({
    required this.type,
    this.delta,
    this.output,
    this.model,
    this.error,
    this.toolCalls = const [],
    this.usage,
    this.costUsd,
    this.providerStateToken,
    this.event,
    this.rateLimitInfo,
  });

  final ProviderStreamEventType type;
  final String? delta;
  final String? output;
  final String? model;
  final RuntimeError? error;
  final List<QueryToolCall> toolCalls;
  final QueryUsage? usage;
  final double? costUsd;
  final String? providerStateToken;
  final Map<String, Object?>? event;
  final QueryRateLimitInfo? rateLimitInfo;

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
    List<QueryToolCall> toolCalls = const [],
    QueryUsage? usage,
    double? costUsd,
    String? providerStateToken,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.done,
      output: output,
      model: model,
      toolCalls: toolCalls,
      usage: usage,
      costUsd: costUsd,
      providerStateToken: providerStateToken,
    );
  }

  factory ProviderStreamEvent.error({
    required RuntimeError error,
    String? output,
    String? model,
    List<QueryToolCall> toolCalls = const [],
    QueryUsage? usage,
    double? costUsd,
    String? providerStateToken,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.error,
      error: error,
      output: output,
      model: model,
      toolCalls: toolCalls,
      usage: usage,
      costUsd: costUsd,
      providerStateToken: providerStateToken,
    );
  }

  factory ProviderStreamEvent.streamEvent({
    required Map<String, Object?> event,
    String? model,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.streamEvent,
      event: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(event),
      ),
      model: model,
    );
  }

  factory ProviderStreamEvent.rateLimit({
    required QueryRateLimitInfo rateLimitInfo,
    String? model,
  }) {
    return ProviderStreamEvent(
      type: ProviderStreamEventType.rateLimit,
      rateLimitInfo: rateLimitInfo,
      model: model,
    );
  }
}

/// Base interface for LLM providers.
///
/// Implementations provide both synchronous and streaming query execution.
/// The default [stream] implementation wraps [run] for providers that don't
/// support native streaming.
abstract class LlmProvider {
  bool get supportsNativeToolCalling => false;

  Future<void> cancelActiveRequest() async {}

  /// Executes a query synchronously and returns the complete response.
  Future<QueryResponse> run(QueryRequest request);

  /// Executes a query with streaming output, yielding events as they arrive.
  ///
  /// Default implementation wraps [run] for non-streaming providers.
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    if (_isRequestCancelled(request)) {
      yield ProviderStreamEvent.error(
        error: _buildCancelledRuntimeError(
          request,
          source: 'provider_stream',
        ),
        output: _formatCancelledOutput(request),
      );
      return;
    }

    final response = await run(request);
    if (_isRequestCancelled(request) && response.error == null) {
      yield ProviderStreamEvent.error(
        error: _buildCancelledRuntimeError(
          request,
          source: 'provider_stream',
        ),
        output: _formatCancelledOutput(request),
        model: response.modelUsed,
        toolCalls: response.toolCalls,
        usage: response.usage,
        costUsd: response.costUsd,
        providerStateToken: response.providerStateToken,
      );
      return;
    }
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
        toolCalls: response.toolCalls,
        usage: response.usage,
        costUsd: response.costUsd,
        providerStateToken: response.providerStateToken,
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
      toolCalls: response.toolCalls,
      usage: response.usage,
      costUsd: response.costUsd,
      providerStateToken: response.providerStateToken,
    );
  }
}

/// Base class for providers that return structured tool calls natively.
abstract class NativeToolCallingLlmProvider extends LlmProvider {
  @override
  bool get supportsNativeToolCalling => true;
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

class ClaudeApiProvider extends NativeToolCallingLlmProvider {
  ClaudeApiProvider({
    required this.apiKey,
    this.baseUrl,
    this.model,
    this.timeout,
  });

  final String apiKey;
  final String? baseUrl;
  final String? model;
  final Duration? timeout;
  HttpClient? _activeClient;

  @override
  Future<void> cancelActiveRequest() async {
    _activeClient?.close(force: true);
  }

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
    _activeClient = client;
    final outputBuffer = StringBuffer();
    final streamState = _ClaudeStreamingState();
    var modelUsed = requestedModel;
    var emittedTerminalEvent = false;
    final requestTimeout = timeout ?? RetryConfig.streaming.timeout;

    try {
      final uri = _buildClaudeUri(baseUrl);
      final body = _buildClaudeRequestBody(request)..['stream'] = true;
      final httpRequest = await client.postUrl(uri).timeout(requestTimeout);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers.set('x-api-key', apiKey);
      httpRequest.headers.set('anthropic-version', _anthropicApiVersion);
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close().timeout(requestTimeout);
      final rateLimitInfo = _extractRateLimitInfoFromHeaders(
        httpResponse.headers,
        provider: 'claude',
        statusCode: httpResponse.statusCode,
      );
      if (request.includeObservabilityMessages && rateLimitInfo != null) {
        yield ProviderStreamEvent.rateLimit(
          rateLimitInfo: rateLimitInfo,
          model: modelUsed,
        );
      }
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

      await for (final sseEvent in SseParser.parse(httpResponse)) {
        if (sseEvent.isEmpty) continue;

        final parsed = _parseClaudeStreamPayload(
          rawPayload: sseEvent.data,
          eventName: sseEvent.event,
          currentModel: modelUsed,
          outputBuffer: outputBuffer,
          streamState: streamState,
        );
        modelUsed = parsed.modelUsed;
        if (request.includeObservabilityMessages) {
          final rawEvent = _decodeJsonObject(sseEvent.data);
          if (rawEvent.isNotEmpty) {
            yield ProviderStreamEvent.streamEvent(
              event: rawEvent,
              model: modelUsed,
            );
          }
        }
        for (final event in parsed.events) {
          yield event;
        }
        if (parsed.terminal) {
          emittedTerminalEvent = true;
          break;
        }
      }

      if (!emittedTerminalEvent) {
        final output = outputBuffer.toString();
        yield ProviderStreamEvent.done(
          output: output.isEmpty && streamState.toolCalls.isNotEmpty
              ? ''
              : output.isEmpty
                  ? '[empty-output]'
                  : output,
          model: modelUsed,
          toolCalls: streamState.toolCalls,
          usage: streamState.usage,
          costUsd: streamState.costUsd,
        );
      }
    } catch (error) {
      if (_isRequestCancelled(request)) {
        yield ProviderStreamEvent.error(
          error: _buildCancelledRuntimeError(
            request,
            source: 'claude_stream',
          ),
          output: _formatCancelledOutput(request),
          model: modelUsed,
          toolCalls: streamState.toolCalls,
          usage: streamState.usage,
          costUsd: streamState.costUsd,
        );
        return;
      }
      final runtimeError = _mapClaudeTransportError(
        error,
        source: 'claude_stream',
      );
      yield ProviderStreamEvent.error(
        error: runtimeError,
        output: _formatClaudeErrorOutput(runtimeError),
        model: modelUsed,
        usage: streamState.usage,
        costUsd: streamState.costUsd,
      );
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
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

    final retryConfig =
        timeout != null ? RetryConfig(timeout: timeout!) : RetryConfig.standard;

    return await withRetry(
      operation: () async {
        final client = HttpClient();
        _activeClient = client;
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
          final responseText =
              await httpResponse.transform(utf8.decoder).join();
          final responseMap = _decodeJsonObject(responseText);

          if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            final output = _extractClaudeOutput(responseMap);
            final toolCalls = _extractClaudeToolCalls(responseMap);
            return QueryResponse.success(
              output: output.isEmpty && toolCalls.isNotEmpty
                  ? ''
                  : output.isEmpty
                      ? '[empty-output]'
                      : output,
              modelUsed: responseMap['model'] as String? ?? requestedModel,
              toolCalls: toolCalls,
              usage: _extractUsageFromMap(
                responseMap,
                usageKey: 'usage',
                inputTokensKey: 'input_tokens',
                outputTokensKey: 'output_tokens',
                cacheCreationInputTokensKey: 'cache_creation_input_tokens',
                cacheReadInputTokensKey: 'cache_read_input_tokens',
              ),
              costUsd: _extractUsdCost(responseMap),
            );
          }

          final runtimeError = RuntimeError(
            code: _mapClaudeHttpCode(httpResponse.statusCode),
            message: _extractClaudeErrorMessage(
              responseMap: responseMap,
              fallbackStatusCode: httpResponse.statusCode,
            ),
            source: 'claude_http',
            retriable: httpResponse.statusCode >= 500 ||
                httpResponse.statusCode == 429,
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
          if (_isRequestCancelled(request)) {
            return QueryResponse.failure(
              error: _buildCancelledRuntimeError(
                request,
                source: 'claude_http',
              ),
              output: _formatCancelledOutput(request),
              modelUsed: requestedModel,
            );
          }
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
          if (identical(_activeClient, client)) {
            _activeClient = null;
          }
          client.close(force: true);
        }
      },
      config: retryConfig,
      shouldRetry: (error, statusCode) {
        // Retry on network errors and retriable HTTP errors
        if (error is QueryResponse) {
          return error.error?.retriable ?? false;
        }
        return isRetriableError(error, statusCode: statusCode);
      },
    );
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

  List<QueryToolCall> _extractClaudeToolCalls(
      Map<String, Object?> responseMap) {
    final content = responseMap['content'];
    if (content is! List) {
      return const [];
    }

    final toolCalls = <QueryToolCall>[];
    for (final block in content.whereType<Map>()) {
      if (block['type'] != 'tool_use') {
        continue;
      }
      final id = block['id'] as String?;
      final name = block['name'] as String?;
      if (id == null ||
          id.trim().isEmpty ||
          name == null ||
          name.trim().isEmpty) {
        continue;
      }
      final input = block['input'] is Map<String, Object?>
          ? block['input'] as Map<String, Object?>
          : block['input'] is Map
              ? Map<String, Object?>.from(block['input'] as Map)
              : const <String, Object?>{};
      toolCalls.add(
        QueryToolCall(
          id: id.trim(),
          name: name.trim(),
          input: Map<String, Object?>.unmodifiable(input),
        ),
      );
    }

    return List<QueryToolCall>.unmodifiable(toolCalls);
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

  String _extractClaudeContentBlockStartText(Map<String, Object?> block) {
    if (block['type'] != 'text') {
      return '';
    }
    final text = block['text'];
    if (text is! String) {
      return '';
    }
    return text;
  }

  QueryUsage? _extractClaudeUsage(Map<String, Object?> payload) {
    final message = payload['message'];
    if (message is Map<String, dynamic>) {
      final usage = _extractUsageFromMap(
        Map<String, Object?>.from(message),
        usageKey: 'usage',
        inputTokensKey: 'input_tokens',
        outputTokensKey: 'output_tokens',
        cacheCreationInputTokensKey: 'cache_creation_input_tokens',
        cacheReadInputTokensKey: 'cache_read_input_tokens',
      );
      if (usage != null) {
        return usage;
      }
    }

    final delta = payload['delta'];
    if (delta is Map<String, dynamic>) {
      return _extractUsageFromMap(
        Map<String, Object?>.from(delta),
        usageKey: 'usage',
        inputTokensKey: 'input_tokens',
        outputTokensKey: 'output_tokens',
        cacheCreationInputTokensKey: 'cache_creation_input_tokens',
        cacheReadInputTokensKey: 'cache_read_input_tokens',
      );
    }

    return _extractUsageFromMap(
      payload,
      usageKey: 'usage',
      inputTokensKey: 'input_tokens',
      outputTokensKey: 'output_tokens',
      cacheCreationInputTokensKey: 'cache_creation_input_tokens',
      cacheReadInputTokensKey: 'cache_read_input_tokens',
    );
  }

  _ClaudeStreamPayloadParseResult _parseClaudeStreamPayload({
    required String rawPayload,
    required String? eventName,
    required String currentModel,
    required StringBuffer outputBuffer,
    required _ClaudeStreamingState streamState,
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
          toolCalls: streamState.toolCalls,
          usage: streamState.usage,
          costUsd: streamState.costUsd,
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

    final usage = _extractClaudeUsage(payload);
    if (usage != null) {
      streamState.usage = QueryUsage.combine([streamState.usage, usage]);
    }
    final costUsd = _extractUsdCost(payload);
    if (costUsd != null) {
      streamState.costUsd = _sumNullableDouble(streamState.costUsd, costUsd);
    }

    final index = payload['index'] as int?;

    if (effectiveType == 'content_block_start' && index != null) {
      final contentBlock = payload['content_block'];
      if (contentBlock is Map) {
        final block = Map<String, Object?>.from(contentBlock);
        streamState.startBlock(index, block);
        final initialText = _extractClaudeContentBlockStartText(block);
        if (initialText.isNotEmpty) {
          outputBuffer.write(initialText);
          events.add(
            ProviderStreamEvent.textDelta(
              delta: initialText,
              model: modelUsed,
            ),
          );
        }
      }
    }

    if (effectiveType == 'content_block_delta' && index != null) {
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

      final delta = payload['delta'];
      if (delta is Map) {
        streamState.applyDelta(index, Map<String, Object?>.from(delta));
      }
    }

    if (effectiveType == 'content_block_stop' && index != null) {
      streamState.finishBlock(index);
    }

    if (effectiveType == 'message_stop') {
      final output = outputBuffer.toString();
      events.add(
        ProviderStreamEvent.done(
          output: output.isEmpty && streamState.toolCalls.isNotEmpty
              ? ''
              : output.isEmpty
                  ? '[empty-output]'
                  : output,
          model: modelUsed,
          toolCalls: streamState.toolCalls,
          usage: streamState.usage,
          costUsd: streamState.costUsd,
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
    if (error is TimeoutException) {
      return RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message:
            'Claude API request timed out. Check endpoint latency, model responsiveness, or the configured timeout.',
        source: source,
        retriable: true,
      );
    }
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
        error.message.contains('request timed out') ||
        error.message
            .contains('TLS handshake failed while reaching Claude API')) {
      return '[ERROR] Could not reach Claude API. Check your network, timeout, and base URL.';
    }
    return '[ERROR] Could not reach Claude API. Check your network, timeout, and base URL.';
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

bool _isRequestCancelled(QueryRequest request) {
  return request.cancellationSignal?.isCancelled ?? false;
}

RuntimeError _buildCancelledRuntimeError(
  QueryRequest request, {
  required String source,
}) {
  final reason = request.cancellationSignal?.reason?.trim();
  return RuntimeError(
    code: RuntimeErrorCode.cancelled,
    message: reason == null || reason.isEmpty ? 'request cancelled' : reason,
    source: source,
    retriable: false,
  );
}

String _formatCancelledOutput(QueryRequest request) {
  return '[STOPPED] request cancelled';
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

QueryUsage? _extractUsageFromMap(
  Map<String, Object?> source, {
  required String usageKey,
  String? inputTokensKey,
  String? outputTokensKey,
  String? totalTokensKey,
  String? reasoningTokensKey,
  String? cachedInputTokensKey,
  String? cacheCreationInputTokensKey,
  String? cacheReadInputTokensKey,
  List<String>? reasoningTokensPath,
  List<String>? cachedInputTokensPath,
}) {
  final usageSource = _lookupNestedMap(source, [usageKey]);
  if (usageSource == null) {
    return null;
  }

  final usage = QueryUsage(
    inputTokens:
        inputTokensKey == null ? null : _asInt(usageSource[inputTokensKey]),
    outputTokens:
        outputTokensKey == null ? null : _asInt(usageSource[outputTokensKey]),
    totalTokens:
        totalTokensKey == null ? null : _asInt(usageSource[totalTokensKey]),
    reasoningTokens: reasoningTokensPath == null
        ? (reasoningTokensKey == null
            ? null
            : _asInt(usageSource[reasoningTokensKey]))
        : _asInt(_lookupNestedValue(usageSource, reasoningTokensPath)),
    cachedInputTokens: cachedInputTokensPath == null
        ? (cachedInputTokensKey == null
            ? null
            : _asInt(usageSource[cachedInputTokensKey]))
        : _asInt(_lookupNestedValue(usageSource, cachedInputTokensPath)),
    cacheCreationInputTokens: cacheCreationInputTokensKey == null
        ? null
        : _asInt(usageSource[cacheCreationInputTokensKey]),
    cacheReadInputTokens: cacheReadInputTokensKey == null
        ? null
        : _asInt(usageSource[cacheReadInputTokensKey]),
    raw: Map<String, Object?>.unmodifiable(usageSource),
  );
  return usage.isEmpty ? null : usage;
}

double? _extractUsdCost(Map<String, Object?> source) {
  final direct = _asDouble(source['cost_usd']) ??
      _asDouble(source['total_cost_usd']) ??
      _asDouble(source['cost']);
  if (direct != null) {
    return direct;
  }

  final usage = _lookupNestedMap(source, const ['usage']);
  if (usage != null) {
    final usageCost = _asDouble(usage['cost_usd']) ??
        _asDouble(usage['total_cost_usd']) ??
        _asDouble(usage['cost']) ??
        _asDouble(usage['total_cost']);
    if (usageCost != null) {
      return usageCost;
    }
  }

  final nestedResponse = _lookupNestedMap(source, const ['response']);
  if (nestedResponse != null) {
    return _extractUsdCost(nestedResponse);
  }

  return null;
}

Map<String, Object?>? _lookupNestedMap(
  Map<String, Object?> source,
  List<String> path,
) {
  final value = _lookupNestedValue(source, path);
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  return null;
}

Object? _lookupNestedValue(Map<String, Object?> source, List<String> path) {
  Object? current = source;
  for (final key in path) {
    if (current is Map<String, Object?>) {
      current = current[key];
      continue;
    }
    if (current is Map) {
      current = current[key];
      continue;
    }
    return null;
  }
  return current;
}

int? _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

double? _sumNullableDouble(double? left, double? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left + right;
}

QueryRateLimitInfo? _extractRateLimitInfoFromHeaders(
  HttpHeaders headers, {
  required String provider,
  int? statusCode,
}) {
  String? firstValue(List<String> names) {
    for (final name in names) {
      final value = headers.value(name)?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  final requestsLimit = firstValue([
    'anthropic-ratelimit-requests-limit',
    'x-ratelimit-limit-requests',
  ]);
  final requestsRemaining = firstValue([
    'anthropic-ratelimit-requests-remaining',
    'x-ratelimit-remaining-requests',
  ]);
  final requestsReset = firstValue([
    'anthropic-ratelimit-requests-reset',
    'x-ratelimit-reset-requests',
  ]);
  final tokensLimit = firstValue([
    'anthropic-ratelimit-tokens-limit',
    'x-ratelimit-limit-tokens',
  ]);
  final tokensRemaining = firstValue([
    'anthropic-ratelimit-tokens-remaining',
    'x-ratelimit-remaining-tokens',
  ]);
  final tokensReset = firstValue([
    'anthropic-ratelimit-tokens-reset',
    'x-ratelimit-reset-tokens',
  ]);
  final retryAfter = firstValue([
    'retry-after',
  ]);

  final raw = <String, Object?>{};
  void addIfPresent(String key, String? value) {
    if (value != null && value.isNotEmpty) {
      raw[key] = value;
    }
  }

  addIfPresent('requests_limit', requestsLimit);
  addIfPresent('requests_remaining', requestsRemaining);
  addIfPresent('requests_reset', requestsReset);
  addIfPresent('tokens_limit', tokensLimit);
  addIfPresent('tokens_remaining', tokensRemaining);
  addIfPresent('tokens_reset', tokensReset);
  addIfPresent('retry_after', retryAfter);

  final info = QueryRateLimitInfo(
    provider: provider,
    status: statusCode == 429 ? 'rate_limited' : 'ok',
    requestsLimit: requestsLimit,
    requestsRemaining: requestsRemaining,
    requestsReset: requestsReset,
    tokensLimit: tokensLimit,
    tokensRemaining: tokensRemaining,
    tokensReset: tokensReset,
    retryAfter: retryAfter,
    raw: Map<String, Object?>.unmodifiable(raw),
  );
  return info.hasData ? info : null;
}

Map<String, Object?> _buildClaudeRequestBodyPayload({
  required QueryRequest request,
  String? fallbackModel,
}) {
  final resolvedModel = request.model ?? fallbackModel ?? _defaultClaudeModel;
  final systemMessages = <String>[];
  final messages = _buildClaudeMessagesPayload(
    request.messages,
    systemMessages: systemMessages,
  );
  final prependedSystemPrompt = request.systemPrompt?.trim();
  if (prependedSystemPrompt != null && prependedSystemPrompt.isNotEmpty) {
    systemMessages.insert(0, prependedSystemPrompt);
  }
  final appendedSystemPrompt = request.appendSystemPrompt?.trim();
  if (appendedSystemPrompt != null && appendedSystemPrompt.isNotEmpty) {
    systemMessages.add(appendedSystemPrompt);
  }

  if (messages.isEmpty) {
    messages.add({'role': 'user', 'content': ''});
  }

  return {
    'model': resolvedModel,
    'max_tokens': request.maxTokens ?? _defaultClaudeMaxTokens,
    'thinking':
        (request.thinking ?? const ClartCodeThinkingConfig.disabled()).toJson(),
    if (systemMessages.isNotEmpty) 'system': systemMessages.join('\n'),
    'messages': messages,
    if (request.toolDefinitions.isNotEmpty)
      'tools': request.toolDefinitions
          .map(_buildClaudeToolDefinitionPayload)
          .toList(growable: false),
  };
}

List<Map<String, Object?>> _buildClaudeMessagesPayload(
  List<ChatMessage> history, {
  required List<String> systemMessages,
}) {
  final messages = <Map<String, Object?>>[];
  final pendingToolResults = <Map<String, Object?>>[];

  void flushPendingToolResults() {
    if (pendingToolResults.isEmpty) {
      return;
    }
    messages.add({
      'role': 'user',
      'content': List<Map<String, Object?>>.from(pendingToolResults),
    });
    pendingToolResults.clear();
  }

  for (final message in history) {
    switch (message.role) {
      case MessageRole.system:
        systemMessages.add(message.text);
        break;
      case MessageRole.user:
        flushPendingToolResults();
        messages.add({'role': 'user', 'content': message.text});
        break;
      case MessageRole.assistant:
        flushPendingToolResults();
        final payload = _decodeAssistantToolCallPayload(message.text);
        if (payload == null) {
          messages.add({'role': 'assistant', 'content': message.text});
          break;
        }

        final content = <Map<String, Object?>>[];
        if (payload.text != null && payload.text!.trim().isNotEmpty) {
          content.add({
            'type': 'text',
            'text': payload.text!.trim(),
          });
        }
        for (final toolCall in payload.toolCalls) {
          content.add({
            'type': 'tool_use',
            'id': toolCall.id,
            'name': toolCall.name,
            'input': toolCall.input,
          });
        }
        messages.add({
          'role': 'assistant',
          'content': content,
        });
        break;
      case MessageRole.tool:
        final toolResult = _decodeToolResultPayload(message.text);
        if (toolResult == null) {
          flushPendingToolResults();
          messages.add({
            'role': 'user',
            'content': '[tool] ${message.text}',
          });
          break;
        }
        pendingToolResults.add({
          'type': 'tool_result',
          'tool_use_id': toolResult.callId,
          'content': toolResult.output,
          if (toolResult.isError) 'is_error': true,
        });
        break;
    }
  }

  flushPendingToolResults();
  return messages;
}

Map<String, Object?> _buildClaudeToolDefinitionPayload(
  QueryToolDefinition tool,
) {
  return {
    'name': tool.name,
    'description': tool.description,
    'input_schema': tool.inputSchema ??
        const {
          'type': 'object',
          'properties': {},
        },
  };
}

_AssistantToolCallPayload? _decodeAssistantToolCallPayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final payload = Map<String, Object?>.from(decoded);
    final toolCallsRaw = payload['tool_calls'];
    if (toolCallsRaw is! List) {
      return null;
    }
    final toolCalls = toolCallsRaw
        .whereType<Map>()
        .map((item) => _toolCallFromJsonMap(Map<String, Object?>.from(item)))
        .whereType<QueryToolCall>()
        .toList(growable: false);
    if (toolCalls.isEmpty) {
      return null;
    }
    return _AssistantToolCallPayload(
      text: payload['text'] as String?,
      toolCalls: toolCalls,
    );
  } catch (_) {
    return null;
  }
}

QueryToolCall? _toolCallFromJsonMap(Map<String, Object?> map) {
  final id = map['id'] as String?;
  final name = map['name'] as String?;
  if (id == null || id.trim().isEmpty || name == null || name.trim().isEmpty) {
    return null;
  }
  final input = map['input'] is Map<String, Object?>
      ? map['input'] as Map<String, Object?>
      : map['input'] is Map
          ? Map<String, Object?>.from(map['input'] as Map)
          : const <String, Object?>{};
  return QueryToolCall(
    id: id.trim(),
    name: name.trim(),
    input: Map<String, Object?>.unmodifiable(input),
  );
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

class _ClaudeStreamingState {
  final Map<int, _ClaudeContentBlockState> _blocks = {};
  final List<QueryToolCall> _toolCalls = [];
  QueryUsage? usage;
  double? costUsd;

  List<QueryToolCall> get toolCalls =>
      List<QueryToolCall>.unmodifiable(_toolCalls);

  void startBlock(int index, Map<String, Object?> block) {
    _blocks[index] = _ClaudeContentBlockState.fromStartBlock(block);
  }

  void applyDelta(int index, Map<String, Object?> delta) {
    _blocks[index]?.applyDelta(delta);
  }

  void finishBlock(int index) {
    final toolCall = _blocks.remove(index)?.toToolCall();
    if (toolCall != null) {
      _toolCalls.add(toolCall);
    }
  }
}

class _ClaudeContentBlockState {
  _ClaudeContentBlockState._({
    required this.type,
    this.toolId,
    this.toolName,
    Map<String, Object?>? toolInputSeed,
  }) : _toolInputSeed = toolInputSeed == null
            ? const <String, Object?>{}
            : Map<String, Object?>.unmodifiable(toolInputSeed);

  factory _ClaudeContentBlockState.fromStartBlock(Map<String, Object?> block) {
    final type = block['type'] as String? ?? '';
    if (type == 'tool_use') {
      final input = block['input'];
      return _ClaudeContentBlockState._(
        type: type,
        toolId: block['id'] as String?,
        toolName: block['name'] as String?,
        toolInputSeed: input is Map<String, Object?>
            ? input
            : input is Map
                ? Map<String, Object?>.from(input)
                : null,
      );
    }
    return _ClaudeContentBlockState._(type: type);
  }

  final String type;
  final String? toolId;
  final String? toolName;
  final Map<String, Object?> _toolInputSeed;
  final StringBuffer _toolInputBuffer = StringBuffer();

  void applyDelta(Map<String, Object?> delta) {
    if (type != 'tool_use' || delta['type'] != 'input_json_delta') {
      return;
    }
    final partialJson = delta['partial_json'];
    if (partialJson is String && partialJson.isNotEmpty) {
      _toolInputBuffer.write(partialJson);
    }
  }

  QueryToolCall? toToolCall() {
    if (type != 'tool_use') {
      return null;
    }
    final id = toolId?.trim();
    final name = toolName?.trim();
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return QueryToolCall(
      id: id,
      name: name,
      input: _decodeToolInput(),
    );
  }

  Map<String, Object?> _decodeToolInput() {
    final raw = _toolInputBuffer.toString().trim();
    if (raw.isEmpty) {
      return _toolInputSeed;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return Map<String, Object?>.unmodifiable(decoded);
      }
      if (decoded is Map) {
        return Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(decoded),
        );
      }
    } catch (_) {
      return _toolInputSeed;
    }
    return _toolInputSeed;
  }
}

class _AssistantToolCallPayload {
  const _AssistantToolCallPayload({
    required this.toolCalls,
    this.text,
  });

  final String? text;
  final List<QueryToolCall> toolCalls;
}

class OpenAiApiProvider extends NativeToolCallingLlmProvider {
  OpenAiApiProvider({
    required this.apiKey,
    this.baseUrl,
    this.model,
    this.timeout,
  });

  final String apiKey;
  final String? baseUrl;
  final String? model;
  final Duration? timeout;
  HttpClient? _activeClient;

  @override
  Future<void> cancelActiveRequest() async {
    _activeClient?.close(force: true);
  }

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
    _activeClient = client;
    final outputBuffer = StringBuffer();
    var modelUsed = chosenModel;
    var emittedTerminalEvent = false;
    var emittedTextDelta = false;
    final requestTimeout = timeout ?? RetryConfig.streaming.timeout;

    try {
      final uri = _buildOpenAiResponsesUri(baseUrl);
      final body = _buildOpenAiResponsesRequestBody(request)..['stream'] = true;
      final httpRequest = await client.postUrl(uri).timeout(requestTimeout);
      httpRequest.headers
          .set(HttpHeaders.contentTypeHeader, 'application/json');
      httpRequest.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
      httpRequest.add(utf8.encode(jsonEncode(body)));

      final httpResponse = await httpRequest.close().timeout(requestTimeout);
      final rateLimitInfo = _extractRateLimitInfoFromHeaders(
        httpResponse.headers,
        provider: 'openai',
        statusCode: httpResponse.statusCode,
      );
      if (request.includeObservabilityMessages && rateLimitInfo != null) {
        yield ProviderStreamEvent.rateLimit(
          rateLimitInfo: rateLimitInfo,
          model: modelUsed,
        );
      }
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

      await for (final sseEvent in SseParser.parse(httpResponse)) {
        if (sseEvent.isEmpty) continue;

        final parsed = _parseOpenAiResponsesStreamPayload(
          rawPayload: sseEvent.data,
          eventName: sseEvent.event,
          currentModel: modelUsed,
          outputBuffer: outputBuffer,
        );
        modelUsed = parsed.modelUsed;
        if (request.includeObservabilityMessages && sseEvent.data != '[DONE]') {
          final rawEvent = _decodeJsonObject(sseEvent.data);
          if (rawEvent.isNotEmpty) {
            yield ProviderStreamEvent.streamEvent(
              event: rawEvent,
              model: modelUsed,
            );
          }
        }

        final hasTextDelta = parsed.events.any(
          (event) => event.type == ProviderStreamEventType.textDelta,
        );
        if (hasTextDelta) {
          emittedTextDelta = true;
        }

        final hasTerminalError = parsed.events.any(
          (event) => event.type == ProviderStreamEventType.error,
        );
        if (hasTerminalError && !emittedTextDelta) {
          final fallback = await run(request);
          final fallbackModel = fallback.modelUsed ?? modelUsed;
          if (fallback.isOk) {
            if (fallback.output.isNotEmpty) {
              yield ProviderStreamEvent.textDelta(
                delta: fallback.output,
                model: fallbackModel,
              );
            }
            yield ProviderStreamEvent.done(
              output: fallback.output,
              model: fallbackModel,
              toolCalls: fallback.toolCalls,
              usage: fallback.usage,
              costUsd: fallback.costUsd,
              providerStateToken: fallback.providerStateToken,
            );
          } else {
            yield ProviderStreamEvent.error(
              error: fallback.error ??
                  const RuntimeError(
                    code: RuntimeErrorCode.providerFailure,
                    message: 'OpenAI stream fallback failed',
                    source: 'openai_stream_fallback',
                    retriable: true,
                  ),
              output: fallback.output,
              model: fallbackModel,
              toolCalls: fallback.toolCalls,
              usage: fallback.usage,
              costUsd: fallback.costUsd,
              providerStateToken: fallback.providerStateToken,
            );
          }
          emittedTerminalEvent = true;
          break;
        }

        for (final event in parsed.events) {
          yield event;
        }
        if (parsed.terminal) {
          emittedTerminalEvent = true;
          break;
        }
      }

      if (!emittedTerminalEvent) {
        final output = outputBuffer.toString();
        yield ProviderStreamEvent.done(
          output: output.isEmpty ? '[empty-output]' : output,
          model: modelUsed,
        );
      }
    } catch (error) {
      if (_isRequestCancelled(request)) {
        yield ProviderStreamEvent.error(
          error: _buildCancelledRuntimeError(
            request,
            source: 'openai_stream',
          ),
          output: _formatCancelledOutput(request),
          model: modelUsed,
        );
        return;
      }
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
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
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

    final retryConfig =
        timeout != null ? RetryConfig(timeout: timeout!) : RetryConfig.standard;

    return await withRetry(
      operation: () async {
        final client = HttpClient();
        _activeClient = client;

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
          final responseText =
              await httpResponse.transform(utf8.decoder).join();
          final responseMap = _decodeJsonObject(responseText);

          if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            final output = _extractOpenAiResponsesOutput(responseMap);
            final toolCalls = _extractOpenAiResponsesToolCalls(responseMap);
            return QueryResponse.success(
              output: output.isEmpty && toolCalls.isNotEmpty
                  ? ''
                  : output.isEmpty
                      ? '[empty-output]'
                      : output,
              modelUsed:
                  _extractOpenAiResponsesModel(responseMap) ?? chosenModel,
              toolCalls: toolCalls,
              usage: _extractOpenAiResponsesUsage(responseMap),
              costUsd: _extractUsdCost(responseMap),
              providerStateToken: _extractOpenAiResponsesId(responseMap),
            );
          }

          final runtimeError = RuntimeError(
            code: _mapOpenAiHttpCode(httpResponse.statusCode),
            message: _extractOpenAiErrorMessage(
              responseMap: responseMap,
              fallbackStatusCode: httpResponse.statusCode,
            ),
            source: 'openai_http',
            retriable: httpResponse.statusCode >= 500 ||
                httpResponse.statusCode == 429,
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
          if (_isRequestCancelled(request)) {
            return QueryResponse.failure(
              error: _buildCancelledRuntimeError(
                request,
                source: 'openai_http',
              ),
              output: _formatCancelledOutput(request),
              modelUsed: chosenModel,
            );
          }
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
          if (identical(_activeClient, client)) {
            _activeClient = null;
          }
          client.close(force: true);
        }
      },
      config: retryConfig,
      shouldRetry: (error, statusCode) {
        // Retry on network errors and retriable HTTP errors
        if (error is QueryResponse) {
          return error.error?.retriable ?? false;
        }
        return isRetriableError(error, statusCode: statusCode);
      },
    );
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
  final input = request.providerStateToken == null
      ? <Map<String, Object?>>[]
      : _buildOpenAiResponsesContinuationInput(request.messages);

  if (request.providerStateToken == null) {
    final prependedSystemPrompt = request.systemPrompt?.trim();
    if (prependedSystemPrompt != null && prependedSystemPrompt.isNotEmpty) {
      input.add({
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': prependedSystemPrompt},
        ],
      });
    }

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

    final appendedSystemPrompt = request.appendSystemPrompt?.trim();
    if (appendedSystemPrompt != null && appendedSystemPrompt.isNotEmpty) {
      input.add({
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': appendedSystemPrompt},
        ],
      });
    }
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
    if (request.providerStateToken != null)
      'previous_response_id': request.providerStateToken,
    'input': input,
    if (request.maxTokens != null) 'max_output_tokens': request.maxTokens,
    if (request.effort != null)
      'reasoning': {
        'effort': request.effort!.name,
      },
    if (request.jsonSchema != null || request.outputFormat != null)
      'text': {
        'format': _buildOpenAiResponsesTextFormat(
          jsonSchema: request.jsonSchema,
          outputFormat: request.outputFormat,
        ),
      },
    if (request.toolDefinitions.isNotEmpty)
      'tools': request.toolDefinitions
          .map(_buildOpenAiResponsesToolDefinition)
          .toList(growable: false),
    if (request.toolDefinitions.isNotEmpty) 'tool_choice': 'auto',
  };
}

Map<String, Object?> _buildOpenAiResponsesTextFormat({
  required ClartCodeJsonSchema? jsonSchema,
  required ClartCodeOutputFormat? outputFormat,
}) {
  if (jsonSchema != null) {
    return {
      'type': 'json_schema',
      'name': jsonSchema.name,
      'schema': jsonSchema.schema,
      'strict': jsonSchema.strict,
    };
  }

  switch (outputFormat?.type) {
    case ClartCodeOutputFormatType.jsonObject:
      return const {'type': 'json_object'};
    case ClartCodeOutputFormatType.text:
    case null:
      return const {'type': 'text'};
  }
}

List<Map<String, Object?>> _buildOpenAiResponsesContinuationInput(
  List<ChatMessage> messages,
) {
  final input = <Map<String, Object?>>[];
  for (final message in messages) {
    if (message.role == MessageRole.tool) {
      final toolResult = _decodeToolResultPayload(message.text);
      if (toolResult != null) {
        input.add({
          'type': 'function_call_output',
          'call_id': toolResult.callId,
          'output': toolResult.output,
        });
        continue;
      }
    }

    input.add({
      'role': _toOpenAiResponsesRole(message.role),
      'content': [
        {
          'type': _toOpenAiResponsesContentType(message.role),
          'text': message.role == MessageRole.tool
              ? '[tool] ${message.text}'
              : message.text,
        },
      ],
    });
  }
  return input;
}

Map<String, Object?> _buildOpenAiResponsesToolDefinition(
  QueryToolDefinition tool,
) {
  return {
    'type': 'function',
    'name': tool.name,
    'description': tool.description,
    'parameters': tool.inputSchema ??
        const {
          'type': 'object',
          'properties': {},
        },
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

String? _extractOpenAiResponsesId(Map<String, Object?> responseMap) {
  final response = responseMap['response'];
  if (response is Map<String, dynamic>) {
    final id = response['id'];
    if (id is String && id.isNotEmpty) {
      return id;
    }
  }
  final id = responseMap['id'];
  if (id is String && id.isNotEmpty) {
    return id;
  }
  return null;
}

QueryUsage? _extractOpenAiResponsesUsage(
  Map<String, Object?> responseMap,
) {
  final nestedResponse = responseMap['response'];
  if (nestedResponse is Map<String, dynamic>) {
    final nestedUsage = _extractOpenAiResponsesUsage(
      Map<String, Object?>.from(nestedResponse),
    );
    if (nestedUsage != null) {
      return nestedUsage;
    }
  }

  return _extractUsageFromMap(
    responseMap,
    usageKey: 'usage',
    inputTokensKey: 'input_tokens',
    outputTokensKey: 'output_tokens',
    totalTokensKey: 'total_tokens',
    reasoningTokensPath: ['output_tokens_details', 'reasoning_tokens'],
    cachedInputTokensPath: ['input_tokens_details', 'cached_tokens'],
  );
}

List<QueryToolCall> _extractOpenAiResponsesToolCalls(
  Map<String, Object?> responseMap,
) {
  final nestedResponse = responseMap['response'];
  if (nestedResponse is Map<String, dynamic>) {
    final nestedToolCalls = _extractOpenAiResponsesToolCalls(
      Map<String, Object?>.from(nestedResponse),
    );
    if (nestedToolCalls.isNotEmpty) {
      return nestedToolCalls;
    }
  }

  final output = responseMap['output'];
  if (output is! List) {
    return const [];
  }

  final toolCalls = <QueryToolCall>[];
  for (final item in output.whereType<Map>()) {
    if (item['type'] != 'function_call') {
      continue;
    }
    final name = item['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      continue;
    }
    final callId = item['call_id'] as String? ??
        item['id'] as String? ??
        'call_${toolCalls.length + 1}';
    final arguments = _parseOpenAiToolArguments(item['arguments']);
    toolCalls.add(
      QueryToolCall(
        id: callId,
        name: name.trim(),
        input: arguments,
      ),
    );
  }

  return List<QueryToolCall>.unmodifiable(toolCalls);
}

Map<String, Object?> _parseOpenAiToolArguments(Object? rawArguments) {
  if (rawArguments is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(rawArguments);
  }
  if (rawArguments is Map) {
    return Map<String, Object?>.unmodifiable(
      Map<String, Object?>.from(rawArguments),
    );
  }
  if (rawArguments is String && rawArguments.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map<String, Object?>) {
        return Map<String, Object?>.unmodifiable(decoded);
      }
      if (decoded is Map) {
        return Map<String, Object?>.unmodifiable(
          Map<String, Object?>.from(decoded),
        );
      }
    } catch (_) {
      return const {};
    }
  }
  return const {};
}

_ToolResultPayload? _decodeToolResultPayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final payload = Map<String, Object?>.from(decoded);
    final callId = payload['tool_call_id'] as String?;
    if (callId == null || callId.trim().isEmpty) {
      return null;
    }
    final output = payload['output'] as String? ?? '';
    final ok = payload['ok'] as bool? ?? true;
    return _ToolResultPayload(
      callId: callId.trim(),
      output: output,
      isError: !ok,
    );
  } catch (_) {
    return null;
  }
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
    final toolCalls = _extractOpenAiResponsesToolCalls(payload);
    final usage = _extractOpenAiResponsesUsage(payload);
    final costUsd = _extractUsdCost(payload);
    final output =
        completedOutput.isNotEmpty ? completedOutput : outputBuffer.toString();
    events.add(
      ProviderStreamEvent.done(
        output: output.isEmpty && toolCalls.isNotEmpty
            ? ''
            : output.isEmpty
                ? '[empty-output]'
                : output,
        model: modelUsed,
        toolCalls: toolCalls,
        usage: usage,
        costUsd: costUsd,
        providerStateToken: _extractOpenAiResponsesId(payload),
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

class _ToolResultPayload {
  const _ToolResultPayload({
    required this.callId,
    required this.output,
    this.isError = false,
  });

  final String callId;
  final String output;
  final bool isError;
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
  if (error is TimeoutException) {
    return RuntimeError(
      code: RuntimeErrorCode.providerFailure,
      message:
          'OpenAI-compatible request timed out. Check endpoint latency, model responsiveness, or the configured timeout.',
      source: source,
      retriable: true,
    );
  }
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
      error.message.contains('request timed out') ||
      error.message
          .contains('TLS handshake failed while reaching OpenAI API')) {
    return '[ERROR] Could not reach OpenAI API. Check your network, timeout, and base URL.';
  }
  return '[ERROR] OpenAI request failed: ${error.message}';
}
