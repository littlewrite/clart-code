import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

const _defaultOpenAiBaseUrl = 'https://www.dmxapi.com/v1';
const _defaultModel = 'qwen3.5-plus-2026-02-15';

void main() {
  final apiKey = _readEnv([
    'CLART_OPENAI_API_KEY',
    'OPENAI_API_KEY',
  ]);
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

  test(
    'ClartCodeAgent can reach an OpenAI-compatible endpoint',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_sdk_live_openai_',
      );
      try {
        final agent = ClartCodeAgent(
          ClartCodeAgentOptions(
            cwd: tempDir.path,
            provider: ProviderKind.openai,
            openAiApiKey: apiKey,
            openAiBaseUrl: baseUrl,
            model: model,
            allowedTools: const [],
            maxTurns: 1,
            persistSession: false,
          ),
        );

        final result = await agent.prompt(
          'Reply with exactly CLART_OK and nothing else.',
        );

        expect(
          result.isError,
          isFalse,
          reason:
              'provider=openai model=$model baseUrl=$baseUrl text=${result.text} error=${result.error?.message}',
        );
        expect(result.text, contains('CLART_OK'));
        expect(result.messages.last.type, 'result');
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    },
    timeout: Timeout(const Duration(minutes: 2)),
    skip: apiKey == null
        ? 'Set CLART_OPENAI_API_KEY or OPENAI_API_KEY to run live endpoint validation.'
        : false,
  );
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
