import 'dart:convert';
import 'dart:io';

import 'package:dart_openai/dart_openai.dart';

import '../core/models.dart';
import '../core/runtime_error.dart';

abstract class LlmProvider {
  Future<QueryResponse> run(QueryRequest request);
}

class LocalEchoProvider implements LlmProvider {
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

class ClaudeApiProvider implements LlmProvider {
  ClaudeApiProvider({required this.apiKey, this.baseUrl, this.model});

  final String apiKey;
  final String? baseUrl;
  final String? model;

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    if (apiKey.trim().isEmpty) {
      return QueryResponse.failure(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'CLAUDE_API_KEY is required for claude provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing CLAUDE_API_KEY for claude provider',
        modelUsed: model ?? _defaultClaudeModel,
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
          modelUsed:
              responseMap['model'] as String? ?? model ?? _defaultClaudeModel,
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
        modelUsed: model ?? _defaultClaudeModel,
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
        modelUsed: model ?? _defaultClaudeModel,
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
      'model': model ?? _defaultClaudeModel,
      'max_tokens': _defaultClaudeMaxTokens,
      if (systemMessages.isNotEmpty) 'system': systemMessages.join('\n'),
      'messages': messages,
    };
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

class OpenAiApiProvider implements LlmProvider {
  OpenAiApiProvider({
    required this.apiKey,
    this.baseUrl,
    this.model,
  });

  final String apiKey;
  final String? baseUrl;
  final String? model;

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    if (apiKey.trim().isEmpty) {
      return QueryResponse.failure(
        error: const RuntimeError(
          code: RuntimeErrorCode.invalidInput,
          message: 'OPENAI_API_KEY is required for openai provider',
          source: 'provider_config',
          retriable: false,
        ),
        output: '[ERROR] missing OPENAI_API_KEY for openai provider',
        modelUsed: model ?? 'openai',
      );
    }

    OpenAI.apiKey = apiKey;
    OpenAI.showLogs = false;
    OpenAI.showResponsesLogs = false;
    if (baseUrl != null && baseUrl!.trim().isNotEmpty) {
      OpenAI.baseUrl = baseUrl!;
    }

    final chosenModel = model ?? 'gpt-4o-mini';
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
