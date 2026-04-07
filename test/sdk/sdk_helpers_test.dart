import 'dart:async';
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

  test('top-level prompt helper supports external cancellation signal',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_cancel_',
    );

    try {
      final controller = sdk.QueryCancellationController();
      final provider = _CancelableHelperProvider();
      final pending = sdk.prompt(
        prompt: 'cancel helper prompt',
        options: sdk.ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
        ),
        cancellationSignal: controller.signal,
      );

      await provider.started.future;
      controller.cancel('helper_cancelled');
      final result = await pending;

      expect(provider.cancelCalled, isTrue);
      expect(result.isError, isTrue);
      expect(result.error?.code.name, 'cancelled');
      expect(result.text, contains('STOPPED'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}

class _CancelableHelperProvider extends sdk.LlmProvider {
  final Completer<void> started = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();
  bool cancelCalled = false;

  @override
  Future<void> cancelActiveRequest() async {
    cancelCalled = true;
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  @override
  Future<sdk.QueryResponse> run(sdk.QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<sdk.ProviderStreamEvent> stream(sdk.QueryRequest request) async* {
    if (!started.isCompleted) {
      started.complete();
    }
    await _cancelled.future;
  }
}
