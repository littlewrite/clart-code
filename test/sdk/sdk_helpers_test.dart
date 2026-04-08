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

  test('top-level query helper supports per-call effort override', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_query_effort_',
    );

    try {
      final messages = await sdk
          .query(
            prompt: 'hello helper',
            options: sdk.ClartCodeAgentOptions(
              cwd: tempDir.path,
              effort: sdk.ClartCodeReasoningEffort.low,
              providerOverride: _EffortCapturingHelperProvider(),
              persistSession: false,
            ),
            effort: sdk.ClartCodeReasoningEffort.high,
          )
          .toList();

      expect(messages.last.type, 'result');
      expect(messages.last.text, 'effort=high');
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

  test('top-level prompt helper supports per-call effort override', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_prompt_effort_',
    );

    try {
      final result = await sdk.prompt(
        prompt: 'hello helper prompt',
        options: sdk.ClartCodeAgentOptions(
          cwd: tempDir.path,
          effort: sdk.ClartCodeReasoningEffort.low,
          providerOverride: _EffortCapturingHelperProvider(),
          persistSession: false,
        ),
        effort: sdk.ClartCodeReasoningEffort.max,
      );

      expect(result.isError, false);
      expect(result.text, 'effort=max');
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

  test('top-level runSubagent helper returns subagent result', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_subagent_',
    );

    try {
      final result = await sdk.runSubagent(
        prompt: 'inspect helper target',
        options: sdk.ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          providerOverride: _SubagentHelperProvider(),
        ),
        subagent: const sdk.ClartCodeSubagentOptions(
          model: 'child-model',
          allowedTools: ['read'],
        ),
      );

      expect(result.isError, false);
      expect(result.text, 'helper subagent answer');
      expect(result.parentSessionId, isNotEmpty);
      expect(result.sessionId, isNot(result.parentSessionId));
      expect(result.model, 'child-model');
      expect(result.transcriptMessages, hasLength(1));
      expect(
        result.transcriptMessages.single.kind,
        sdk.TranscriptMessageKind.subagent,
      );
      expect(result.cascadedMessages, hasLength(4));
      expect(result.cascadedMessages.first.type, 'subagent');
      expect(result.cascadedMessages.first.subtype, 'start');
      expect(result.cascadedMessages.first.parentSessionId,
          result.parentSessionId);
      expect(result.cascadedMessages.last.type, 'subagent');
      expect(result.cascadedMessages.last.subtype, 'end');
      expect(result.cascadedMessages.last.terminalSubtype, 'success');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('top-level session helpers wrap session store operations', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_session_',
    );

    try {
      final result = await sdk.prompt(
        prompt: 'session helper prompt',
        options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
      );

      expect(sdk.activeSessionId(cwd: tempDir.path), result.sessionId);
      expect(sdk.latestSession(cwd: tempDir.path)?.id, result.sessionId);
      expect(
        sdk.getSessionInfo(sessionId: result.sessionId, cwd: tempDir.path)?.id,
        result.sessionId,
      );
      expect(
        sdk
            .getSessionMessages(sessionId: result.sessionId, cwd: tempDir.path)
            ?.last
            .text,
        'echo: session helper prompt',
      );

      final appended = sdk.appendToSession(
        sessionId: result.sessionId,
        cwd: tempDir.path,
        history: const [
          sdk.ChatMessage(
            role: sdk.MessageRole.user,
            text: 'manual tail',
          ),
        ],
      );
      expect(appended, isNotNull);
      expect(appended!.history.last.text, 'manual tail');

      final renamed = sdk.renameSession(
        sessionId: result.sessionId,
        title: 'Helper Session',
        cwd: tempDir.path,
      );
      expect(renamed?.title, 'Helper Session');

      expect(
        sdk.deleteSession(sessionId: result.sessionId, cwd: tempDir.path),
        isTrue,
      );
      expect(
        sdk.loadSession(sessionId: result.sessionId, cwd: tempDir.path),
        isNull,
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('continue-latest and continue-active helpers resume persisted sessions',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_helpers_continue_',
    );

    try {
      final initial = await sdk.prompt(
        prompt: 'first turn',
        options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
      );

      final latest = await sdk.continueLatestPrompt(
        prompt: 'second turn',
        options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
      );
      final activeMessages = await sdk
          .continueActiveQuery(
            prompt: 'third turn',
            options: sdk.ClartCodeAgentOptions(cwd: tempDir.path),
          )
          .toList();

      expect(latest.sessionId, initial.sessionId);
      expect(activeMessages.last.sessionId, initial.sessionId);

      final persisted = sdk.loadSession(
        sessionId: initial.sessionId,
        cwd: tempDir.path,
      );
      expect(persisted, isNotNull);
      expect(
        persisted!.history
            .where((message) => message.role == sdk.MessageRole.user)
            .map((message) => message.text),
        containsAll(['first turn', 'second turn', 'third turn']),
      );
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

class _SubagentHelperProvider extends sdk.NativeToolCallingLlmProvider {
  @override
  Future<sdk.QueryResponse> run(sdk.QueryRequest request) async {
    expect(request.model, 'child-model');
    expect(request.toolDefinitions.map((tool) => tool.name).toList(), ['read']);
    return sdk.QueryResponse.success(
      output: 'helper subagent answer',
      modelUsed: request.model,
    );
  }
}

class _EffortCapturingHelperProvider extends sdk.NativeToolCallingLlmProvider {
  @override
  Future<sdk.QueryResponse> run(sdk.QueryRequest request) async {
    return sdk.QueryResponse.success(
      output: 'effort=${request.effort?.name}',
      modelUsed: request.model,
    );
  }
}
