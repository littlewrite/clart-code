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

  test('start command accepts --no-repl', () async {
    final trustFile = File(
      '${Directory.systemTemp.path}/clart_trust_norepl_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final code = await runCli([
        'start',
        '--yes',
        '--no-repl',
        '--trust-file',
        trustFile.path,
      ]);
      expect(code, 0);
    } finally {
      if (trustFile.existsSync()) {
        trustFile.deleteSync();
      }
    }
  });

  test('auth command writes provider key and host into config file', () async {
    final configFile = File(
      '${Directory.systemTemp.path}/clart_auth_cfg_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final code = await runCli([
        'auth',
        '--provider',
        'openai',
        '--api-key',
        'sk-test-123456',
        '--base-url',
        'https://openai.example.com/v1',
        '--config',
        configFile.path,
      ]);
      expect(code, 0);
      expect(configFile.existsSync(), true);

      final decoded = jsonDecode(await configFile.readAsString());
      expect(decoded, isA<Map>());
      final map = decoded as Map<String, dynamic>;
      expect(map['provider'], 'openai');
      expect(map['openAiApiKey'], 'sk-test-123456');
      expect(map['openAiBaseUrl'], 'https://openai.example.com/v1');
    } finally {
      if (configFile.existsSync()) {
        configFile.deleteSync();
      }
    }
  });

  test('init command writes provider key host and model into config file',
      () async {
    final configFile = File(
      '${Directory.systemTemp.path}/clart_init_cfg_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final code = await runCli([
        'init',
        '--provider',
        'openai',
        '--api-key',
        'sk-init-123456',
        '--base-url',
        'https://openai.init.example.com/v1',
        '--model',
        'gpt-4.1-mini',
        '--config',
        configFile.path,
      ]);
      expect(code, 0);
      expect(configFile.existsSync(), true);

      final decoded = jsonDecode(await configFile.readAsString());
      expect(decoded, isA<Map>());
      final map = decoded as Map<String, dynamic>;
      expect(map['provider'], 'openai');
      expect(map['openAiApiKey'], 'sk-init-123456');
      expect(map['openAiBaseUrl'], 'https://openai.init.example.com/v1');
      expect(map['model'], 'gpt-4.1-mini');
    } finally {
      if (configFile.existsSync()) {
        configFile.deleteSync();
      }
    }
  });

  test('buildProviderSetupHint reports local/missing-config states', () {
    const local = AppConfig(provider: ProviderKind.local);
    expect(buildProviderSetupHint(local), isNotNull);
    expect(buildProviderSetupHint(local)!, contains('Run /init'));

    const openAiMissing = AppConfig(provider: ProviderKind.openai);
    expect(buildProviderSetupHint(openAiMissing), isNotNull);
    expect(buildProviderSetupHint(openAiMissing)!, contains('missing API key'));

    const openAiReady = AppConfig(
      provider: ProviderKind.openai,
      openAiApiKey: 'sk-ready-1234',
    );
    expect(buildProviderSetupHint(openAiReady), isNull);
  });

  test('config loader auto-loads .clart/config.json', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_cfg_autoload_',
    );

    try {
      Directory.current = tempDir;
      final configDir = Directory('${tempDir.path}/.clart');
      await configDir.create(recursive: true);
      final configFile = File('${configDir.path}/config.json');
      await configFile.writeAsString(
        jsonEncode({
          'provider': 'claude',
          'claudeApiKey': 'test-claude-key',
          'claudeBaseUrl': 'https://claude.example.com',
          'model': 'claude-test-model',
        }),
      );

      final result = const ConfigLoader().load();
      expect(result.isOk, true);
      expect(result.config, isNotNull);
      expect(result.config!.provider, ProviderKind.claude);
      expect(result.config!.claudeApiKey, 'test-claude-key');
      expect(result.config!.claudeBaseUrl, 'https://claude.example.com');
      expect(result.config!.model, 'claude-test-model');
      expect(result.config!.configPath, isNotNull);
      expect(result.config!.configPath!.endsWith('/.clart/config.json'), true);
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
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

  test('global provider host/key overrides are accepted', () async {
    final code = await runCli([
      '--provider',
      'openai',
      '--openai-api-key',
      'sk-inline-1234',
      '--openai-base-url',
      'https://openai.example.com/v1',
      'version',
    ]);
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

  test('repl accepts --stream-json and exits in non-interactive mode',
      () async {
    final code = await runCli(['repl', '--stream-json']);
    expect(code, 0);
  });

  test('repl rejects invalid ui mode', () async {
    final code = await runCli(['repl', '--ui', 'invalid']);
    expect(code, 2);
  });

  test('start rejects invalid ui mode', () async {
    final code = await runCli(['start', '--ui', 'invalid', '--no']);
    expect(code, 2);
  });

  test('rich composer buffer supports multiline cursor movement', () {
    final buffer = RichComposerBuffer();
    buffer.insert('hello');
    buffer.insert('\n');
    buffer.insert('world');

    expect(buffer.text, 'hello\nworld');
    expect(buffer.cursor, 11);
    expect(buffer.isOnLastLine, true);

    expect(buffer.moveUp(), true);
    expect(buffer.cursor, 5);
    expect(buffer.isOnFirstLine, true);

    expect(buffer.moveLineStart(), true);
    expect(buffer.cursor, 0);
    expect(buffer.moveDown(), true);
    expect(buffer.cursor, 6);
  });

  test('rich composer buffer deleteWordBackward removes previous token', () {
    final buffer = RichComposerBuffer(text: 'hello brave new');

    expect(buffer.deleteWordBackward(), true);
    expect(buffer.text, 'hello brave ');
    expect(buffer.cursor, buffer.text.length);

    expect(buffer.deleteWordBackward(), true);
    expect(buffer.text, 'hello ');
  });

  test('buildRichComposerView keeps cursor line visible', () {
    const input = 'line1\nline2\nline3\nline4\nline5';
    final cursor = input.length;
    final view = buildRichComposerView(input, cursor, 20, maxLines: 3);

    expect(view.visibleLines, ['line3', 'line4', 'line5']);
    expect(view.cursorRow, 2);
    expect(view.cursorCol, 5);
  });

  test('buildRichComposerView maps wrapped cursor on width boundary', () {
    final view = buildRichComposerView('abcdefgh', 8, 4, maxLines: 4);

    expect(view.visibleLines, ['abcd', 'efgh']);
    expect(view.cursorRow, 1);
    expect(view.cursorCol, 4);
  });

  test('buildRichComposerView tracks cursor width for chinese chars', () {
    final view =
        buildRichComposerView('abc你好', 'abc你好'.length, 20, maxLines: 4);

    expect(view.visibleLines, ['abc你好']);
    expect(view.cursorRow, 0);
    expect(view.cursorCol, 7);
  });

  test('buildRichComposerView wraps chinese chars by display width', () {
    final view = buildRichComposerView('你你你', '你你你'.length, 4, maxLines: 4);

    expect(view.visibleLines, ['你你', '你']);
    expect(view.cursorRow, 1);
    expect(view.cursorCol, 2);
  });

  test('rich input utf8 decoder reconstructs chinese chars from bytes', () {
    final decoder = RichInputUtf8Decoder();

    expect(decoder.pushChunk(String.fromCharCode(0xE4)), isNull);
    expect(decoder.pushChunk(String.fromCharCode(0xBD)), isNull);
    expect(decoder.pushChunk(String.fromCharCode(0xA0)), '你');

    expect(decoder.pushChunk(String.fromCharCode(0xE5)), isNull);
    expect(decoder.pushChunk(String.fromCharCode(0xA5)), isNull);
    expect(decoder.pushChunk(String.fromCharCode(0xBD)), '好');
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

  test('query loop emits providerDelta events in stream mode', () async {
    final runtime = AppRuntime(provider: _ChunkedStreamingProvider());
    final engine = QueryEngine(runtime);
    final loop = QueryLoop(engine);
    final events = <QueryEvent>[];

    final result = await loop.run(
      prompt: 'hello',
      maxTurns: 1,
      streamJson: true,
      onEvent: events.add,
    );

    expect(result.success, true);
    expect(result.lastOutput, 'hello world');
    expect(
      events
          .where((event) => event.type == QueryEventType.providerDelta)
          .length,
      2,
    );
    expect(events.last.type, QueryEventType.done);
    expect(events.last.model, 'stream-mock');
    expect(events.last.status, 'ok');
    expect(result.status, 'ok');
    expect(result.modelUsed, 'stream-mock');
  });

  test('query loop emits providerDelta events in text mode callback', () async {
    final runtime = AppRuntime(provider: _ChunkedStreamingProvider());
    final engine = QueryEngine(runtime);
    final loop = QueryLoop(engine);
    final events = <QueryEvent>[];

    final result = await loop.run(
      prompt: 'hello',
      maxTurns: 1,
      streamJson: false,
      onEvent: events.add,
    );

    expect(result.success, true);
    expect(result.status, 'ok');
    expect(result.modelUsed, 'stream-mock');
    expect(
      events
          .where((event) => event.type == QueryEventType.providerDelta)
          .length,
      2,
    );
    expect(events.last.type, QueryEventType.done);
    expect(events.last.model, 'stream-mock');
    expect(events.last.status, 'ok');
  });

  test('query loop marks success false on provider stream error', () async {
    final runtime = AppRuntime(provider: _ErrorStreamingProvider());
    final engine = QueryEngine(runtime);
    final loop = QueryLoop(engine);
    final events = <QueryEvent>[];

    final result = await loop.run(
      prompt: 'hello',
      maxTurns: 1,
      streamJson: true,
      onEvent: events.add,
    );

    expect(result.success, false);
    expect(result.turns, 1);
    expect(events.any((event) => event.type == QueryEventType.error), true);
    expect(events.last.type, QueryEventType.done);
    expect(events.last.status, 'error');
  });
}

class _ThrowingProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    throw StateError('boom');
  }
}

class _ChunkedStreamingProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.success(
        output: 'hello world', modelUsed: 'stream-mock');
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    yield ProviderStreamEvent.textDelta(delta: 'hello ', model: 'stream-mock');
    yield ProviderStreamEvent.textDelta(delta: 'world', model: 'stream-mock');
    yield ProviderStreamEvent.done(output: 'hello world', model: 'stream-mock');
  }
}

class _ErrorStreamingProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.failure(
      error: const RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'stream failure',
        source: 'test',
      ),
      output: '[ERROR] stream failure',
      modelUsed: 'stream-mock',
    );
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    yield ProviderStreamEvent.error(
      error: const RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'stream failure',
        source: 'test',
      ),
      output: '[ERROR] stream failure',
      model: 'stream-mock',
    );
  }
}
