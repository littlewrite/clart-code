import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart' as sdk;
import 'package:test/test.dart';

void main() {
  test('top-level query helper streams sdk messages', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_query_',
    );

    try {
      final messages = await sdk
          .query(
            prompt: 'hello helper',
            options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
          )
          .toList();

      expect(messages.map((message) => message.type), [
        'system',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(messages.last.text, 'echo: hello helper');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('top-level prompt helper returns terminal result', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_prompt_',
    );

    try {
      final result = await sdk.prompt(
        prompt: 'hello helper prompt',
        options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
      );

      expect(result.isError, false);
      expect(result.text, 'echo: hello helper prompt');
      expect(result.messages.last.type, 'result');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}
