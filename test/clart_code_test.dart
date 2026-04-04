import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clart_code/clart_code.dart';
import 'package:clart_code/src/cli/repl_command_dispatcher.dart';
import 'package:clart_code/src/cli/workspace_store.dart';
import 'package:clart_code/src/tools/tool_registry.dart';
import 'package:clart_code/src/tools/tool_scheduler.dart';
import 'package:test/test.dart';

class _FakeReplCommandSession implements ReplCommandSession {
  _FakeReplCommandSession({
    required this.config,
  });

  @override
  AppConfig config;

  var conversationCleared = false;

  @override
  void clearConversation() {
    conversationCleared = true;
  }
}

class _CapturedRunResult {
  const _CapturedRunResult({
    required this.code,
    required this.output,
  });

  final int code;
  final String output;
}

class _RecordingTool implements Tool {
  _RecordingTool({
    required this.name,
    required this.executionHint,
    required this.log,
    this.delay = Duration.zero,
  });

  @override
  final String name;

  @override
  final ToolExecutionHint executionHint;

  final List<String> log;
  final Duration delay;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    log.add('start:$name');
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    log.add('end:$name');
    return ToolExecutionResult.success(tool: name, output: name);
  }
}

Future<_CapturedRunResult> _capturePrintOutput(
  Future<int> Function() action,
) async {
  final lines = <String>[];
  final code = await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, String line) {
        lines.add(line);
      },
    ),
  );
  return _CapturedRunResult(code: code, output: lines.join('\n'));
}

Future<void> _runGit(
  String workingDirectory,
  List<String> args,
) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

Future<void> _initDirtyGitWorkspace(Directory tempDir) async {
  await _runGit(tempDir.path, const ['init']);
  await _runGit(
    tempDir.path,
    const ['config', 'user.email', 'clart-test@example.com'],
  );
  await _runGit(
    tempDir.path,
    const ['config', 'user.name', 'Clart Test'],
  );

  final trackedFile = File('${tempDir.path}/tracked.txt');
  await trackedFile.writeAsString('hello\n');
  await _runGit(tempDir.path, const ['add', 'tracked.txt']);
  await _runGit(tempDir.path, const ['commit', '-m', 'initial']);

  await trackedFile.writeAsString('hello\nworld\n');
  await File('${tempDir.path}/new_file.dart').writeAsString(
    "void main() {\n  print('hi');\n}\n",
  );
}

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

  test('start welcome screen shows tips and recent activity areas', () async {
    final trustFile = File(
      '${Directory.systemTemp.path}/clart_trust_welcome_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final result = await _capturePrintOutput(() {
        return runCli([
          'start',
          '--yes',
          '--no-repl',
          '--trust-file',
          trustFile.path,
        ]);
      });

      expect(result.code, 0);
      expect(result.output, contains('Tips for getting started'));
      expect(result.output, contains('Recent activity'));
      expect(result.output, contains('Welcome back!'));
    } finally {
      if (trustFile.existsSync()) {
        trustFile.deleteSync();
      }
    }
  });

  test('help shows rich as the default interactive ui', () async {
    final result = await _capturePrintOutput(() => runCli(['help']));

    expect(result.code, 0);
    expect(result.output,
        contains('--ui MODE            plain|rich (default rich)'));
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

  test('applyProviderSetup returns masked summary lines', () async {
    final configFile = File(
      '${Directory.systemTemp.path}/clart_apply_cfg_${DateTime.now().microsecondsSinceEpoch}.json',
    );

    try {
      final result = applyProviderSetup(
        current: AppConfig(
          provider: ProviderKind.local,
          configPath: configFile.path,
        ),
        provider: ProviderKind.openai,
        apiKey: 'sk-apply-123456',
        baseUrl: 'https://openai.apply.example.com/v1',
        model: 'gpt-4.1-mini',
      );

      expect(result.config.provider, ProviderKind.openai);
      expect(result.status, 'Initialized provider config.');
      expect(result.lines, contains('provider=openai'));
      expect(result.lines, contains('model=gpt-4.1-mini'));
      expect(
        result.lines,
        contains('openai.apiKey=***********3456'),
      );
      expect(configFile.existsSync(), true);
    } finally {
      if (configFile.existsSync()) {
        configFile.deleteSync();
      }
    }
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

  test('claude request body includes explicit disabled thinking config', () {
    final body = buildClaudeRequestBodyForTest(
      request: const QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.system, text: 'You are helpful.'),
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
        model: 'claude-test-model',
      ),
      fallbackModel: 'claude-fallback-model',
    );

    expect(body['model'], 'claude-test-model');
    expect(body['max_tokens'], 1024);
    expect(body['thinking'], {'type': 'disabled'});
    expect(body['system'], 'You are helpful.');
    expect(
      body['messages'],
      [
        {'role': 'user', 'content': 'hello'},
      ],
    );
  });

  test('conversation session builds next request from prior turns', () {
    final session = ConversationSession();

    final first = session.prepareInput('hello', model: 'mock-model');
    expect(first.request, isNotNull);
    expect(first.request!.messages.length, 1);
    expect(first.request!.messages.first.text, 'hello');

    session.recordTurn(prompt: 'hello', output: 'hi there');

    final second = session.prepareInput('how are you', model: 'mock-model');
    expect(second.request, isNotNull);
    expect(
      second.request!.messages
          .map((message) => '${message.role.name}:${message.text}')
          .toList(),
      [
        'user:hello',
        'assistant:hi there',
        'user:how are you',
      ],
    );

    session.clear();
    final reset = session.prepareInput('fresh start', model: 'mock-model');
    expect(reset.request, isNotNull);
    expect(reset.request!.messages.length, 1);
    expect(reset.request!.messages.first.text, 'fresh start');
  });

  test(
      'conversation session keeps typed transcript separate from model history',
      () {
    final session = ConversationSession();

    session.appendTranscriptMessages(const [
      TranscriptMessage.localCommand('/status'),
      TranscriptMessage.localCommandStdout('provider=local'),
    ]);

    expect(session.history, isEmpty);
    expect(
      session.transcript.map((message) => message.kind).toList(),
      [
        TranscriptMessageKind.localCommand,
        TranscriptMessageKind.localCommandStdout,
      ],
    );

    session.recordHistoryTurn(prompt: 'hello', output: 'hi there');
    expect(
      session.history
          .map((message) => '${message.role.name}:${message.text}')
          .toList(),
      [
        'user:hello',
        'assistant:hi there',
      ],
    );
    expect(session.transcript, hasLength(2));
  });

  test('prompt submitter reuses conversation history for query submissions',
      () {
    final session = ConversationSession();
    final submitter = PromptSubmitter(conversation: session);

    final first = submitter.submit('hello', model: 'mock-model');
    expect(first.isQuery, true);
    expect(first.request, isNotNull);
    expect(
      first.request!.messages
          .map((message) => '${message.role.name}:${message.text}')
          .toList(),
      ['user:hello'],
    );

    session.recordTurn(prompt: 'hello', output: 'hi there');

    final second = submitter.submit('how are you', model: 'mock-model');
    expect(second.isQuery, true);
    expect(
      second.request!.messages
          .map((message) => '${message.role.name}:${message.text}')
          .toList(),
      [
        'user:hello',
        'assistant:hi there',
        'user:how are you',
      ],
    );
  });

  test('user input processor emits query request and transcript user message',
      () {
    final submission = PromptSubmitter().submit('hello', model: 'mock-model');
    final processed = const UserInputProcessor().process(submission);

    expect(processed.isQuery, true);
    expect(processed.request, isNotNull);
    expect(processed.transcriptMessages.length, 1);
    expect(
      processed.transcriptMessages.first.kind,
      TranscriptMessageKind.userPrompt,
    );
    expect(processed.transcriptMessages.first.text, 'hello');
  });

  test('user input processor promotes slash command callback result', () {
    final submission = PromptSubmitter().submit('/status');
    final processed = const UserInputProcessor().process(
      submission,
      onSlashCommand: (_) => const LocalCommandResult(
        status: 'Displayed status.',
        messages: [
          TranscriptMessage.localCommandStdout('provider=local'),
        ],
      ),
    );

    expect(processed.kind, ProcessUserInputKind.localCommand);
    expect(processed.status, 'Displayed status.');
    expect(processed.transcriptMessages.length, 2);
    expect(processed.transcriptMessages.first.kind,
        TranscriptMessageKind.localCommand);
    expect(processed.transcriptMessages.first.text, '/status');
    expect(
      processed.transcriptMessages.last.kind,
      TranscriptMessageKind.localCommandStdout,
    );
    expect(processed.transcriptMessages.last.text, 'provider=local');
  });

  test('repl slash dispatcher clears conversation for /clear', () {
    final session = _FakeReplCommandSession(
      config: const AppConfig(provider: ProviderKind.local),
    );

    final result = executeReplSlashCommand('/clear', session);

    expect(result, isNotNull);
    expect(result!.clearTranscript, true);
    expect(session.conversationCleared, true);
  });

  test('repl slash dispatcher updates session model for /model', () {
    final session = _FakeReplCommandSession(
      config: const AppConfig(provider: ProviderKind.local),
    );

    final result = executeReplSlashCommand('/model claude-sonnet', session);

    expect(result, isNotNull);
    expect(result!.status, 'Model switched.');
    expect(session.config.model, 'claude-sonnet');
  });

  test('repl slash dispatcher help includes doctor and diff', () {
    final session = _FakeReplCommandSession(
      config: const AppConfig(provider: ProviderKind.local),
    );

    final result = executeReplSlashCommand('/help', session);

    expect(result, isNotNull);
    final lines = result!.messages.map((message) => message.text).toList();
    expect(lines, contains('/doctor   Show workspace/provider diagnostics'));
    expect(lines, contains('/diff     Show current git workspace summary'));
    expect(lines, contains('/mcp      Show local MCP server registry'));
    expect(lines, contains('/session  Show current active session snapshot'));
  });

  test('repl slash dispatcher renders doctor report', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_repl_doctor_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/doctor', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed doctor report.');
      final lines = result.messages.map((message) => message.text).toList();
      expect(lines, contains('provider=local'));
      expect(lines, contains('git.repository=true'));
      expect(lines, contains('git.status=dirty'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders diff summary', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_repl_diff_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/diff', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed diff summary.');
      final lines = result.messages.map((message) => message.text).toList();
      expect(lines, contains('git.files=2'));
      expect(lines, contains('- tracked.txt [modified] (+1/-0)'));
      expect(lines, contains('- new_file.dart [untracked]'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders workspace memory', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_repl_memory_');

    try {
      Directory.current = tempDir;
      writeWorkspaceMemory('remember this');
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/memory', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed workspace memory.');
      expect(result.messages.single.text, 'remember this');
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders workspace tasks', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_repl_tasks_');

    try {
      Directory.current = tempDir;
      addWorkspaceTask('ship mvp');
      completeWorkspaceTask(1);
      addWorkspaceTask('write docs');
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/tasks', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed workspace tasks.');
      final lines = result.messages.map((message) => message.text).toList();
      expect(lines, contains('[x] #1 ship mvp'));
      expect(lines, contains('[ ] #2 write docs'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders workspace permissions', () async {
    final oldCwd = Directory.current;
    final tempDir =
        await Directory.systemTemp.createTemp('clart_repl_permissions_');

    try {
      Directory.current = tempDir;
      writeDefaultToolPermissionMode(ToolPermissionMode.deny);
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/permissions', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed permissions.');
      expect(result.messages.single.text, 'permissions.default=deny');
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders MCP servers', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_repl_mcp_');

    try {
      Directory.current = tempDir;
      upsertWorkspaceMcpServer(
        const WorkspaceMcpServer(
          name: 'local',
          transport: 'stdio',
          target: 'node server.js',
        ),
      );
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/mcp', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed MCP servers.');
      expect(result.messages.single.text, 'local\tstdio\tnode server.js');
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('repl slash dispatcher renders active session snapshot', () async {
    final oldCwd = Directory.current;
    final tempDir =
        await Directory.systemTemp.createTemp('clart_repl_session_');

    try {
      Directory.current = tempDir;
      writeWorkspaceSession(
        buildWorkspaceSessionSnapshot(
          id: 'session-1',
          provider: 'local',
          model: 'mock-model',
          history: const [
            ChatMessage(role: MessageRole.user, text: 'hello'),
            ChatMessage(role: MessageRole.assistant, text: 'hi'),
          ],
          transcript: const [
            TranscriptMessage.userPrompt('hello'),
            TranscriptMessage.assistant('hi'),
          ],
        ),
      );
      final session = _FakeReplCommandSession(
        config: const AppConfig(provider: ProviderKind.local),
      );

      final result = executeReplSlashCommand('/session', session);

      expect(result, isNotNull);
      expect(result!.status, 'Displayed session.');
      final lines = result.messages.map((message) => message.text).toList();
      expect(lines, contains('id=session-1'));
      expect(lines, contains('provider=local'));
      expect(lines, contains('model=mock-model'));
      expect(lines, contains('history.messages=2'));
      expect(lines, contains('transcript.messages=2'));
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

  test('chat rejects slash command input', () async {
    final code = await runCli(['chat', '/exit']);
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
    final code = await runCli([
      '--provider',
      'local',
      'loop',
      '--max-turns',
      '2',
      'hello',
    ]);
    expect(code, 0);
  });

  test('loop command rejects slash command prompt', () async {
    final code = await runCli(['loop', '/exit']);
    expect(code, 2);
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

  test('memory command persists workspace memory file', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_memory_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['memory', 'set', 'project', 'notes']), 0);
      expect(await runCli(['memory', 'append', 'next', 'step']), 0);

      final memoryFile = File('${tempDir.path}/.clart/memory.md');
      expect(memoryFile.existsSync(), true);
      expect(await memoryFile.readAsString(), 'project notes\nnext step');
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('tasks command persists and completes workspace tasks', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_tasks_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['tasks', 'add', 'ship', 'mvp']), 0);
      expect(await runCli(['tasks', 'done', '1']), 0);

      final taskFile = File('${tempDir.path}/.clart/tasks.json');
      final decoded =
          jsonDecode(await taskFile.readAsString()) as List<dynamic>;
      expect(decoded, hasLength(1));
      expect((decoded.first as Map<String, dynamic>)['done'], true);
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('permissions command persists default mode for tool command', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_permissions_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['permissions', 'set', 'deny']), 0);
      expect(await runCli(['tool', 'shell', 'pwd']), 1);

      final permissionsFile = File('${tempDir.path}/.clart/permissions.json');
      final decoded = jsonDecode(await permissionsFile.readAsString());
      expect((decoded as Map<String, dynamic>)['mode'], 'deny');
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('export command writes workspace snapshot', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_export_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['memory', 'set', 'remember this']), 0);
      expect(await runCli(['tasks', 'add', 'write', 'docs']), 0);
      expect(
          await runCli(['mcp', 'add', 'local', 'stdio', 'node server.js']), 0);
      final exportPath = '${tempDir.path}/snapshot.json';

      expect(await runCli(['export', '--out', exportPath]), 0);

      final decoded = jsonDecode(await File(exportPath).readAsString())
          as Map<String, dynamic>;
      expect(decoded['memory'], 'remember this');
      expect(decoded['tasks'] as List<dynamic>, hasLength(1));
      expect(decoded['mcpServers'] as List<dynamic>, hasLength(1));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('diff command emits git workspace json snapshot', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_diff_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;

      final result = await _capturePrintOutput(
        () => runCli(['diff', '--json']),
      );

      expect(result.code, 0);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['isGitRepository'], true);
      expect(decoded['hasChanges'], true);
      expect(decoded['filesChanged'], 2);
      expect(decoded['untrackedFiles'], 1);

      final files = decoded['files'] as List<dynamic>;
      expect(
        files.any(
          (file) => (file as Map<String, dynamic>)['path'] == 'tracked.txt',
        ),
        true,
      );
      expect(
        files.any(
          (file) => (file as Map<String, dynamic>)['path'] == 'new_file.dart',
        ),
        true,
      );
      expect((decoded['patch'] as String), contains('tracked.txt'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('review command runs against current git workspace diff', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_review_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;

      final result = await _capturePrintOutput(
        () => runCli(['review']),
      );

      expect(result.code, 0);
      expect(result.output, contains('echo: You are reviewing'));
      expect(result.output, contains('tracked.txt'));
      expect(result.output, contains('new_file.dart'));

      final sessionsDir = Directory('${tempDir.path}/.clart/sessions');
      expect(sessionsDir.existsSync(), true);
      final sessionFiles = sessionsDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList();
      expect(sessionFiles, hasLength(1));

      final snapshot = jsonDecode(
        await sessionFiles.first.readAsString(),
      ) as Map<String, dynamic>;
      expect((snapshot['history'] as List<dynamic>), hasLength(2));
      expect((snapshot['transcript'] as List<dynamic>), hasLength(2));
      expect(snapshot['title'], contains('You are reviewing the current git'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('review --prompt-only prints generated review prompt', () async {
    final oldCwd = Directory.current;
    final tempDir =
        await Directory.systemTemp.createTemp('clart_review_prompt_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;

      final result = await _capturePrintOutput(
        () => runCli(['review', '--prompt-only', 'focus', 'tests']),
      );

      expect(result.code, 0);
      expect(result.output, contains('Extra review instructions: focus tests'));
      expect(result.output, contains('Tracked file patch:'));
      expect(result.output, contains('Untracked file previews:'));
      expect(result.output, contains('new_file.dart'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('chat persists session and resume updates same snapshot', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_session_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['chat', 'hello']), 0);

      final sessionsDir = Directory('${tempDir.path}/.clart/sessions');
      expect(sessionsDir.existsSync(), true);
      final sessionFiles = sessionsDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList();
      expect(sessionFiles, hasLength(1));

      final initialSnapshot = jsonDecode(
        await sessionFiles.first.readAsString(),
      ) as Map<String, dynamic>;
      expect((initialSnapshot['history'] as List<dynamic>), hasLength(2));
      expect((initialSnapshot['transcript'] as List<dynamic>), hasLength(2));

      expect(await runCli(['resume', '--last', 'how are you']), 0);

      final resumedSnapshot = jsonDecode(
        await sessionFiles.first.readAsString(),
      ) as Map<String, dynamic>;
      expect((resumedSnapshot['history'] as List<dynamic>), hasLength(4));
      expect(
        ((resumedSnapshot['history'] as List<dynamic>).last
            as Map<String, dynamic>)['text'],
        'echo: hello\nhow are you',
      );
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('share command exports active session as markdown', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_share_');

    try {
      Directory.current = tempDir;
      expect(await runCli(['chat', 'hello share']), 0);
      final outputPath = '${tempDir.path}/session.md';

      expect(await runCli(['share', '--out', outputPath]), 0);

      final markdown = await File(outputPath).readAsString();
      expect(markdown, contains('# hello share'));
      expect(markdown, contains('## Transcript'));
      expect(markdown, contains('assistant'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('doctor reports git workspace state', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_doctor_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;

      final result = await _capturePrintOutput(
        () => runCli(['doctor']),
      );

      expect(result.code, 0);
      expect(result.output, contains('git.repository=true'));
      expect(result.output, contains('git.status=dirty'));
      expect(result.output, contains('git.files=2'));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('export command includes git workspace snapshot', () async {
    final oldCwd = Directory.current;
    final tempDir = await Directory.systemTemp.createTemp('clart_export_git_');

    try {
      await _initDirtyGitWorkspace(tempDir);
      Directory.current = tempDir;
      final exportPath = '${tempDir.path}/snapshot.json';

      expect(await runCli(['export', '--out', exportPath]), 0);

      final decoded = jsonDecode(await File(exportPath).readAsString())
          as Map<String, dynamic>;
      final git = decoded['git'] as Map<String, dynamic>;
      expect(git['isGitRepository'], true);
      expect(git['hasChanges'], true);
      expect(git['filesChanged'], 2);
      expect(git['untrackedFiles'], 1);
      expect(git['files'] as List<dynamic>, hasLength(2));
    } finally {
      Directory.current = oldCwd;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
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

  test('rich repl immediate eof falls back to plain mode', () {
    expect(
      shouldFallbackToPlainReplOnImmediateEof(
        richInputReturnedEof: true,
        hasTranscript: false,
        hasInputHistory: false,
        elapsedSincePrompt: const Duration(milliseconds: 50),
      ),
      isTrue,
    );

    expect(
      shouldFallbackToPlainReplOnImmediateEof(
        richInputReturnedEof: true,
        hasTranscript: true,
        hasInputHistory: false,
        elapsedSincePrompt: const Duration(milliseconds: 50),
      ),
      isFalse,
    );

    expect(
      shouldFallbackToPlainReplOnImmediateEof(
        richInputReturnedEof: true,
        hasTranscript: false,
        hasInputHistory: false,
        elapsedSincePrompt: const Duration(seconds: 1),
      ),
      isFalse,
    );
  });

  test('tool scheduler preserves order and splits parallel batches', () async {
    final log = <String>[];
    final scheduler = ToolScheduler();
    final registry = ToolRegistry(
      tools: [
        _RecordingTool(
          name: 'read_a',
          executionHint: ToolExecutionHint.parallelSafe,
          log: log,
          delay: const Duration(milliseconds: 30),
        ),
        _RecordingTool(
          name: 'read_b',
          executionHint: ToolExecutionHint.parallelSafe,
          log: log,
          delay: const Duration(milliseconds: 10),
        ),
        _RecordingTool(
          name: 'write_mid',
          executionHint: ToolExecutionHint.serialOnly,
          log: log,
        ),
        _RecordingTool(
          name: 'read_c',
          executionHint: ToolExecutionHint.parallelSafe,
          log: log,
        ),
      ],
    );

    final results = await scheduler.runBatch(
      invocations: const [
        ToolInvocation(name: 'read_a'),
        ToolInvocation(name: 'read_b'),
        ToolInvocation(name: 'write_mid'),
        ToolInvocation(name: 'read_c'),
      ],
      registry: registry,
      permissionPolicy: const ToolPermissionPolicy(),
    );

    expect(results.map((result) => result.tool).toList(),
        ['read_a', 'read_b', 'write_mid', 'read_c']);

    final writeStartIndex = log.indexOf('start:write_mid');
    final readCStartIndex = log.indexOf('start:read_c');
    expect(writeStartIndex, greaterThan(log.indexOf('end:read_a')));
    expect(writeStartIndex, greaterThan(log.indexOf('end:read_b')));
    expect(readCStartIndex, greaterThan(log.indexOf('end:write_mid')));
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

  test('rich input parser decodes bracketed paste with newlines', () {
    final token = parseRichInputBytesForTest([
      0x1B,
      0x5B,
      0x32,
      0x30,
      0x30,
      0x7E,
      ...utf8.encode('line1\r\nline2\nline3'),
      0x1B,
      0x5B,
      0x32,
      0x30,
      0x31,
      0x7E,
    ]);

    expect(token.kind, RichInputTokenKind.paste);
    expect(token.text, 'line1\nline2\nline3');
  });

  test('rich input parser decodes utf8 printable chars', () {
    final token = parseRichInputBytesForTest(utf8.encode('你'));

    expect(token.kind, RichInputTokenKind.text);
    expect(token.text, '你');
  });

  test('rich terminal byte reader retries transient eof before data', () {
    final values = <int>[-1, -1, 0x61];
    var transientEofCount = 0;

    final value = readRichInputByteSyncForTest(
      () => values.removeAt(0),
      stdinHasTerminal: true,
      onTransientEof: () {
        transientEofCount += 1;
      },
    );

    expect(value, 0x61);
    expect(transientEofCount, 2);
  });

  test('rich terminal byte reader preserves eof for non-terminal input', () {
    final value = readRichInputByteSyncForTest(
      () => -1,
      stdinHasTerminal: false,
    );

    expect(value, -1);
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

  test('query loop stops after first turn without continuation builder',
      () async {
    final runtime = AppRuntime(provider: LocalEchoProvider());
    final engine = QueryEngine(runtime);
    final loop = QueryLoop(engine);
    final result = await loop.run(prompt: 'hello', maxTurns: 3);

    expect(result.success, true);
    expect(result.turns, 1);
    expect(result.lastOutput, 'echo: hello');
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

  test('turn executor emits provider deltas and assistant transcript',
      () async {
    final runtime = AppRuntime(provider: _ChunkedStreamingProvider());
    final engine = QueryEngine(runtime);
    final executor = TurnExecutor(engine);
    final events = <QueryEvent>[];

    final result = await executor.execute(
      request: const QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      ),
      turn: 1,
      onEvent: events.add,
    );

    expect(result.success, true);
    expect(result.output, 'hello world');
    expect(result.displayOutput, 'hello world');
    expect(result.rawOutput, 'hello world');
    expect(result.transcriptMessages, hasLength(1));
    expect(
        result.transcriptMessages.first.kind, TranscriptMessageKind.assistant);
    expect(
      events.map((event) => event.type).toList(),
      [
        QueryEventType.turnStart,
        QueryEventType.providerDelta,
        QueryEventType.providerDelta,
        QueryEventType.assistant,
      ],
    );
  });

  test('turn executor normalizes provider config errors', () async {
    final runtime = AppRuntime(provider: _MissingConfigStreamingProvider());
    final engine = QueryEngine(runtime);
    final executor = TurnExecutor(engine);
    final events = <QueryEvent>[];

    final result = await executor.execute(
      request: const QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      ),
      turn: 1,
      onEvent: events.add,
    );

    expect(result.failed, true);
    expect(
      result.output,
      'Provider is not configured. Run /init or clart_code init.',
    );
    expect(result.transcriptMessages.first.text, result.output);
    expect(events.last.type, QueryEventType.error);
    expect(events.last.output, result.output);
  });

  test('turn executor returns interrupted display output for empty partials',
      () async {
    final runtime = AppRuntime(provider: _SlowStreamingProvider());
    final engine = QueryEngine(runtime);
    final executor = TurnExecutor(engine);
    final events = <QueryEvent>[];

    final result = await executor.execute(
      request: const QueryRequest(
        messages: [
          ChatMessage(role: MessageRole.user, text: 'hello'),
        ],
      ),
      turn: 1,
      onEvent: events.add,
      interruptSignals: Stream<void>.fromFuture(Future<void>.value()),
    );

    expect(result.interrupted, true);
    expect(result.output, isEmpty);
    expect(result.displayOutput, '[interrupted]');
    expect(result.transcriptMessages.first.text, '[interrupted]');
    expect(
        events.map((event) => event.type).toList(), [QueryEventType.turnStart]);
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

class _MissingConfigStreamingProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.failure(
      error: const RuntimeError(
        code: RuntimeErrorCode.invalidInput,
        message: 'missing config',
        source: 'provider_config',
      ),
      output: '[ERROR] missing config',
      modelUsed: 'config-mock',
    );
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    yield ProviderStreamEvent.error(
      error: const RuntimeError(
        code: RuntimeErrorCode.invalidInput,
        message: 'missing config',
        source: 'provider_config',
      ),
      output: '[ERROR] missing config',
      model: 'config-mock',
    );
  }
}

class _SlowStreamingProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.success(output: 'slow', modelUsed: 'slow-mock');
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    yield ProviderStreamEvent.textDelta(delta: 'slow', model: 'slow-mock');
    yield ProviderStreamEvent.done(output: 'slow', model: 'slow-mock');
  }
}
