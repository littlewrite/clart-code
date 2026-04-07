import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';

const _defaultOpenAiBaseUrl = 'https://www.dmxapi.com/v1';
const _defaultModel = 'qwen3.5-plus-2026-02-15';

Future<void> main(List<String> args) async {
  final apiKey = _readEnv([
    'CLART_OPENAI_API_KEY',
    'OPENAI_API_KEY',
  ]);
  if (apiKey == null) {
    stderr.writeln(
      'Set CLART_OPENAI_API_KEY or OPENAI_API_KEY before running this example.',
    );
    exitCode = 64;
    return;
  }

  final baseUrl = _readEnv([
        'CLART_OPENAI_BASE_URL',
        'OPENAI_BASE_URL',
      ]) ??
      _defaultOpenAiBaseUrl;
  final model = _readEnv([
        'CLART_OPENAI_MODEL',
        'OPENAI_MODEL',
      ]) ??
      _defaultModel;
  final prompt = args.isEmpty
      ? 'Reply with exactly CLART_OK and nothing else.'
      : args.join(' ');

  final agent = ClartCodeAgent(
    ClartCodeAgentOptions(
      provider: ProviderKind.openai,
      openAiApiKey: apiKey,
      openAiBaseUrl: baseUrl,
      model: model,
      allowedTools: const [],
      maxTurns: 1,
      persistSession: false,
    ),
  );

  final watch = Stopwatch()..start();
  await for (final message in agent.query(prompt)) {
    if (message.type == 'assistant_delta' && message.delta != null) {
      stdout.write(message.delta);
      continue;
    }

    if (message.type == 'result') {
      stdout.writeln();
      stdout.writeln('---');
      stdout.writeln(
        'session=${message.sessionId} model=${message.model} error=${message.isError} elapsedMs=${watch.elapsedMilliseconds}',
      );
      if (message.text != null && message.text!.isNotEmpty) {
        stdout.writeln(message.text);
      }
    }
  }
}

String? _readEnv(List<String> keys) {
  for (final key in keys) {
    final value = Platform.environment[key];
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}
