import 'dart:convert';
import 'dart:io';

import 'package:clart_code/clart_code.dart';
import 'package:test/test.dart';

void main() {
  test('version exits with 0', () async {
    final code = await runCli(['version']);
    expect(code, 0);
  });

  test('start command can be denied explicitly', () async {
    final code = await runCli(['start', '--no']);
    expect(code, 1);
  });

  test('start command accepts --yes and persists trust', () async {
    final trustFile = File(
      '${Directory.systemTemp.path}/clart_trust_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final code = await runCli([
        'start',
        '--yes',
        '--trust-file',
        trustFile.path,
      ]);
      expect(code, 0);
      expect(trustFile.existsSync(), true);
    } finally {
      if (trustFile.existsSync()) {
        trustFile.deleteSync();
      }
    }
  });

  test('start command rejects conflicting trust flags', () async {
    final code = await runCli(['start', '--yes', '--no']);
    expect(code, 2);
  });

  test('chat without prompt exits with error', () async {
    final code = await runCli(['chat']);
    expect(code, 2);
  });

  test('unknown command exits with error', () async {
    final code = await runCli(['unknown']);
    expect(code, 2);
  });

  test('global provider flag accepts local', () async {
    final code = await runCli(['--provider', 'local', 'chat', 'hello']);
    expect(code, 0);
  });

  test('global provider flag rejects invalid value', () async {
    final code = await runCli(['--provider', 'invalid', 'chat', 'hello']);
    expect(code, 2);
  });

  test('global provider flag accepts openai', () async {
    final code = await runCli(['--provider', 'openai', 'version']);
    expect(code, 0);
  });

  test('openai provider returns error when api key is missing', () async {
    final configFile = File(
      '${Directory.systemTemp.path}/clart_openai_cfg_${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await configFile.writeAsString(
      jsonEncode({
        'provider': 'openai',
        'openAiApiKey': '',
      }),
    );

    try {
      final code = await runCli([
        '--config',
        configFile.path,
        '--provider',
        'openai',
        'chat',
        'hello',
      ]);
      expect(code, 1);
    } finally {
      if (configFile.existsSync()) {
        configFile.deleteSync();
      }
    }
  });

  test('claude provider returns error when api key is missing', () async {
    final configFile = File(
      '${Directory.systemTemp.path}/clart_claude_cfg_${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await configFile.writeAsString(
      jsonEncode({
        'provider': 'claude',
        'claudeApiKey': '',
      }),
    );

    try {
      final code = await runCli([
        '--config',
        configFile.path,
        '--provider',
        'claude',
        'chat',
        'hello',
      ]);
      expect(code, 1);
    } finally {
      if (configFile.existsSync()) {
        configFile.deleteSync();
      }
    }
  });

  test('loop command runs with max turns', () async {
    final code = await runCli(['loop', '--max-turns', '2', 'hello']);
    expect(code, 0);
  });

  test('loop command rejects invalid max turns', () async {
    final code = await runCli(['loop', '--max-turns', 'x', 'hello']);
    expect(code, 2);
  });

  test('tool read command runs', () async {
    final file = File(
      '${Directory.systemTemp.path}/clart_tool_read_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString('hello');

    try {
      final code = await runCli(['tool', 'read', file.path]);
      expect(code, 0);
    } finally {
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  });

  test('tool write command runs', () async {
    final file = File(
      '${Directory.systemTemp.path}/clart_tool_write_${DateTime.now().microsecondsSinceEpoch}.txt',
    );

    try {
      final code = await runCli(['tool', 'write', file.path, 'hello', 'dart']);
      expect(code, 0);
      expect(await file.readAsString(), 'hello dart');
    } finally {
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  });

  test('tool command honors deny permission mode', () async {
    final code = await runCli([
      'tool',
      '--permission',
      'deny',
      'shell',
      'echo hello',
    ]);
    expect(code, 1);
  });

  test('query engine maps provider exception to providerFailure', () async {
    final runtime = AppRuntime(provider: _ThrowingProvider());
    final engine = QueryEngine(runtime);
    final response = await engine.run(
      const QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      ),
    );

    expect(response.isOk, false);
    expect(response.error, isNotNull);
    expect(response.error!.code, RuntimeErrorCode.providerFailure);
  });

  test('query loop marks success false on provider failure', () async {
    final runtime = AppRuntime(provider: _ThrowingProvider());
    final engine = QueryEngine(runtime);
    final loop = QueryLoop(engine);
    final result = await loop.run(prompt: 'hello', maxTurns: 2);

    expect(result.success, false);
    expect(result.turns, 1);
  });
}

class _ThrowingProvider implements LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    throw StateError('boom');
  }
}
