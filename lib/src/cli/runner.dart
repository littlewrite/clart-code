import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_console/dart_console.dart';

import '../core/app_config.dart';
import '../core/models.dart';
import '../core/query_engine.dart';
import '../core/query_loop.dart';
import '../providers/llm_provider.dart';
import '../runtime/app_runtime.dart';
import '../services/security_guard.dart';
import '../services/telemetry.dart';
import '../tools/tool_models.dart';
import '../tools/tool_permissions.dart';
import '../ui/startup_experience.dart';
import 'command_registry.dart';

class ParsedCli {
  const ParsedCli({
    required this.command,
    required this.commandArgs,
    this.provider,
    this.model,
    this.configPath,
    this.claudeApiKey,
    this.claudeBaseUrl,
    this.openAiApiKey,
    this.openAiBaseUrl,
    this.error,
  });

  final String command;
  final List<String> commandArgs;
  final String? provider;
  final String? model;
  final String? configPath;
  final String? claudeApiKey;
  final String? claudeBaseUrl;
  final String? openAiApiKey;
  final String? openAiBaseUrl;
  final String? error;

  bool get isOk => error == null;
}

enum _ReplUiMode { plain, rich }

Future<int> runCli(List<String> args) async {
  final parsed = _parseCli(args);
  if (!parsed.isOk) {
    print('error: ${parsed.error}');
    _printHelp();
    return 2;
  }

  final configResult = const ConfigLoader().load(
    configPath: parsed.configPath,
    providerOverride: parsed.provider,
    modelOverride: parsed.model,
    claudeApiKeyOverride: parsed.claudeApiKey,
    claudeBaseUrlOverride: parsed.claudeBaseUrl,
    openAiApiKeyOverride: parsed.openAiApiKey,
    openAiBaseUrlOverride: parsed.openAiBaseUrl,
  );
  if (!configResult.isOk) {
    print('error: ${configResult.error}');
    return 2;
  }

  final config = configResult.config!;
  final provider = _resolveProvider(config);
  final runtime = AppRuntime(
    provider: provider,
    telemetry: const TelemetryService(),
    securityGuard: const SecurityGuard(
      enableHardening: false,
      enableMaliciousPromptFilter: false,
    ),
  );
  final engine = QueryEngine(runtime);

  final commands = buildCommands(all: [
    RegisteredCommand(
      name: 'help',
      aliases: const ['--help'],
      description: 'Show help',
      handler: (_) async {
        _printHelp();
        return 0;
      },
    ),
    RegisteredCommand(
      name: 'version',
      aliases: const ['--version', '-v'],
      description: 'Show version',
      handler: (_) async {
        print('clart_code 0.3.0');
        return 0;
      },
    ),
    RegisteredCommand(
      name: 'start',
      description: 'Interactive startup (trust gate + welcome + REPL)',
      handler: _runStartCommand,
    ),
    RegisteredCommand(
      name: 'chat',
      description: 'Send a single prompt and print response',
      handler: runChatLikeCommand,
    ),
    RegisteredCommand(
      name: 'print',
      description: 'Alias of chat',
      handler: runChatLikeCommand,
    ),
    RegisteredCommand(
      name: 'repl',
      description: 'Run interactive chat loop with streaming output',
      handler: _runReplCommand,
    ),
    RegisteredCommand(
      name: 'auth',
      description: 'Save provider auth config (provider + key + host)',
      handler: _runAuthCommand,
    ),
    RegisteredCommand(
      name: 'init',
      description: 'Initialize provider config for real LLM usage',
      handler: _runInitCommand,
    ),
    RegisteredCommand(
      name: 'loop',
      description: 'Run minimal multi-turn loop (Iteration 9 stream baseline)',
      handler: _runLoopCommand,
    ),
    RegisteredCommand(
      name: 'tool',
      description: 'Run minimal built-in tool executor (Iteration 4 baseline)',
      handler: _runToolCommand,
    ),
    RegisteredCommand(
      name: 'status',
      description: 'Show runtime status/config snapshot',
      handler: (ctx) async {
        print('provider=${ctx.config.provider.name}');
        print('model=${ctx.config.model ?? '-'}');
        print('config=${ctx.config.configPath ?? '-'}');
        _printProviderConfigSummary(ctx.config);
        return 0;
      },
    ),
    RegisteredCommand(
      name: 'features',
      description: 'Show currently implemented migration features',
      handler: (_) async {
        print('Implemented now:');
        print('- command registry + dispatcher');
        print(
            '- config loading (env + JSON file, with .clart/config.json fallback)');
        print('- provider switching (local/claude/openai)');
        print('- auth config command (provider + key + host)');
        print('- one-shot chat/print');
        print('- startup trust gate + welcome screen');
        print('- interactive REPL loop with streaming output');
        print('- optional rich UI mode (full-screen)');
        print('- multi-turn loop with provider-level stream-json');
        print('- tool abstraction + serial scheduler');
        print('- built-in tools: read/write/shell-stub');
        print('- tool permission policy (allow|deny)');
        print('- telemetry no-op shell');
        return 0;
      },
    ),
  ]);

  final command = commands.firstWhere(
    (c) => c.matches(parsed.command),
    orElse: () => const RegisteredCommand(
      name: '__unknown__',
      description: 'unknown',
      handler: _unknownCommand,
    ),
  );

  runtime.telemetry.logEvent('command_start', {'command': parsed.command});
  final code = await command.handler(
    CommandContext(
      command: parsed.command,
      args: parsed.commandArgs,
      config: config,
      engine: engine,
    ),
  );
  runtime.telemetry.logEvent('command_end', {
    'command': parsed.command,
    'code': code,
  });
  return code;
}

Future<int> _unknownCommand(CommandContext context) async {
  print('error: unknown command "${context.command}"');
  _printHelp();
  return 2;
}

Future<int> _runReplCommand(CommandContext context) async {
  var streamJson = false;
  var uiMode = _ReplUiMode.plain;

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--stream-json') {
      streamJson = true;
      i += 1;
      continue;
    }
    if (token == '--ui') {
      if (i + 1 >= context.args.length) {
        print('error: --ui requires a value: plain|rich');
        return 2;
      }
      final parsed = _parseReplUiMode(context.args[i + 1]);
      if (parsed == null) {
        print('error: --ui must be plain|rich');
        return 2;
      }
      uiMode = parsed;
      i += 2;
      continue;
    }
    print('error: unknown option for repl: $token');
    return 2;
  }

  return _runInteractiveRepl(
    context,
    streamJson: streamJson,
    printIntro: true,
    uiMode: uiMode,
  );
}

Future<int> _runAuthCommand(CommandContext context) async {
  String? providerRaw;
  String? apiKey;
  String? baseUrl;
  String? configPath;
  var showOnly = false;

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--provider') {
      if (i + 1 >= context.args.length) {
        print('error: --provider requires local|claude|openai');
        return 2;
      }
      providerRaw = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--api-key') {
      if (i + 1 >= context.args.length) {
        print('error: --api-key requires a value');
        return 2;
      }
      apiKey = context.args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--base-url') {
      if (i + 1 >= context.args.length) {
        print('error: --base-url requires a value');
        return 2;
      }
      baseUrl = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--config') {
      if (i + 1 >= context.args.length) {
        print('error: --config requires a path');
        return 2;
      }
      configPath = context.args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--show') {
      showOnly = true;
      i += 1;
      continue;
    }

    print('error: unknown option for auth: $token');
    return 2;
  }

  final selectedProvider = _parseProviderKind(providerRaw);
  if (providerRaw != null && selectedProvider == null) {
    print('error: --provider must be local|claude|openai');
    return 2;
  }
  final providerKind = selectedProvider ?? context.config.provider;
  final resolvedPath = configPath ??
      context.config.configPath ??
      defaultConfigPath(cwd: Directory.current.path);

  final existing = _readConfigJsonFile(resolvedPath);
  if (showOnly) {
    final merged = _mergeConfigMapIntoAppConfig(context.config, existing);
    print('config=$resolvedPath');
    print('provider=${merged.provider.name}');
    _printProviderConfigSummary(merged);
    return 0;
  }

  if (providerKind == ProviderKind.local) {
    print('error: auth only supports provider claude|openai');
    return 2;
  }

  var effectiveApiKey = apiKey?.trim();
  if (effectiveApiKey == null || effectiveApiKey.isEmpty) {
    if (!stdin.hasTerminal) {
      print('error: --api-key is required in non-interactive mode');
      return 2;
    }
    stdout.write('Enter API key for ${providerKind.name}: ');
    effectiveApiKey = stdin.readLineSync()?.trim();
  }
  if (effectiveApiKey == null || effectiveApiKey.isEmpty) {
    print('error: api key cannot be empty');
    return 2;
  }

  final next = Map<String, Object?>.from(existing);
  next['provider'] = providerKind.name;
  if (providerKind == ProviderKind.claude) {
    next['claudeApiKey'] = effectiveApiKey;
    if (baseUrl != null && baseUrl.isNotEmpty) {
      next['claudeBaseUrl'] = baseUrl;
    }
  } else {
    next['openAiApiKey'] = effectiveApiKey;
    if (baseUrl != null && baseUrl.isNotEmpty) {
      next['openAiBaseUrl'] = baseUrl;
    }
  }

  final file = File(resolvedPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(next),
  );

  print('Saved auth config to $resolvedPath');
  print('provider=${providerKind.name}');
  if (baseUrl != null && baseUrl.isNotEmpty) {
    print('baseUrl=$baseUrl');
  }
  print('apiKey=${_maskSecret(effectiveApiKey)}');
  print('');
  print('Try now:');
  print('  fvm dart run ./bin/clart_code.dart');
  return 0;
}

Future<int> _runInitCommand(CommandContext context) async {
  String? providerRaw;
  String? apiKey;
  String? baseUrl;
  String? model;
  String? configPath;

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--provider') {
      if (i + 1 >= context.args.length) {
        print('error: --provider requires claude|openai');
        return 2;
      }
      providerRaw = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--api-key') {
      if (i + 1 >= context.args.length) {
        print('error: --api-key requires a value');
        return 2;
      }
      apiKey = context.args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--base-url') {
      if (i + 1 >= context.args.length) {
        print('error: --base-url requires a value');
        return 2;
      }
      baseUrl = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--model') {
      if (i + 1 >= context.args.length) {
        print('error: --model requires a value');
        return 2;
      }
      model = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--config') {
      if (i + 1 >= context.args.length) {
        print('error: --config requires a path');
        return 2;
      }
      configPath = context.args[i + 1];
      i += 2;
      continue;
    }

    print('error: unknown option for init: $token');
    return 2;
  }

  final resolvedPath = configPath ??
      context.config.configPath ??
      defaultConfigPath(cwd: Directory.current.path);
  final existingRaw = _readConfigJsonFile(resolvedPath);
  final existing = _mergeConfigMapIntoAppConfig(
    context.config.copyWith(configPath: resolvedPath),
    existingRaw,
  );

  ProviderKind? providerKind;
  if (providerRaw != null) {
    providerKind = _parseProviderKind(providerRaw);
    if (providerKind == null || providerKind == ProviderKind.local) {
      print('error: --provider must be claude|openai');
      return 2;
    }
  } else if (existing.provider != ProviderKind.local) {
    providerKind = existing.provider;
  }

  if (providerKind == null) {
    if (!stdin.hasTerminal) {
      print('error: missing provider; set --provider claude|openai');
      return 2;
    }
    stdout.write('Provider (claude/openai): ');
    final selected = stdin.readLineSync()?.trim();
    providerKind = _parseProviderKind(selected);
    if (providerKind == null || providerKind == ProviderKind.local) {
      print('error: provider must be claude|openai');
      return 2;
    }
  }

  final existingApiKey = providerKind == ProviderKind.claude
      ? existing.claudeApiKey
      : existing.openAiApiKey;
  final hasExistingApiKey = existingApiKey?.trim().isNotEmpty == true;

  var effectiveApiKey = apiKey?.trim();
  if (effectiveApiKey == null || effectiveApiKey.isEmpty) {
    if (!stdin.hasTerminal) {
      print('error: missing api key; set --api-key');
      return 2;
    }
    stdout.write(
      'API key for ${providerKind.name}${hasExistingApiKey ? ' (Enter to keep current)' : ''}: ',
    );
    final entered = stdin.readLineSync()?.trim() ?? '';
    if (entered.isEmpty && hasExistingApiKey) {
      effectiveApiKey = existingApiKey!.trim();
    } else {
      effectiveApiKey = entered;
    }
  }
  if (effectiveApiKey.isEmpty) {
    print('error: api key cannot be empty');
    return 2;
  }

  if (baseUrl == null && stdin.hasTerminal && context.args.isEmpty) {
    final currentBaseUrl = providerKind == ProviderKind.claude
        ? existing.claudeBaseUrl
        : existing.openAiBaseUrl;
    stdout.write(
      'Base URL (optional${currentBaseUrl?.trim().isNotEmpty == true ? ', Enter to keep current' : ''}): ',
    );
    final entered = stdin.readLineSync()?.trim() ?? '';
    if (entered.isNotEmpty) {
      baseUrl = entered;
    }
  }

  if (model == null && stdin.hasTerminal && context.args.isEmpty) {
    stdout.write(
      'Model (optional${existing.model?.trim().isNotEmpty == true ? ', Enter to keep current' : ''}): ',
    );
    final entered = stdin.readLineSync()?.trim() ?? '';
    if (entered.isNotEmpty) {
      model = entered;
    }
  }

  final nextConfig = saveProviderSetup(
    current: existing,
    provider: providerKind,
    apiKey: effectiveApiKey,
    baseUrl: baseUrl,
    model: model,
    configPath: resolvedPath,
  );

  print('Saved init config to ${nextConfig.configPath}');
  print('provider=${nextConfig.provider.name}');
  print('model=${nextConfig.model ?? 'default'}');
  _printProviderConfigSummary(nextConfig);
  print('');
  print('Try now:');
  print('  fvm dart run ./bin/clart_code.dart');
  return 0;
}

Future<int> _runLoopCommand(CommandContext context) async {
  var maxTurns = 1;
  var streamJson = false;
  final promptTokens = <String>[];

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--stream-json') {
      streamJson = true;
      i += 1;
      continue;
    }
    if (token == '--max-turns') {
      if (i + 1 >= context.args.length) {
        print('error: --max-turns requires a number');
        return 2;
      }
      final parsed = int.tryParse(context.args[i + 1]);
      if (parsed == null || parsed < 1) {
        print('error: --max-turns must be a positive integer');
        return 2;
      }
      maxTurns = parsed;
      i += 2;
      continue;
    }
    promptTokens.add(token);
    i += 1;
  }

  final prompt = promptTokens.join(' ').trim();
  if (prompt.isEmpty) {
    print('error: missing prompt text');
    return 2;
  }

  final loop = QueryLoop(context.engine);
  final result = await loop.run(
    prompt: prompt,
    maxTurns: maxTurns,
    streamJson: streamJson,
    model: context.config.model,
  );

  if (!streamJson) {
    print(result.lastOutput);
    print(
      '[loop_done] turns=${result.turns} status=${result.status} model=${result.modelUsed ?? '-'}',
    );
  }

  return result.success ? 0 : 1;
}

Future<int> _runStartCommand(CommandContext context) async {
  var assumeTrusted = false;
  var denyTrust = false;
  var noRepl = false;
  var uiMode = _ReplUiMode.plain;
  String? trustFilePath;

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--yes') {
      assumeTrusted = true;
      i += 1;
      continue;
    }
    if (token == '--no') {
      denyTrust = true;
      i += 1;
      continue;
    }
    if (token == '--trust-file') {
      if (i + 1 >= context.args.length) {
        print('error: --trust-file requires a path');
        return 2;
      }
      trustFilePath = context.args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--no-repl') {
      noRepl = true;
      i += 1;
      continue;
    }
    if (token == '--ui') {
      if (i + 1 >= context.args.length) {
        print('error: --ui requires a value: plain|rich');
        return 2;
      }
      final parsed = _parseReplUiMode(context.args[i + 1]);
      if (parsed == null) {
        print('error: --ui must be plain|rich');
        return 2;
      }
      uiMode = parsed;
      i += 2;
      continue;
    }

    print('error: unknown option for start: $token');
    return 2;
  }

  if (assumeTrusted && denyTrust) {
    print('error: --yes and --no cannot be used together');
    return 2;
  }

  final startup = StartupExperience();
  final trustStore = TrustStore(
    trustFilePath ?? defaultTrustStorePath(),
  );
  final cwd = Directory.current.absolute.path;
  final decision = await startup.ensureTrusted(
    directoryPath: cwd,
    trustStore: trustStore,
    assumeTrusted: assumeTrusted,
    denyTrust: denyTrust,
  );

  if (!decision.allowed) {
    if (denyTrust) {
      print('exit: folder is not trusted.');
      return 1;
    }

    if (!stdin.hasTerminal) {
      print('error: current folder is not trusted in non-interactive mode.');
      print('hint: run `clart_code start --yes` to trust this folder.');
      return 1;
    }

    print('exit: folder is not trusted.');
    return 1;
  }

  startup.renderWelcome(cwd: cwd, config: context.config);
  if (noRepl || !stdin.hasTerminal) {
    return 0;
  }
  return _runInteractiveRepl(
    context,
    streamJson: false,
    printIntro: false,
    uiMode: uiMode,
  );
}

class _ReplSessionState {
  _ReplSessionState({
    required this.config,
  });

  AppConfig config;

  ProviderKind get provider => config.provider;

  set provider(ProviderKind value) {
    config = config.copyWith(provider: value);
  }

  String? get model => config.model;

  set model(String? value) {
    config = config.copyWith(model: value);
  }
}

QueryEngine _buildRuntimeEngine(CommandContext context, AppConfig config) {
  final runtime = AppRuntime(
    provider: _resolveProvider(config),
    telemetry: context.engine.runtime.telemetry,
    securityGuard: context.engine.runtime.securityGuard,
    toolExecutor: context.engine.runtime.toolExecutor,
  );
  return QueryEngine(runtime);
}

_ReplUiMode? _parseReplUiMode(String raw) {
  switch (raw.trim()) {
    case 'plain':
      return _ReplUiMode.plain;
    case 'rich':
      return _ReplUiMode.rich;
    default:
      return null;
  }
}

Future<int> _runInteractiveRepl(
  CommandContext context, {
  required bool streamJson,
  required bool printIntro,
  required _ReplUiMode uiMode,
}) async {
  var lastCode = 0;
  final session = _ReplSessionState(
    config: context.config,
  );
  if (uiMode == _ReplUiMode.rich &&
      !streamJson &&
      stdin.hasTerminal &&
      stdout.hasTerminal) {
    return _runRichInteractiveRepl(
      context,
      session: session,
      printIntro: printIntro,
    );
  }
  if (printIntro) {
    print('Entering REPL. Type /help for commands, /exit to quit.');
  }
  final startupHint = buildProviderSetupHint(session.config);
  if (startupHint != null) {
    print('hint: $startupHint');
  }

  while (true) {
    final line = _readPlainInputWithContinuation();
    if (line == null) {
      if (stdin.hasTerminal) {
        print('');
      }
      break;
    }

    final input = line.trim();
    if (input.isEmpty) {
      continue;
    }
    if (_isExitCommand(input)) {
      break;
    }
    if (input.startsWith('/')) {
      if (_handleSlashCommand(input, context, session)) {
        continue;
      }
      print('Unknown command: $input (try /help)');
      continue;
    }

    final turnConfig = session.config;
    final turnEngine = _buildRuntimeEngine(context, turnConfig);
    final code = streamJson
        ? await _runReplTurnJson(turnEngine, input, model: session.model)
        : await _runReplTurnStreamText(turnEngine, input, model: session.model);
    if (code != 0) {
      lastCode = code;
    }
  }

  return lastCode;
}

enum _RichMessageRole { user, assistant, system, error }

class _RichMessage {
  const _RichMessage({
    required this.role,
    required this.text,
  });

  final _RichMessageRole role;
  final String text;
}

class _ReplStreamTurnResult {
  const _ReplStreamTurnResult({
    required this.success,
    required this.output,
    this.interrupted = false,
  });

  final bool success;
  final String output;
  final bool interrupted;
}

enum _RichInputEventType { submit, breakSignal, eof }

class _RichInputEvent {
  const _RichInputEvent._({
    required this.type,
    this.text,
    this.hadDraft = false,
  });

  factory _RichInputEvent.submit(String text) =>
      _RichInputEvent._(type: _RichInputEventType.submit, text: text);

  factory _RichInputEvent.breakSignal({required bool hadDraft}) =>
      _RichInputEvent._(
        type: _RichInputEventType.breakSignal,
        hadDraft: hadDraft,
      );

  factory _RichInputEvent.eof() =>
      const _RichInputEvent._(type: _RichInputEventType.eof);

  final _RichInputEventType type;
  final String? text;
  final bool hadDraft;
}

class RichComposerBuffer {
  RichComposerBuffer({String text = '', int? cursor})
      : _text = text,
        _cursor = (cursor ?? text.length).clamp(0, text.length);

  String _text;
  int _cursor;
  int? _preferredColumn;

  String get text => _text;

  int get cursor => _cursor;

  bool get isOnFirstLine => _lineStart(_cursor) == 0;

  bool get isOnLastLine => _lineEnd(_cursor) == _text.length;

  int get currentColumn => _cursor - _lineStart(_cursor);

  void setText(String value, {bool moveCursorToEnd = true}) {
    _text = value;
    if (moveCursorToEnd) {
      _cursor = _text.length;
    } else {
      _cursor = _cursor.clamp(0, _text.length);
    }
    _preferredColumn = null;
  }

  bool insert(String value) {
    if (value.isEmpty) {
      return false;
    }
    _text = _text.replaceRange(_cursor, _cursor, value);
    _cursor += value.length;
    _preferredColumn = null;
    return true;
  }

  bool backspace() {
    if (_cursor == 0) {
      return false;
    }
    _text = _text.replaceRange(_cursor - 1, _cursor, '');
    _cursor -= 1;
    _preferredColumn = null;
    return true;
  }

  bool deleteForward() {
    if (_cursor >= _text.length) {
      return false;
    }
    _text = _text.replaceRange(_cursor, _cursor + 1, '');
    _preferredColumn = null;
    return true;
  }

  bool deleteToLineStart() {
    final start = _lineStart(_cursor);
    if (start == _cursor) {
      return false;
    }
    _text = _text.replaceRange(start, _cursor, '');
    _cursor = start;
    _preferredColumn = null;
    return true;
  }

  bool deleteToLineEnd() {
    final end = _lineEnd(_cursor);
    if (end == _cursor) {
      return false;
    }
    _text = _text.replaceRange(_cursor, end, '');
    _preferredColumn = null;
    return true;
  }

  bool deleteWordBackward() {
    if (_cursor == 0) {
      return false;
    }
    var start = _cursor;
    while (start > 0 && _isWhitespaceCodeUnit(_text.codeUnitAt(start - 1))) {
      start -= 1;
    }
    while (start > 0 && !_isWhitespaceCodeUnit(_text.codeUnitAt(start - 1))) {
      start -= 1;
    }
    if (start == _cursor) {
      return false;
    }
    _text = _text.replaceRange(start, _cursor, '');
    _cursor = start;
    _preferredColumn = null;
    return true;
  }

  bool moveLeft() {
    if (_cursor == 0) {
      return false;
    }
    _cursor -= 1;
    _preferredColumn = null;
    return true;
  }

  bool moveRight() {
    if (_cursor >= _text.length) {
      return false;
    }
    _cursor += 1;
    _preferredColumn = null;
    return true;
  }

  bool moveLineStart() {
    final start = _lineStart(_cursor);
    if (_cursor == start) {
      return false;
    }
    _cursor = start;
    _preferredColumn = null;
    return true;
  }

  bool moveLineEnd() {
    final end = _lineEnd(_cursor);
    if (_cursor == end) {
      return false;
    }
    _cursor = end;
    _preferredColumn = null;
    return true;
  }

  bool moveUp() {
    final currentStart = _lineStart(_cursor);
    if (currentStart == 0) {
      return false;
    }
    final previousEnd = currentStart - 1;
    final previousStart = _lineStart(previousEnd);
    final previousLength = previousEnd - previousStart;
    final targetColumn = _preferredColumn ?? currentColumn;
    _cursor = previousStart + min(targetColumn, previousLength);
    _preferredColumn = targetColumn;
    return true;
  }

  bool moveDown() {
    final currentStart = _lineStart(_cursor);
    final currentEnd = _lineEnd(_cursor);
    if (currentEnd >= _text.length) {
      return false;
    }
    final nextStart = currentEnd + 1;
    final nextEnd = _lineEnd(nextStart);
    final nextLength = nextEnd - nextStart;
    final targetColumn = _preferredColumn ?? (_cursor - currentStart);
    _cursor = nextStart + min(targetColumn, nextLength);
    _preferredColumn = targetColumn;
    return true;
  }

  int _lineStart(int index) {
    var cursor = index.clamp(0, _text.length);
    while (cursor > 0 && _text.codeUnitAt(cursor - 1) != 0x0A) {
      cursor -= 1;
    }
    return cursor;
  }

  int _lineEnd(int index) {
    var cursor = index.clamp(0, _text.length);
    while (cursor < _text.length && _text.codeUnitAt(cursor) != 0x0A) {
      cursor += 1;
    }
    return cursor;
  }

  static bool _isWhitespaceCodeUnit(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

class RichComposerView {
  const RichComposerView({
    required this.visibleLines,
    required this.cursorRow,
    required this.cursorCol,
  });

  final List<String> visibleLines;
  final int cursorRow;
  final int cursorCol;
}

class RichInputUtf8Decoder {
  final List<int> _buffer = <int>[];

  String? pushChunk(String chunk) {
    _buffer.addAll(chunk.codeUnits);
    try {
      final decoded = utf8.decode(_buffer);
      _buffer.clear();
      return decoded;
    } catch (_) {
      return null;
    }
  }

  void reset() {
    _buffer.clear();
  }
}

Future<int> _runRichInteractiveRepl(
  CommandContext context, {
  required _ReplSessionState session,
  required bool printIntro,
}) async {
  final console = Console.scrolling(recordBlanks: false);
  if (console.windowWidth < 70 || console.windowHeight < 20) {
    return _runInteractiveRepl(
      context,
      streamJson: false,
      printIntro: printIntro,
      uiMode: _ReplUiMode.plain,
    );
  }
  final transcript = <_RichMessage>[];
  final inputHistory = <String>[];
  var status = buildProviderSetupHint(session.config) ??
      (printIntro ? 'Ready. Type /help for commands.' : 'Ready.');
  var lastCode = 0;
  DateTime? pendingExitHintAt;
  const exitHintWindow = Duration(seconds: 2);

  console.hideCursor();
  try {
    while (true) {
      var draftInput = '';
      var draftCursor = 0;
      _renderRichRepl(
        console,
        context,
        session,
        transcript,
        status: status,
        inputBuffer: draftInput,
        inputCursor: draftCursor,
      );

      final inputEvent = _readRichInput(
        console,
        history: inputHistory,
        onDraftChanged: (draft, cursor) {
          draftInput = draft;
          draftCursor = cursor;
          _renderRichRepl(
            console,
            context,
            session,
            transcript,
            status: status,
            inputBuffer: draftInput,
            inputCursor: draftCursor,
          );
        },
      );
      if (inputEvent.type == _RichInputEventType.eof) {
        status = 'Session ended.';
        break;
      }
      if (inputEvent.type == _RichInputEventType.breakSignal) {
        final now = DateTime.now();
        final previousHint = pendingExitHintAt;
        final withinWindow = previousHint != null &&
            now.difference(previousHint) <= exitHintWindow;
        if (withinWindow) {
          status = 'Exiting.';
          break;
        }
        pendingExitHintAt = now;
        status = inputEvent.hadDraft
            ? 'Input cleared. Press Ctrl+C again to exit.'
            : 'Press Ctrl+C again to exit.';
        continue;
      }
      pendingExitHintAt = null;
      final input = inputEvent.text ?? '';
      final trimmed = input.trim();
      if (trimmed.isEmpty) {
        status = 'Ready.';
        continue;
      }
      if (inputHistory.isEmpty || inputHistory.last != input) {
        inputHistory.add(input);
      }
      if (_isExitCommand(trimmed)) {
        status = 'Exiting.';
        break;
      }

      if (trimmed.startsWith('/')) {
        final handled = _handleSlashCommandRich(
          trimmed,
          context,
          session,
          transcript,
          onStatus: (value) => status = value,
        );
        if (!handled) {
          status = 'Unknown command: $trimmed';
          transcript.add(
            _RichMessage(
              role: _RichMessageRole.error,
              text: 'Unknown command: $trimmed',
            ),
          );
        }
        continue;
      }

      transcript.add(_RichMessage(role: _RichMessageRole.user, text: trimmed));
      transcript
          .add(const _RichMessage(role: _RichMessageRole.assistant, text: ''));
      status = 'Streaming response... (Ctrl+C to interrupt)';
      _renderRichRepl(
        console,
        context,
        session,
        transcript,
        status: status,
        inputBuffer: '',
        inputCursor: 0,
      );

      final assistantIndex = transcript.length - 1;
      final turnConfig = session.config;
      final turnEngine = _buildRuntimeEngine(context, turnConfig);
      final result = await _runReplTurnCollectStream(
        turnEngine,
        trimmed,
        model: session.model,
        allowInterrupt: true,
        onInterrupt: () {
          status = 'Interrupted.';
        },
        onDelta: (delta) {
          final current = transcript[assistantIndex].text;
          transcript[assistantIndex] = _RichMessage(
            role: _RichMessageRole.assistant,
            text: '$current$delta',
          );
          _renderRichRepl(
            console,
            context,
            session,
            transcript,
            status: 'Streaming response... (Ctrl+C to interrupt)',
            inputBuffer: '',
            inputCursor: 0,
          );
        },
      );

      if (result.success) {
        final output = result.output.isEmpty ? '[empty-output]' : result.output;
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.assistant,
          text: output,
        );
        status = 'Done.';
      } else if (result.interrupted) {
        final output = result.output.isEmpty ? '[interrupted]' : result.output;
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.assistant,
          text: output,
        );
        status = 'Interrupted.';
      } else {
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.error,
          text: result.output,
        );
        status = 'Provider error.';
        lastCode = 1;
      }
    }
  } finally {
    console.resetColorAttributes();
    console.showCursor();
    console.cursorPosition = Coordinate(console.windowHeight - 1, 0);
    console.writeLine();
  }

  return lastCode;
}

void _renderRichRepl(
  Console console,
  CommandContext context,
  _ReplSessionState session,
  List<_RichMessage> transcript, {
  required String status,
  required String inputBuffer,
  required int inputCursor,
}) {
  final width = min(console.windowWidth, 140);
  final inner = width - 2;
  final height = console.windowHeight;
  final composerInnerWidth = max(8, inner - 4);
  final composerView = buildRichComposerView(
    inputBuffer,
    inputCursor,
    composerInnerWidth,
    maxLines: 6,
  );

  final headerRows = 8;
  final footerRows = 4 + composerView.visibleLines.length;
  final transcriptStart = headerRows;
  final transcriptRows = max(3, height - headerRows - footerRows);

  final lines = _buildRichTranscriptLines(transcript, inner);
  final visible = lines.length > transcriptRows
      ? lines.sublist(lines.length - transcriptRows)
      : lines;

  console.clearScreen();
  console.cursorPosition = const Coordinate(0, 0);

  _writeRow(
    console,
    0,
    '╭${_fillTitle('─── Clart Code v0.3.0 ', inner)}╮',
  );
  _writeRow(
    console,
    1,
    '│${_fitRow(' Welcome back!  /help for commands', inner)}│',
  );
  _writeRow(
    console,
    2,
    '│${_fitRow(' Workspace: ${Directory.current.path}', inner)}│',
  );
  _writeRow(
    console,
    3,
    '│${_fitRow(' Provider: ${session.provider.name}   Model: ${session.model ?? 'default'}', inner)}│',
  );
  _writeRow(
    console,
    4,
    '│${_fitRow(' Stream mode: provider delta -> CLI', inner)}│',
  );
  _writeRow(console, 5, '│${_fitRow('', inner)}│');
  _writeRow(
    console,
    6,
    '╰${'─' * inner}╯',
  );
  _writeRow(console, 7, '─' * width);

  for (var i = 0; i < transcriptRows; i++) {
    final line = i < visible.length ? visible[i] : '';
    _writeRow(console, transcriptStart + i, _fitRow(line, width));
  }

  final statusRow = transcriptStart + transcriptRows;
  _writeRow(console, statusRow, '─' * width);
  _writeRow(
    console,
    statusRow + 1,
    _fitRow('status: $status', width),
  );
  _writeRow(
    console,
    statusRow + 2,
    '╭${_fillTitle('── Message (Enter=send, Ctrl+J=newline, Up/Down=cursor/history, Ctrl+P/N=history) ', inner)}╮',
  );
  for (var i = 0; i < composerView.visibleLines.length; i++) {
    final prefix = i == composerView.cursorRow ? ' > ' : '   ';
    _writeRow(
      console,
      statusRow + 3 + i,
      '│${_fitRow('$prefix${composerView.visibleLines[i]}', inner)}│',
    );
  }
  _writeRow(
    console,
    statusRow + 3 + composerView.visibleLines.length,
    '╰${'─' * inner}╯',
  );
  final cursorRow = statusRow + 3 + composerView.cursorRow;
  final cursorCol = min(width - 2, 4 + composerView.cursorCol);
  console.cursorPosition = Coordinate(cursorRow, cursorCol);
}

List<String> _buildRichTranscriptLines(
    List<_RichMessage> transcript, int width) {
  final lines = <String>[];
  for (final message in transcript) {
    final prefix = switch (message.role) {
      _RichMessageRole.user => 'user> ',
      _RichMessageRole.assistant => 'asst> ',
      _RichMessageRole.system => 'sys > ',
      _RichMessageRole.error => 'err > ',
    };
    final wrapped = _wrapText(message.text, max(8, width - prefix.length));
    if (wrapped.isEmpty) {
      lines.add(prefix);
      continue;
    }
    for (var i = 0; i < wrapped.length; i++) {
      lines.add(i == 0
          ? '$prefix${wrapped[i]}'
          : '${' ' * prefix.length}${wrapped[i]}');
    }
  }
  return lines;
}

_RichInputEvent _readRichInput(
  Console console, {
  required List<String> history,
  required void Function(String draft, int cursor) onDraftChanged,
}) {
  final draft = RichComposerBuffer();
  final utf8Decoder = RichInputUtf8Decoder();
  int? historyIndex;
  var historyStash = '';

  void applyHistoryValue(String value) {
    draft.setText(value);
    onDraftChanged(draft.text, draft.cursor);
  }

  void clearHistoryBrowse() {
    historyIndex = null;
    historyStash = '';
  }

  bool moveHistoryUp() {
    if (history.isEmpty) {
      return false;
    }
    if (historyIndex == null) {
      historyStash = draft.text;
      historyIndex = history.length - 1;
    } else if (historyIndex! > 0) {
      historyIndex = historyIndex! - 1;
    } else {
      return false;
    }
    applyHistoryValue(history[historyIndex!]);
    return true;
  }

  bool moveHistoryDown() {
    if (historyIndex == null) {
      return false;
    }
    if (historyIndex! < history.length - 1) {
      historyIndex = historyIndex! + 1;
      applyHistoryValue(history[historyIndex!]);
      return true;
    }
    historyIndex = null;
    applyHistoryValue(historyStash);
    historyStash = '';
    return true;
  }

  void onEditChange() {
    clearHistoryBrowse();
    onDraftChanged(draft.text, draft.cursor);
  }

  console.showCursor();
  try {
    while (true) {
      final key = console.readKey();
      if (key.isControl) {
        utf8Decoder.reset();
        switch (key.controlChar) {
          case ControlCharacter.enter:
            return _RichInputEvent.submit(draft.text);
          case ControlCharacter.ctrlJ:
            if (draft.insert('\n')) {
              onEditChange();
            }
            continue;
          case ControlCharacter.ctrlC:
            return _RichInputEvent.breakSignal(
              hadDraft: draft.text.trim().isNotEmpty,
            );
          case ControlCharacter.ctrlD:
            if (draft.text.isEmpty) {
              return _RichInputEvent.eof();
            }
            if (draft.deleteForward()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.backspace:
          case ControlCharacter.ctrlH:
            if (draft.backspace()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.delete:
            if (draft.deleteForward()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.ctrlU:
            if (draft.deleteToLineStart()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.ctrlK:
            if (draft.deleteToLineEnd()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.wordBackspace:
          case ControlCharacter.ctrlW:
            if (draft.deleteWordBackward()) {
              onEditChange();
            }
            continue;
          case ControlCharacter.arrowLeft:
          case ControlCharacter.ctrlB:
            if (draft.moveLeft()) {
              onDraftChanged(draft.text, draft.cursor);
            }
            continue;
          case ControlCharacter.arrowRight:
          case ControlCharacter.ctrlF:
            if (draft.moveRight()) {
              onDraftChanged(draft.text, draft.cursor);
            }
            continue;
          case ControlCharacter.home:
          case ControlCharacter.ctrlA:
            if (draft.moveLineStart()) {
              onDraftChanged(draft.text, draft.cursor);
            }
            continue;
          case ControlCharacter.end:
          case ControlCharacter.ctrlE:
            if (draft.moveLineEnd()) {
              onDraftChanged(draft.text, draft.cursor);
            }
            continue;
          case ControlCharacter.arrowUp:
            if (draft.moveUp()) {
              onDraftChanged(draft.text, draft.cursor);
            } else {
              moveHistoryUp();
            }
            continue;
          case ControlCharacter.arrowDown:
            if (draft.moveDown()) {
              onDraftChanged(draft.text, draft.cursor);
            } else {
              moveHistoryDown();
            }
            continue;
          case ControlCharacter.ctrlP:
            moveHistoryUp();
            continue;
          case ControlCharacter.ctrlN:
            moveHistoryDown();
            continue;
          case ControlCharacter.tab:
            if (draft.insert('\t')) {
              onEditChange();
            }
            continue;
          default:
            continue;
        }
      }
      final decoded = utf8Decoder.pushChunk(key.char);
      if (decoded == null) {
        continue;
      }
      if (draft.insert(decoded)) {
        onEditChange();
      }
    }
  } finally {
    console.hideCursor();
  }
}

bool _handleSlashCommandRich(
  String raw,
  CommandContext context,
  _ReplSessionState session,
  List<_RichMessage> transcript, {
  required void Function(String status) onStatus,
}) {
  final input = raw.trim();
  if (input == '/help') {
    transcript.add(
      const _RichMessage(
        role: _RichMessageRole.system,
        text:
            'Commands: /help /init /status /model [/model <name>] /provider [/provider <local|claude|openai>] /clear /exit; input: Enter send, Ctrl+J newline, Up/Down cursor/history, Ctrl+P/N history, Ctrl+C interrupt stream / double Ctrl+C exit',
      ),
    );
    onStatus('Displayed help.');
    return true;
  }
  if (input == '/init') {
    transcript.add(
      const _RichMessage(
        role: _RichMessageRole.system,
        text:
            'usage: /init <claude|openai> <apiKey> [baseUrl] [model]; also available: clart_code init',
      ),
    );
    onStatus('Displayed /init usage.');
    return true;
  }
  if (input.startsWith('/init ')) {
    final parsed = _parseInlineInitCommand(input);
    if (parsed.error != null) {
      onStatus(parsed.error!);
      return true;
    }
    final nextConfig = saveProviderSetup(
      current: session.config,
      provider: parsed.provider!,
      apiKey: parsed.apiKey!,
      baseUrl: parsed.baseUrl,
      model: parsed.model,
    );
    session.config = nextConfig;
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text:
            'configured ${parsed.provider!.name} -> ${nextConfig.configPath ?? defaultConfigPath(cwd: Directory.current.path)}',
      ),
    );
    if (parsed.model != null && parsed.model!.trim().isNotEmpty) {
      transcript.add(
        _RichMessage(
          role: _RichMessageRole.system,
          text: 'model switched to ${session.model}',
        ),
      );
    }
    final hint = buildProviderSetupHint(session.config);
    onStatus(hint ?? 'Initialized provider config.');
    return true;
  }
  if (input == '/clear') {
    transcript.clear();
    onStatus('Transcript cleared.');
    return true;
  }
  if (input == '/model') {
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text:
            'provider=${session.provider.name}, model=${session.model ?? 'default'}',
      ),
    );
    onStatus('Displayed model.');
    return true;
  }
  if (input.startsWith('/model ')) {
    final requested = input.substring('/model '.length).trim();
    if (requested.isEmpty) {
      onStatus('usage: /model <name>');
      return true;
    }
    session.model = requested;
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text: 'model switched to $requested',
      ),
    );
    onStatus('Model switched.');
    return true;
  }
  if (input == '/provider') {
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text: 'provider=${session.provider.name}',
      ),
    );
    onStatus('Displayed provider.');
    return true;
  }
  if (input.startsWith('/provider ')) {
    final requested = input.substring('/provider '.length).trim();
    final parsed = _parseProviderKind(requested);
    if (parsed == null) {
      onStatus('usage: /provider local|claude|openai');
      return true;
    }
    session.provider = parsed;
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text: 'provider switched to ${parsed.name}',
      ),
    );
    final hint = buildProviderSetupHint(session.config);
    onStatus(hint ?? 'Provider switched.');
    return true;
  }
  if (input == '/status') {
    final config = session.config;
    transcript.add(
      _RichMessage(
        role: _RichMessageRole.system,
        text:
            'provider=${config.provider.name} model=${config.model ?? 'default'}',
      ),
    );
    onStatus('Displayed status.');
    return true;
  }
  return false;
}

List<String> _wrapText(String input, int width) {
  if (input.isEmpty) {
    return const [];
  }
  if (width <= 0) {
    return [input];
  }
  final lines = <String>[];
  for (final paragraph in input.split('\n')) {
    if (paragraph.isEmpty) {
      lines.add('');
      continue;
    }
    lines.addAll(_wrapLine(paragraph, width));
  }
  return lines;
}

RichComposerView buildRichComposerView(
  String input,
  int cursor,
  int width, {
  int maxLines = 6,
}) {
  final effectiveWidth = max(1, width);
  final effectiveMaxLines = max(1, maxLines);
  final safeCursor = cursor.clamp(0, input.length);
  final wrappedLines = <String>[];

  final prefix = input.substring(0, safeCursor);
  final cursorLineIndex = '\n'.allMatches(prefix).length;
  final lineStart = prefix.lastIndexOf('\n');
  final cursorColumn =
      lineStart == -1 ? safeCursor : safeCursor - lineStart - 1;

  final logicalLines = input.isEmpty ? const [''] : input.split('\n');
  var wrappedCursorRow = 0;
  var wrappedCursorCol = 0;

  for (var i = 0; i < logicalLines.length; i++) {
    final line = logicalLines[i];
    final wrapped = _wrapLine(line, effectiveWidth);
    if (i == cursorLineIndex) {
      final safeLineCursor = cursorColumn.clamp(0, line.length);
      final cursorDisplayColumn =
          _displayWidth(line.substring(0, safeLineCursor));
      final cursorInLine =
          _cursorInWrappedLine(cursorDisplayColumn, effectiveWidth);
      wrappedCursorRow = wrappedLines.length + cursorInLine.row;
      wrappedCursorCol = cursorInLine.col;
    }
    wrappedLines.addAll(wrapped);
  }

  if (wrappedLines.isEmpty) {
    wrappedLines.add('');
  }

  var start = 0;
  if (wrappedLines.length > effectiveMaxLines) {
    start = max(0, wrappedCursorRow - effectiveMaxLines + 1);
    if (start + effectiveMaxLines > wrappedLines.length) {
      start = wrappedLines.length - effectiveMaxLines;
    }
  }
  final end = min(wrappedLines.length, start + effectiveMaxLines);
  final visible = wrappedLines.sublist(start, end);
  final visibleCursorRow = wrappedCursorRow - start;

  return RichComposerView(
    visibleLines: visible,
    cursorRow: visibleCursorRow,
    cursorCol: wrappedCursorCol,
  );
}

List<String> _wrapLine(String line, int width) {
  if (line.isEmpty) {
    return const [''];
  }
  if (width <= 0) {
    return [line];
  }
  final chunks = <String>[];
  var chunk = StringBuffer();
  var chunkWidth = 0;
  for (final rune in line.runes) {
    final char = String.fromCharCode(rune);
    final charWidth = _displayWidth(char);
    if (chunkWidth > 0 && chunkWidth + charWidth > width) {
      chunks.add(chunk.toString());
      chunk = StringBuffer();
      chunkWidth = 0;
    }
    chunk.write(char);
    chunkWidth += charWidth;
    if (chunkWidth >= width) {
      chunks.add(chunk.toString());
      chunk = StringBuffer();
      chunkWidth = 0;
    }
  }
  if (chunkWidth > 0 || chunks.isEmpty) {
    chunks.add(chunk.toString());
  }
  return chunks;
}

({int row, int col}) _cursorInWrappedLine(int column, int width) {
  if (column <= 0) {
    return (row: 0, col: 0);
  }
  if (column % width == 0) {
    return (row: (column ~/ width) - 1, col: width);
  }
  return (row: column ~/ width, col: column % width);
}

void _writeRow(Console console, int row, String text) {
  if (row < 0) {
    return;
  }
  console.cursorPosition = Coordinate(row, 0);
  console.write(text);
}

String _fitRow(String value, int width) {
  if (width <= 0) {
    return '';
  }
  final displayWidth = _displayWidth(value);
  if (displayWidth == width) {
    return value;
  }
  if (displayWidth < width) {
    return value + (' ' * (width - displayWidth));
  }
  if (width < 2) {
    return _takeDisplayWidth(value, width);
  }
  return '${_takeDisplayWidth(value, width - 1)}~';
}

String _fillTitle(String title, int width) {
  final titleWidth = _displayWidth(title);
  if (titleWidth >= width) {
    return _fitRow(title, width);
  }
  return title + ('─' * (width - titleWidth));
}

String _takeDisplayWidth(String value, int width) {
  if (width <= 0 || value.isEmpty) {
    return '';
  }
  final output = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final charWidth = _displayWidth(char);
    if (used + charWidth > width) {
      break;
    }
    output.write(char);
    used += charWidth;
  }
  return output.toString();
}

int _displayWidth(String value) {
  var width = 0;
  for (final rune in value.runes) {
    width += _runeDisplayWidth(rune);
  }
  return width;
}

int _runeDisplayWidth(int rune) {
  if (rune == 0) {
    return 0;
  }
  if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) {
    return 0;
  }
  if (_isCombiningRune(rune)) {
    return 0;
  }
  if (_isWideRune(rune)) {
    return 2;
  }
  return 1;
}

bool _isCombiningRune(int rune) {
  return (rune >= 0x0300 && rune <= 0x036F) ||
      (rune >= 0x1AB0 && rune <= 0x1AFF) ||
      (rune >= 0x1DC0 && rune <= 0x1DFF) ||
      (rune >= 0x20D0 && rune <= 0x20FF) ||
      (rune >= 0xFE20 && rune <= 0xFE2F);
}

bool _isWideRune(int rune) {
  return (rune >= 0x1100 && rune <= 0x115F) ||
      rune == 0x2329 ||
      rune == 0x232A ||
      (rune >= 0x2E80 && rune <= 0xA4CF) ||
      (rune >= 0xAC00 && rune <= 0xD7A3) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFE10 && rune <= 0xFE19) ||
      (rune >= 0xFE30 && rune <= 0xFE6F) ||
      (rune >= 0xFF00 && rune <= 0xFF60) ||
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x1F300 && rune <= 0x1FAFF) ||
      (rune >= 0x20000 && rune <= 0x2FFFD) ||
      (rune >= 0x30000 && rune <= 0x3FFFD);
}

bool _isExitCommand(String value) {
  final input = value.trim().toLowerCase();
  return input == '/exit' ||
      input == '/quit' ||
      input == 'exit' ||
      input == 'quit';
}

bool _handleSlashCommand(
  String raw,
  CommandContext context,
  _ReplSessionState session,
) {
  final input = raw.trim();
  if (input == '/help') {
    _printReplHelp();
    return true;
  }
  if (input == '/init') {
    print(
        'usage: /init <claude|openai> <apiKey> [baseUrl] [model]  (or run: clart_code init)');
    return true;
  }
  if (input.startsWith('/init ')) {
    final parsed = _parseInlineInitCommand(input);
    if (parsed.error != null) {
      print(parsed.error);
      return true;
    }
    final nextConfig = saveProviderSetup(
      current: session.config,
      provider: parsed.provider!,
      apiKey: parsed.apiKey!,
      baseUrl: parsed.baseUrl,
      model: parsed.model,
    );
    session.config = nextConfig;
    print(
        'configured ${parsed.provider!.name} -> ${nextConfig.configPath ?? defaultConfigPath(cwd: Directory.current.path)}');
    if (parsed.model != null && parsed.model!.trim().isNotEmpty) {
      print('model switched to ${session.model}');
    }
    final hint = buildProviderSetupHint(session.config);
    if (hint == null) {
      print('init complete.');
    } else {
      print('hint: $hint');
    }
    return true;
  }
  if (input == '/model') {
    print('provider=${session.provider.name}');
    print('model=${session.model ?? 'default'}');
    return true;
  }
  if (input.startsWith('/model ')) {
    final requested = input.substring('/model '.length).trim();
    if (requested.isEmpty) {
      print('usage: /model <name>');
      return true;
    }
    session.model = requested;
    print('model switched to $requested');
    return true;
  }
  if (input == '/provider') {
    print('provider=${session.provider.name}');
    _printProviderConfigSummary(session.config);
    final hint = buildProviderSetupHint(session.config);
    if (hint != null) {
      print('hint: $hint');
    }
    return true;
  }
  if (input.startsWith('/provider ')) {
    final requested = input.substring('/provider '.length).trim();
    final parsed = _parseProviderKind(requested);
    if (parsed == null) {
      print('usage: /provider local|claude|openai');
      return true;
    }
    session.provider = parsed;
    print('provider switched to ${parsed.name}');
    if (parsed != ProviderKind.local) {
      _printProviderConfigSummary(session.config);
    }
    final hint = buildProviderSetupHint(session.config);
    if (hint != null) {
      print('hint: $hint');
    }
    return true;
  }
  if (input == '/status') {
    print('provider=${session.provider.name}');
    print('model=${session.model ?? 'default'}');
    return true;
  }
  if (input == '/clear') {
    if (stdout.hasTerminal) {
      stdout.write('\x1B[2J\x1B[H');
    }
    return true;
  }
  return false;
}

String? _readPlainInputWithContinuation() {
  if (!stdin.hasTerminal) {
    return stdin.readLineSync();
  }
  final chunks = <String>[];
  var prompt = '> ';
  while (true) {
    stdout.write(prompt);
    final line = stdin.readLineSync();
    if (line == null) {
      return chunks.isEmpty ? null : chunks.join('\n');
    }
    if (line.endsWith(r'\')) {
      chunks.add(line.substring(0, line.length - 1));
      prompt = '... ';
      continue;
    }
    chunks.add(line);
    return chunks.join('\n');
  }
}

Future<_ReplStreamTurnResult> _runReplTurnCollectStream(
  QueryEngine engine,
  String prompt, {
  String? model,
  bool allowInterrupt = false,
  void Function()? onInterrupt,
  void Function(String delta)? onDelta,
}) async {
  final request = QueryRequest(
    messages: [ChatMessage(role: MessageRole.user, text: prompt)],
    maxTurns: 1,
    model: model,
  );

  final outputBuffer = StringBuffer();
  final completer = Completer<_ReplStreamTurnResult>();
  var completed = false;
  late final StreamSubscription<ProviderStreamEvent> streamSub;
  StreamSubscription<ProcessSignal>? sigintSub;

  void complete(_ReplStreamTurnResult value) {
    if (completed) {
      return;
    }
    completed = true;
    completer.complete(value);
  }

  streamSub = engine.runStream(request).listen(
    (event) {
      switch (event.type) {
        case ProviderStreamEventType.textDelta:
          final delta = event.delta ?? '';
          if (delta.isNotEmpty) {
            outputBuffer.write(delta);
            onDelta?.call(delta);
          }
          break;
        case ProviderStreamEventType.done:
          complete(
            _ReplStreamTurnResult(
              success: true,
              output: (event.output ?? outputBuffer.toString()),
            ),
          );
          break;
        case ProviderStreamEventType.error:
          final output = _renderProviderErrorOutput(event);
          complete(
            _ReplStreamTurnResult(
              success: false,
              output: output,
            ),
          );
          break;
      }
    },
    onError: (Object error) {
      complete(
        _ReplStreamTurnResult(
          success: false,
          output: '[ERROR] provider stream failed: $error',
        ),
      );
    },
    onDone: () {
      if (completed) {
        return;
      }
      final collected = outputBuffer.toString();
      if (collected.isNotEmpty) {
        complete(_ReplStreamTurnResult(success: true, output: collected));
      } else {
        complete(
          const _ReplStreamTurnResult(
            success: false,
            output: '[ERROR] provider stream ended unexpectedly',
          ),
        );
      }
    },
    cancelOnError: false,
  );

  if (allowInterrupt && stdin.hasTerminal) {
    try {
      sigintSub = ProcessSignal.sigint.watch().listen((_) {
        onInterrupt?.call();
        complete(
          _ReplStreamTurnResult(
            success: false,
            output: outputBuffer.toString(),
            interrupted: true,
          ),
        );
        unawaited(streamSub.cancel());
      });
    } catch (_) {
      // Keep stream path available if signal watching is unsupported.
    }
  }

  final result = await completer.future;
  await sigintSub?.cancel();
  await streamSub.cancel();
  return result;
}

String _renderProviderErrorOutput(ProviderStreamEvent event) {
  if (event.error?.source == 'provider_config') {
    return 'Provider is not configured. Run /init or clart_code init.';
  }
  if (event.output?.trim().isNotEmpty == true) {
    return event.output!;
  }
  return event.error?.message ?? '[ERROR] provider stream failed';
}

Future<int> _runReplTurnJson(
  QueryEngine engine,
  String prompt, {
  String? model,
}) async {
  final loop = QueryLoop(engine);
  final result = await loop.run(
    prompt: prompt,
    maxTurns: 1,
    streamJson: true,
    model: model,
  );
  return result.success ? 0 : 1;
}

Future<int> _runReplTurnStreamText(
  QueryEngine engine,
  String prompt, {
  String? model,
}) async {
  var printedAnyDelta = false;
  final result = await _runReplTurnCollectStream(
    engine,
    prompt,
    model: model,
    allowInterrupt: stdin.hasTerminal,
    onDelta: (delta) {
      printedAnyDelta = true;
      stdout.write(delta);
    },
  );
  if (result.success) {
    if (!printedAnyDelta && result.output.isNotEmpty) {
      stdout.write(result.output);
    }
    stdout.writeln('');
    return 0;
  }
  if (result.interrupted) {
    if (!printedAnyDelta && result.output.isNotEmpty) {
      stdout.write(result.output);
      stdout.writeln('');
    } else if (printedAnyDelta) {
      stdout.writeln('');
    }
    print('[interrupted] response cancelled');
    return 0;
  }
  if (printedAnyDelta) {
    stdout.writeln('');
  }
  print(result.output);
  return 1;
}

void _printReplHelp() {
  print('Available REPL commands:');
  print('/help     Show this help');
  print('/init     Configure real LLM provider/api key');
  print('/model    Show or switch current model');
  print('/provider Show or switch current provider');
  print('/status   Show current provider/model');
  print('/clear    Clear terminal screen');
  print('/exit     Exit REPL');
  print('');
  print('Input tips:');
  print('- Plain UI: end line with \\ then Enter for newline');
  print('- Rich UI: Ctrl+J inserts newline (true multiline composer)');
  print('- Rich UI: Ctrl+P / Ctrl+N browse input history');
  print('- Ctrl+C interrupts current streaming response');
  print('- At prompt, press Ctrl+C twice to exit');
}

Future<int> _runToolCommand(CommandContext context) async {
  var permissionMode = ToolPermissionMode.allow;
  var i = 0;

  while (i < context.args.length && context.args[i].startsWith('--')) {
    final token = context.args[i];
    if (token == '--permission') {
      if (i + 1 >= context.args.length) {
        print('error: --permission requires allow|deny');
        return 2;
      }
      final parsed = _parseToolPermissionMode(context.args[i + 1]);
      if (parsed == null) {
        print('error: --permission must be allow|deny');
        return 2;
      }
      permissionMode = parsed;
      i += 2;
      continue;
    }

    print('error: unknown option: $token');
    return 2;
  }

  if (i >= context.args.length) {
    print('error: missing tool name');
    return 2;
  }

  final toolName = context.args[i];
  final toolArgs = context.args.sublist(i + 1);
  final invocation = _buildToolInvocation(toolName, toolArgs);
  if (invocation == null) {
    return 2;
  }

  final executor = context.engine.runtime.toolExecutor.copyWith(
    permissionPolicy: ToolPermissionPolicy(mode: permissionMode),
  );
  final results = await executor.executeBatch([invocation]);
  final result = results.first;
  print(jsonEncode(result.toJson()));
  return result.ok ? 0 : 1;
}

ToolPermissionMode? _parseToolPermissionMode(String raw) {
  switch (raw.trim()) {
    case 'allow':
      return ToolPermissionMode.allow;
    case 'deny':
      return ToolPermissionMode.deny;
    default:
      return null;
  }
}

ToolInvocation? _buildToolInvocation(String toolName, List<String> args) {
  switch (toolName) {
    case 'read':
      if (args.length != 1) {
        print('error: read usage: tool read <path>');
        return null;
      }
      return ToolInvocation(name: toolName, input: {'path': args.first});
    case 'write':
      if (args.length < 2) {
        print('error: write usage: tool write <path> <content>');
        return null;
      }
      return ToolInvocation(
        name: toolName,
        input: {
          'path': args.first,
          'content': args.sublist(1).join(' '),
        },
      );
    case 'shell':
      if (args.isEmpty) {
        print('error: shell usage: tool shell <command>');
        return null;
      }
      return ToolInvocation(
        name: toolName,
        input: {'command': args.join(' ')},
      );
    default:
      print('error: unknown tool "$toolName"');
      return null;
  }
}

Map<String, Object?> _readConfigJsonFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return <String, Object?>{};
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return Map<String, Object?>.from(decoded);
    }
  } catch (_) {
    // Keep auth/status resilient if config file is malformed.
  }
  return <String, Object?>{};
}

AppConfig _mergeConfigMapIntoAppConfig(
    AppConfig current, Map<String, Object?> raw) {
  final parsedProvider = _parseProviderKind(raw['provider'] as String?);
  return current.copyWith(
    provider: parsedProvider ?? current.provider,
    model: raw['model'] as String? ?? current.model,
    claudeApiKey: raw['claudeApiKey'] as String? ?? current.claudeApiKey,
    claudeBaseUrl: raw['claudeBaseUrl'] as String? ?? current.claudeBaseUrl,
    openAiApiKey: raw['openAiApiKey'] as String? ?? current.openAiApiKey,
    openAiBaseUrl: raw['openAiBaseUrl'] as String? ?? current.openAiBaseUrl,
  );
}

void _printProviderConfigSummary(AppConfig config) {
  switch (config.provider) {
    case ProviderKind.local:
      print('auth=not required (local provider)');
      break;
    case ProviderKind.claude:
      print(
          'claude.baseUrl=${config.claudeBaseUrl ?? 'https://api.anthropic.com'}');
      print('claude.apiKey=${_maskSecret(config.claudeApiKey)}');
      break;
    case ProviderKind.openai:
      print(
          'openai.baseUrl=${config.openAiBaseUrl ?? 'https://api.openai.com/v1'}');
      print('openai.apiKey=${_maskSecret(config.openAiApiKey)}');
      break;
  }
}

String _maskSecret(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return '<missing>';
  }
  if (raw.length <= 6) {
    return '*' * raw.length;
  }
  final visibleSuffix = raw.substring(raw.length - 4);
  return '${'*' * (raw.length - 4)}$visibleSuffix';
}

class _InlineInitCommandParseResult {
  const _InlineInitCommandParseResult({
    this.provider,
    this.apiKey,
    this.baseUrl,
    this.model,
    this.error,
  });

  final ProviderKind? provider;
  final String? apiKey;
  final String? baseUrl;
  final String? model;
  final String? error;
}

_InlineInitCommandParseResult _parseInlineInitCommand(String input) {
  final tokens = input.trim().split(RegExp(r'\s+'));
  if (tokens.length < 3) {
    return const _InlineInitCommandParseResult(
      error:
          'usage: /init <claude|openai> <apiKey> [baseUrl] [model]  (example: /init openai sk-xxx)',
    );
  }
  final parsedProvider = _parseProviderKind(tokens[1]);
  if (parsedProvider == null || parsedProvider == ProviderKind.local) {
    return const _InlineInitCommandParseResult(
      error: 'provider must be claude|openai',
    );
  }
  final apiKey = tokens[2].trim();
  if (apiKey.isEmpty) {
    return const _InlineInitCommandParseResult(
      error: 'api key cannot be empty',
    );
  }
  final baseUrl = tokens.length >= 4 ? tokens[3].trim() : null;
  final model = tokens.length >= 5 ? tokens.sublist(4).join(' ').trim() : null;
  return _InlineInitCommandParseResult(
    provider: parsedProvider,
    apiKey: apiKey,
    baseUrl: baseUrl?.isEmpty == true ? null : baseUrl,
    model: model?.isEmpty == true ? null : model,
  );
}

AppConfig saveProviderSetup({
  required AppConfig current,
  required ProviderKind provider,
  required String apiKey,
  String? baseUrl,
  String? model,
  String? configPath,
}) {
  if (provider == ProviderKind.local) {
    throw ArgumentError.value(provider, 'provider', 'provider must be remote');
  }
  final trimmedKey = apiKey.trim();
  if (trimmedKey.isEmpty) {
    throw ArgumentError.value(apiKey, 'apiKey', 'api key cannot be empty');
  }
  final resolvedPath = configPath ??
      current.configPath ??
      defaultConfigPath(cwd: Directory.current.path);
  final existing = _readConfigJsonFile(resolvedPath);
  final next = Map<String, Object?>.from(existing);

  next['provider'] = provider.name;
  if (model != null && model.trim().isNotEmpty) {
    next['model'] = model.trim();
  }
  if (provider == ProviderKind.claude) {
    next['claudeApiKey'] = trimmedKey;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      next['claudeBaseUrl'] = baseUrl.trim();
    }
  } else {
    next['openAiApiKey'] = trimmedKey;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      next['openAiBaseUrl'] = baseUrl.trim();
    }
  }

  final file = File(resolvedPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(next),
  );

  return _mergeConfigMapIntoAppConfig(
    current.copyWith(configPath: resolvedPath),
    next,
  ).copyWith(configPath: resolvedPath);
}

String? buildProviderSetupHint(AppConfig config) {
  switch (config.provider) {
    case ProviderKind.local:
      return 'Not configured for real LLM. Run /init or clart_code init.';
    case ProviderKind.claude:
      if (config.claudeApiKey?.trim().isEmpty ?? true) {
        return 'Claude is not configured (missing API key). Run /init or clart_code init.';
      }
      return null;
    case ProviderKind.openai:
      if (config.openAiApiKey?.trim().isEmpty ?? true) {
        return 'OpenAI is not configured (missing API key). Run /init or clart_code init.';
      }
      return null;
  }
}

ProviderKind? _parseProviderKind(String? value) {
  switch (value?.trim()) {
    case 'local':
      return ProviderKind.local;
    case 'claude':
      return ProviderKind.claude;
    case 'openai':
      return ProviderKind.openai;
    default:
      return null;
  }
}

LlmProvider _resolveProvider(AppConfig config) {
  switch (config.provider) {
    case ProviderKind.local:
      return LocalEchoProvider();
    case ProviderKind.claude:
      return ClaudeApiProvider(
        apiKey: config.claudeApiKey ?? '',
        baseUrl: config.claudeBaseUrl,
        model: config.model,
      );
    case ProviderKind.openai:
      return OpenAiApiProvider(
        apiKey: config.openAiApiKey ?? '',
        baseUrl: config.openAiBaseUrl,
        model: config.model,
      );
  }
}

ParsedCli _parseCli(List<String> args) {
  if (args.isEmpty) {
    return const ParsedCli(command: 'start', commandArgs: []);
  }

  String? provider;
  String? model;
  String? configPath;
  String? claudeApiKey;
  String? claudeBaseUrl;
  String? openAiApiKey;
  String? openAiBaseUrl;
  String? command;
  final commandArgs = <String>[];

  var i = 0;
  while (i < args.length) {
    final token = args[i];

    if (command != null) {
      commandArgs.add(token);
      i += 1;
      continue;
    }

    if (token == '--provider') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--provider requires a value',
        );
      }
      provider = args[i + 1];
      i += 2;
      continue;
    }

    if (token == '--model') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--model requires a value',
        );
      }
      model = args[i + 1];
      i += 2;
      continue;
    }

    if (token == '--config') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--config requires a value',
        );
      }
      configPath = args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--claude-api-key') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--claude-api-key requires a value',
        );
      }
      claudeApiKey = args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--claude-base-url') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--claude-base-url requires a value',
        );
      }
      claudeBaseUrl = args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--openai-api-key') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--openai-api-key requires a value',
        );
      }
      openAiApiKey = args[i + 1];
      i += 2;
      continue;
    }
    if (token == '--openai-base-url') {
      if (i + 1 >= args.length) {
        return const ParsedCli(
          command: 'help',
          commandArgs: [],
          error: '--openai-base-url requires a value',
        );
      }
      openAiBaseUrl = args[i + 1];
      i += 2;
      continue;
    }

    if (token.startsWith('--')) {
      return ParsedCli(
        command: 'help',
        commandArgs: const [],
        error: 'unknown option: $token',
      );
    }

    command = token;
    i += 1;
  }

  return ParsedCli(
    command: command ?? 'help',
    commandArgs: commandArgs,
    provider: provider,
    model: model,
    configPath: configPath,
    claudeApiKey: claudeApiKey,
    claudeBaseUrl: claudeBaseUrl,
    openAiApiKey: openAiApiKey,
    openAiBaseUrl: openAiBaseUrl,
  );
}

void _printHelp() {
  print('''
  clart_code - runnable migration baseline

Usage:
  clart_code [global options] <command>

Commands:
  help                 Show help
  version              Show version
  start [opts]         Trust gate + welcome + REPL
  status               Show current runtime config
  features             Show implemented migration features
  init [opts]          Initialize provider config (provider/key/host/model)
  chat <prompt>        One-shot prompt
  print <prompt>       Alias of chat
  loop [opts] <prompt> Multi-turn loop
  auth [opts]          Save provider auth config (provider + key + host)
  tool [opts] ...      Run minimal tool executor
  repl [opts]          Interactive mode

Global options:
  --config PATH            Config file path (default: ./.clart/config.json if exists)
  --provider NAME          local|claude|openai
  --model NAME             Model name override
  --claude-api-key KEY     Override Claude API key for this run
  --claude-base-url URL    Override Claude base URL for this run
  --openai-api-key KEY     Override OpenAI API key for this run
  --openai-base-url URL    Override OpenAI base URL for this run

Loop opts:
  --max-turns N        Number of turns (default 1)
  --stream-json        Print event stream as json lines

Repl opts:
  --stream-json        Print turn events as json lines
  --ui MODE            plain|rich (default plain)

Auth opts:
  --provider NAME      claude|openai (required unless current provider is set)
  --api-key KEY        Provider API key
  --base-url URL       Provider host/base URL
  --config PATH        Output config path (default: ./.clart/config.json)
  --show               Show current auth summary only

Init opts:
  --provider NAME      claude|openai (prompted if missing in terminal)
  --api-key KEY        Provider API key (prompted if missing in terminal)
  --base-url URL       Provider host/base URL (optional)
  --model NAME         Model name (optional)
  --config PATH        Output config path (default: ./.clart/config.json)

Tool opts:
  --permission MODE    allow|deny (default allow)

Tool usage:
  tool read <path>
  tool write <path> <content>
  tool shell <command...>

Start opts:
  --yes                Trust current folder and proceed
  --no                 Exit immediately
  --no-repl            Render welcome only, skip REPL
  --ui MODE            plain|rich (default plain)
  --trust-file PATH    Override trust storage path (for tests/CI)

Notes:
  - Telemetry/reporting is intentionally no-op.
  - Claude/OpenAI providers are wired in minimal migration mode.
  - Missing capabilities are kept as placeholders to preserve runnability.
''');
}
