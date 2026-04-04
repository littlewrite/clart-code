import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_console/dart_console.dart';

import '../core/app_config.dart';
import '../core/conversation_session.dart';
import '../core/models.dart';
import '../core/process_user_input.dart';
import '../core/prompt_submitter.dart';
import '../core/query_engine.dart';
import '../core/query_events.dart';
import '../core/query_loop.dart';
import '../core/transcript.dart';
import '../core/turn_executor.dart';
import '../providers/llm_provider.dart';
import '../runtime/app_runtime.dart';
import '../services/security_guard.dart';
import '../services/telemetry.dart';
import '../tools/tool_models.dart';
import '../tools/tool_permissions.dart';
import '../ui/startup_experience.dart';
import 'command_registry.dart';
import 'git_workspace.dart';
import 'local_reports.dart';
import 'provider_setup.dart';
import 'repl_command_dispatcher.dart';
import 'workspace_store.dart';

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
      name: 'doctor',
      description: 'Show workspace/config diagnostics',
      handler: _runDoctorCommand,
    ),
    RegisteredCommand(
      name: 'diff',
      description: 'Show current git workspace diff summary',
      handler: _runDiffCommand,
    ),
    RegisteredCommand(
      name: 'review',
      description: 'Run minimal code review against current git diff',
      handler: _runReviewCommand,
    ),
    RegisteredCommand(
      name: 'memory',
      description: 'Manage simple workspace memory file',
      handler: _runMemoryCommand,
    ),
    RegisteredCommand(
      name: 'tasks',
      description: 'Manage simple local task list',
      handler: _runTasksCommand,
    ),
    RegisteredCommand(
      name: 'permissions',
      description: 'Show/set default tool permission mode',
      handler: _runPermissionsCommand,
    ),
    RegisteredCommand(
      name: 'export',
      description: 'Export workspace snapshot as JSON',
      handler: _runExportCommand,
    ),
    RegisteredCommand(
      name: 'session',
      description: 'Inspect local session snapshots',
      handler: _runSessionCommand,
    ),
    RegisteredCommand(
      name: 'resume',
      description: 'Resume a saved local session with a new prompt',
      handler: _runResumeCommand,
    ),
    RegisteredCommand(
      name: 'share',
      description: 'Export a saved session as JSON or Markdown',
      handler: _runShareCommand,
    ),
    RegisteredCommand(
      name: 'mcp',
      description: 'Manage simple local MCP server registry',
      handler: _runMcpCommand,
    ),
    RegisteredCommand(
      name: 'status',
      description: 'Show runtime status/config snapshot',
      handler: (ctx) async {
        print('provider=${ctx.config.provider.name}');
        print('model=${ctx.config.model ?? '-'}');
        print('config=${ctx.config.configPath ?? '-'}');
        printProviderConfigSummary(ctx.config);
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
        print('- centralized prompt/slash input processing');
        print('- provider-level stream-json turn execution');
        print('- tool abstraction + serial scheduler');
        print('- built-in tools: read/write/shell-stub');
        print('- tool permission policy (allow|deny)');
        print('- persisted default tool permission mode');
        print('- workspace memory/tasks/export/doctor commands');
        print('- git workspace state summary + diff command');
        print('- minimal review command against current git diff');
        print('- local session/resume/share snapshots');
        print('- simple local MCP registry command');
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
  var uiMode = _ReplUiMode.rich;

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

  final selectedProvider = parseProviderKind(providerRaw);
  if (providerRaw != null && selectedProvider == null) {
    print('error: --provider must be local|claude|openai');
    return 2;
  }
  final providerKind = selectedProvider ?? context.config.provider;
  final resolvedPath = configPath ??
      context.config.configPath ??
      defaultConfigPath(cwd: Directory.current.path);

  final existing = readConfigJsonFile(resolvedPath);
  if (showOnly) {
    final merged = mergeConfigMapIntoAppConfig(context.config, existing);
    print('config=$resolvedPath');
    print('provider=${merged.provider.name}');
    printProviderConfigSummary(merged);
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
  print('apiKey=${maskSecret(effectiveApiKey)}');
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
  final existingRaw = readConfigJsonFile(resolvedPath);
  final existing = mergeConfigMapIntoAppConfig(
    context.config.copyWith(configPath: resolvedPath),
    existingRaw,
  );

  ProviderKind? providerKind;
  if (providerRaw != null) {
    providerKind = parseProviderKind(providerRaw);
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
    providerKind = parseProviderKind(selected);
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
  printProviderConfigSummary(nextConfig);
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
  final initialSubmission = PromptSubmitter().submit(
    prompt,
    model: context.config.model,
  );
  final processedInput = const UserInputProcessor().process(initialSubmission);
  if (!processedInput.isQuery) {
    print('error: loop only accepts plain prompt text');
    return 2;
  }

  final loop = QueryLoop(context.engine);
  final result = await loop.run(
    prompt: processedInput.submission.raw,
    maxTurns: maxTurns,
    streamJson: streamJson,
    model: context.config.model,
    continuationPromptBuilder: _autoContinuePromptBuilder,
  );
  writeWorkspaceSession(
    buildWorkspaceSessionSnapshot(
      id: createWorkspaceSessionId(),
      provider: context.config.provider.name,
      model: context.config.model,
      history: result.history,
      transcript: result.transcript,
    ),
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
  var uiMode = _ReplUiMode.rich;
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

String? _autoContinuePromptBuilder(
  QueryResponse response,
  int completedTurn,
  List<ChatMessage> transcript,
) {
  if (!response.isOk) {
    return null;
  }
  return 'continue';
}

class _ReplSessionState implements ReplCommandSession {
  _ReplSessionState({
    required this.config,
    String? sessionId,
    ConversationSession? conversation,
  })  : sessionId = sessionId ?? createWorkspaceSessionId(),
        conversation = conversation ?? ConversationSession() {
    submitter = PromptSubmitter(conversation: this.conversation);
  }

  @override
  AppConfig config;
  final String sessionId;
  final ConversationSession conversation;
  late final PromptSubmitter submitter;

  ProviderKind get provider => config.provider;

  set provider(ProviderKind value) {
    config = config.copyWith(provider: value);
  }

  String? get model => config.model;

  set model(String? value) {
    config = config.copyWith(model: value);
  }

  @override
  void clearConversation() {
    conversation.clear();
  }
}

void _persistConversationSnapshot({
  required String sessionId,
  required AppConfig config,
  required ConversationSession conversation,
}) {
  final existing = readWorkspaceSession(sessionId);
  writeWorkspaceSession(
    buildWorkspaceSessionSnapshot(
      id: sessionId,
      provider: config.provider.name,
      model: config.model,
      history: conversation.history,
      transcript: conversation.transcript,
      createdAt: existing?.createdAt,
    ),
  );
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

ProcessUserInputResult _processReplInput(
  _ReplSessionState session,
  String rawInput,
) {
  final submission = session.submitter.submit(
    rawInput,
    model: session.model,
  );
  return const UserInputProcessor().process(
    submission,
    onSlashCommand: (pending) => executeReplSlashCommand(pending.raw, session),
  );
}

void _renderPlainTranscriptMessages(List<TranscriptMessage> messages) {
  for (final message in messages) {
    print(message.text);
  }
}

_RichMessageRole _mapTranscriptMessageRole(TranscriptMessageKind kind) {
  switch (kind) {
    case TranscriptMessageKind.userPrompt:
      return _RichMessageRole.user;
    case TranscriptMessageKind.assistant:
      return _RichMessageRole.assistant;
    case TranscriptMessageKind.localCommand:
    case TranscriptMessageKind.localCommandStdout:
    case TranscriptMessageKind.toolResult:
    case TranscriptMessageKind.system:
      return _RichMessageRole.system;
    case TranscriptMessageKind.localCommandStderr:
      return _RichMessageRole.error;
  }
}

void _appendRichTranscriptMessages(
  List<_RichMessage> transcript,
  List<TranscriptMessage> messages,
) {
  for (final message in messages) {
    transcript.add(
      _RichMessage(
        role: _mapTranscriptMessageRole(message.kind),
        text: message.text,
      ),
    );
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

    final processed = _processReplInput(session, line);
    switch (processed.kind) {
      case ProcessUserInputKind.ignore:
        continue;
      case ProcessUserInputKind.exit:
        return lastCode;
      case ProcessUserInputKind.localCommand:
        final localResult = processed.localCommandResult!;
        if (localResult.clearScreen && stdout.hasTerminal) {
          stdout.write('\x1B[2J\x1B[H');
        }
        session.conversation.appendTranscriptMessages(
          processed.transcriptMessages,
        );
        _persistConversationSnapshot(
          sessionId: session.sessionId,
          config: session.config,
          conversation: session.conversation,
        );
        _renderPlainTranscriptMessages(processed.transcriptMessages);
        continue;
      case ProcessUserInputKind.invalid:
        session.conversation.appendTranscriptMessages(
          processed.transcriptMessages,
        );
        _persistConversationSnapshot(
          sessionId: session.sessionId,
          config: session.config,
          conversation: session.conversation,
        );
        print('${processed.errorText} (try /help)');
        continue;
      case ProcessUserInputKind.query:
        break;
    }

    final turnConfig = session.config;
    final turnEngine = _buildRuntimeEngine(context, turnConfig);
    final result = streamJson
        ? await _runReplTurnJson(
            turnEngine,
            processed.request!,
          )
        : await _runReplTurnStreamText(
            turnEngine,
            processed.request!,
          );
    if (result.success || result.interrupted) {
      session.conversation.appendTranscriptMessages([
        ...processed.transcriptMessages,
        ...result.transcriptMessages,
      ]);
      session.conversation.recordHistoryTurn(
        prompt: processed.submission.raw,
        output: result.displayOutput,
      );
    } else {
      session.conversation.appendTranscriptMessages([
        ...processed.transcriptMessages,
        ...result.transcriptMessages,
      ]);
    }
    _persistConversationSnapshot(
      sessionId: session.sessionId,
      config: session.config,
      conversation: session.conversation,
    );
    if (!result.success && !result.interrupted) {
      lastCode = 1;
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

String _maskRichSecretInputForDisplay(String raw) {
  final buffer = StringBuffer();
  for (final codeUnit in raw.codeUnits) {
    if (codeUnit == 0x0A || codeUnit == 0x0D) {
      buffer.writeCharCode(codeUnit);
    } else {
      buffer.write('*');
    }
  }
  return buffer.toString();
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

enum RichInputTokenKind { eof, text, control, paste }

class RichInputToken {
  const RichInputToken._({
    required this.kind,
    this.text,
    this.controlChar,
  });

  const RichInputToken.text(String value)
      : this._(kind: RichInputTokenKind.text, text: value);

  const RichInputToken.paste(String value)
      : this._(kind: RichInputTokenKind.paste, text: value);

  const RichInputToken.control(ControlCharacter value)
      : this._(kind: RichInputTokenKind.control, controlChar: value);

  const RichInputToken.eof() : this._(kind: RichInputTokenKind.eof);

  final RichInputTokenKind kind;
  final String? text;
  final ControlCharacter? controlChar;
}

RichInputToken parseRichInputBytesForTest(List<int> bytes) {
  var index = 0;
  return _readRichInputToken(() {
    if (index >= bytes.length) {
      return -1;
    }
    return bytes[index++];
  });
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
  var fallbackToPlain = false;
  DateTime? pendingExitHintAt;
  const exitHintWindow = Duration(seconds: 2);

  console.hideCursor();
  try {
    while (true) {
      final inputWaitStartedAt = DateTime.now();
      final inputEvent = _promptRichInput(
        console,
        context,
        session,
        transcript,
        status: status,
        history: inputHistory,
      );
      final elapsedSincePrompt = DateTime.now().difference(inputWaitStartedAt);
      if (shouldFallbackToPlainReplOnImmediateEof(
        richInputReturnedEof: inputEvent.type == _RichInputEventType.eof,
        hasTranscript: transcript.isNotEmpty,
        hasInputHistory: inputHistory.isNotEmpty,
        elapsedSincePrompt: elapsedSincePrompt,
      )) {
        fallbackToPlain = true;
        break;
      }
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
      final rawInput = inputEvent.text ?? '';
      if (rawInput.trim() == '/init') {
        if (inputHistory.isEmpty || inputHistory.last != rawInput) {
          inputHistory.add(rawInput);
        }
        status = _runRichInitWizard(
          console,
          context,
          session,
          transcript,
        );
        continue;
      }
      final processed = _processReplInput(session, rawInput);
      if (processed.kind == ProcessUserInputKind.ignore) {
        status = 'Ready.';
        continue;
      }
      if (inputHistory.isEmpty || inputHistory.last != rawInput) {
        inputHistory.add(rawInput);
      }
      if (processed.kind == ProcessUserInputKind.exit) {
        status = 'Exiting.';
        break;
      }

      if (processed.kind == ProcessUserInputKind.invalid) {
        status = processed.status ?? 'Invalid input.';
        session.conversation.appendTranscriptMessages(
          processed.transcriptMessages,
        );
        _persistConversationSnapshot(
          sessionId: session.sessionId,
          config: session.config,
          conversation: session.conversation,
        );
        transcript.add(
          _RichMessage(
            role: _RichMessageRole.error,
            text: processed.errorText ?? 'Invalid input.',
          ),
        );
        continue;
      }

      if (processed.kind == ProcessUserInputKind.localCommand) {
        final localResult = processed.localCommandResult!;
        if (localResult.clearTranscript) {
          transcript.clear();
        }
        session.conversation.appendTranscriptMessages(
          processed.transcriptMessages,
        );
        _persistConversationSnapshot(
          sessionId: session.sessionId,
          config: session.config,
          conversation: session.conversation,
        );
        _appendRichTranscriptMessages(
          transcript,
          processed.transcriptMessages,
        );
        status = processed.status ?? 'Done.';
        continue;
      }

      final request = processed.request!;
      final prompt = processed.submission.raw;
      _appendRichTranscriptMessages(
        transcript,
        processed.transcriptMessages,
      );
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
        request,
        allowInterrupt: true,
        onInterrupt: () {
          status = 'Interrupted.';
        },
        onDelta: (delta, _) {
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
        session.conversation.appendTranscriptMessages([
          ...processed.transcriptMessages,
          ...result.transcriptMessages,
        ]);
        session.conversation.recordHistoryTurn(
          prompt: prompt,
          output: result.displayOutput,
        );
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.assistant,
          text: result.displayOutput,
        );
        status = 'Done.';
      } else if (result.interrupted) {
        session.conversation.appendTranscriptMessages([
          ...processed.transcriptMessages,
          ...result.transcriptMessages,
        ]);
        session.conversation.recordHistoryTurn(
          prompt: prompt,
          output: result.displayOutput,
        );
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.assistant,
          text: result.displayOutput,
        );
        status = 'Interrupted.';
      } else {
        session.conversation.appendTranscriptMessages([
          ...processed.transcriptMessages,
          ...result.transcriptMessages,
        ]);
        transcript[assistantIndex] = _RichMessage(
          role: _RichMessageRole.error,
          text: result.output,
        );
        status = 'Provider error.';
        lastCode = 1;
      }
      _persistConversationSnapshot(
        sessionId: session.sessionId,
        config: session.config,
        conversation: session.conversation,
      );
    }
  } finally {
    console.resetColorAttributes();
    console.showCursor();
    console.cursorPosition = Coordinate(console.windowHeight - 1, 0);
    console.writeLine();
  }

  if (fallbackToPlain) {
    print(
        'Rich input is unavailable in this terminal. Falling back to plain REPL.');
    return _runInteractiveRepl(
      context,
      streamJson: false,
      printIntro: printIntro,
      uiMode: _ReplUiMode.plain,
    );
  }

  return lastCode;
}

bool shouldFallbackToPlainReplOnImmediateEof({
  required bool richInputReturnedEof,
  required bool hasTranscript,
  required bool hasInputHistory,
  required Duration elapsedSincePrompt,
  Duration threshold = const Duration(milliseconds: 250),
}) {
  return richInputReturnedEof &&
      !hasTranscript &&
      !hasInputHistory &&
      elapsedSincePrompt <= threshold;
}

String _providerApiKey(AppConfig config, ProviderKind provider) {
  switch (provider) {
    case ProviderKind.local:
      return '';
    case ProviderKind.claude:
      return config.claudeApiKey?.trim() ?? '';
    case ProviderKind.openai:
      return config.openAiApiKey?.trim() ?? '';
  }
}

String? _providerBaseUrl(AppConfig config, ProviderKind provider) {
  switch (provider) {
    case ProviderKind.local:
      return null;
    case ProviderKind.claude:
      return config.claudeBaseUrl?.trim();
    case ProviderKind.openai:
      return config.openAiBaseUrl?.trim();
  }
}

_RichInputEvent _promptRichInput(
  Console console,
  CommandContext context,
  _ReplSessionState session,
  List<_RichMessage> transcript, {
  required String status,
  List<String> history = const [],
  bool maskInput = false,
}) {
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

  return _readRichInput(
    console,
    history: history,
    displayTransform: maskInput ? _maskRichSecretInputForDisplay : null,
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
}

String _runRichInitWizard(
  Console console,
  CommandContext context,
  _ReplSessionState session,
  List<_RichMessage> transcript,
) {
  ProviderKind? selectedProvider;
  while (selectedProvider == null) {
    final remoteDefault = session.config.provider == ProviderKind.local
        ? null
        : session.config.provider;
    final event = _promptRichInput(
      console,
      context,
      session,
      transcript,
      status: remoteDefault == null
          ? 'Init 1/4: provider (claude/openai). Ctrl+C cancels.'
          : 'Init 1/4: provider (claude/openai). Enter keeps ${remoteDefault.name}. Ctrl+C cancels.',
    );
    if (event.type == _RichInputEventType.breakSignal ||
        event.type == _RichInputEventType.eof) {
      final messages = const [
        TranscriptMessage.localCommand('/init'),
        TranscriptMessage.localCommandStderr('init cancelled.'),
      ];
      session.conversation.appendTranscriptMessages(messages);
      _persistConversationSnapshot(
        sessionId: session.sessionId,
        config: session.config,
        conversation: session.conversation,
      );
      _appendRichTranscriptMessages(transcript, messages);
      return 'Init cancelled.';
    }
    final raw = event.text?.trim() ?? '';
    if (raw.isEmpty && remoteDefault != null) {
      selectedProvider = remoteDefault;
      break;
    }
    final parsed = parseProviderKind(raw);
    if (parsed != null && parsed != ProviderKind.local) {
      selectedProvider = parsed;
      break;
    }
  }
  final provider = selectedProvider;

  final currentApiKey = _providerApiKey(session.config, provider);
  String? apiKey;
  while (apiKey == null) {
    final event = _promptRichInput(
      console,
      context,
      session,
      transcript,
      status: currentApiKey.isEmpty
          ? 'Init 2/4: API key for ${provider.name}. Input is masked. Ctrl+C cancels.'
          : 'Init 2/4: API key for ${provider.name}. Enter keeps current key. Input is masked. Ctrl+C cancels.',
      maskInput: true,
    );
    if (event.type == _RichInputEventType.breakSignal ||
        event.type == _RichInputEventType.eof) {
      final messages = const [
        TranscriptMessage.localCommand('/init'),
        TranscriptMessage.localCommandStderr('init cancelled.'),
      ];
      session.conversation.appendTranscriptMessages(messages);
      _persistConversationSnapshot(
        sessionId: session.sessionId,
        config: session.config,
        conversation: session.conversation,
      );
      _appendRichTranscriptMessages(transcript, messages);
      return 'Init cancelled.';
    }
    final raw = event.text?.trim() ?? '';
    if (raw.isEmpty && currentApiKey.isNotEmpty) {
      apiKey = currentApiKey;
      break;
    }
    if (raw.isNotEmpty) {
      apiKey = raw;
    }
  }
  final effectiveApiKey = apiKey;

  final currentBaseUrl = _providerBaseUrl(session.config, provider);
  final baseUrlEvent = _promptRichInput(
    console,
    context,
    session,
    transcript,
    status: currentBaseUrl?.isNotEmpty == true
        ? 'Init 3/4: base URL (optional). Enter keeps current: $currentBaseUrl'
        : 'Init 3/4: base URL (optional). Enter leaves default.',
  );
  if (baseUrlEvent.type == _RichInputEventType.breakSignal ||
      baseUrlEvent.type == _RichInputEventType.eof) {
    final messages = const [
      TranscriptMessage.localCommand('/init'),
      TranscriptMessage.localCommandStderr('init cancelled.'),
    ];
    session.conversation.appendTranscriptMessages(messages);
    _persistConversationSnapshot(
      sessionId: session.sessionId,
      config: session.config,
      conversation: session.conversation,
    );
    _appendRichTranscriptMessages(transcript, messages);
    return 'Init cancelled.';
  }
  final enteredBaseUrl = baseUrlEvent.text?.trim() ?? '';
  final baseUrl = enteredBaseUrl.isEmpty ? currentBaseUrl : enteredBaseUrl;

  final currentModel = session.config.model?.trim();
  final modelEvent = _promptRichInput(
    console,
    context,
    session,
    transcript,
    status: currentModel?.isNotEmpty == true
        ? 'Init 4/4: model (optional). Enter keeps current: $currentModel'
        : 'Init 4/4: model (optional). Enter leaves provider default.',
  );
  if (modelEvent.type == _RichInputEventType.breakSignal ||
      modelEvent.type == _RichInputEventType.eof) {
    final messages = const [
      TranscriptMessage.localCommand('/init'),
      TranscriptMessage.localCommandStderr('init cancelled.'),
    ];
    session.conversation.appendTranscriptMessages(messages);
    _persistConversationSnapshot(
      sessionId: session.sessionId,
      config: session.config,
      conversation: session.conversation,
    );
    _appendRichTranscriptMessages(transcript, messages);
    return 'Init cancelled.';
  }
  final enteredModel = modelEvent.text?.trim() ?? '';
  final model = enteredModel.isEmpty ? currentModel : enteredModel;

  final applied = applyProviderSetup(
    current: session.config,
    provider: provider,
    apiKey: effectiveApiKey,
    baseUrl: baseUrl?.isEmpty == true ? null : baseUrl,
    model: model?.isEmpty == true ? null : model,
  );
  session.config = applied.config;
  final messages = [
    const TranscriptMessage.localCommand('/init'),
    ...applied.lines.map(TranscriptMessage.localCommandStdout),
  ];
  session.conversation.appendTranscriptMessages(messages);
  _persistConversationSnapshot(
    sessionId: session.sessionId,
    config: session.config,
    conversation: session.conversation,
  );
  _appendRichTranscriptMessages(transcript, messages);
  return applied.status;
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
  final headerBody = _buildRichHeaderBody(session, inner);
  final composerInnerWidth = max(8, inner - 4);
  final composerView = buildRichComposerView(
    inputBuffer,
    inputCursor,
    composerInnerWidth,
    maxLines: 6,
  );

  final headerRows = headerBody.length + 3;
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
  for (var i = 0; i < headerBody.length; i++) {
    _writeRow(console, i + 1, '│${headerBody[i]}│');
  }
  _writeRow(console, headerBody.length + 1, '╰${'─' * inner}╯');
  _writeRow(console, headerBody.length + 2, '─' * width);

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
    '╭${_fillTitle('── Message (Enter=send, Ctrl+J=newline, paste multiline ok, Up/Down=cursor/history, Ctrl+P/N=history) ', inner)}╮',
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

List<String> _buildRichHeaderBody(_ReplSessionState session, int innerWidth) {
  final columnGap = 3;
  final leftWidth = max(32, min(52, (innerWidth - columnGap) ~/ 2));
  final rightWidth = innerWidth - leftWidth - columnGap;
  final providerHint = buildProviderSetupHint(session.config);
  final savedSessions = listWorkspaceSessions();
  final recentSession = readWorkspaceSession(session.sessionId) ??
      (savedSessions.isEmpty ? null : savedSessions.first);

  final leftColumn = [
    '',
    _centerHeaderLine('Welcome back!', leftWidth),
    '',
    _centerHeaderLine('▐▛███▜▌', leftWidth),
    _centerHeaderLine('▝▜█████▛▘', leftWidth),
    _centerHeaderLine('▘▘ ▝▝', leftWidth),
    '',
    ' ${session.provider.name} · ${session.model ?? 'default'}',
    ' ${_truncateDisplayPath(Directory.current.path, max(12, leftWidth - 2))}',
  ];
  final rightColumn = [
    'Tips for getting started',
    providerHint ?? 'Provider ready. Enter to send.',
    '',
    'Session',
    'id=${session.sessionId}',
    recentSession == null
        ? 'No saved activity yet'
        : 'last=${recentSession.title}',
    '',
    '/help for commands',
    'Ctrl+J newline · Ctrl+C interrupt',
  ];
  final rows = max(leftColumn.length, rightColumn.length);
  final lines = <String>[];
  for (var i = 0; i < rows; i++) {
    final left = i < leftColumn.length ? leftColumn[i] : '';
    final right = i < rightColumn.length ? rightColumn[i] : '';
    lines.add(
      '${_fitRow(left, leftWidth)} │ ${_fitRow(right, rightWidth)}',
    );
  }
  return lines;
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
  String Function(String draft)? displayTransform,
  required void Function(String draft, int cursor) onDraftChanged,
}) {
  final draft = RichComposerBuffer();
  final utf8Decoder = RichInputUtf8Decoder();
  int? historyIndex;
  var historyStash = '';

  String displayDraft() => displayTransform?.call(draft.text) ?? draft.text;

  void applyHistoryValue(String value) {
    draft.setText(value);
    onDraftChanged(displayDraft(), draft.cursor);
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
    onDraftChanged(displayDraft(), draft.cursor);
  }

  if (stdout.hasTerminal) {
    stdout.write(_enableBracketedPasteMode);
  }
  console.rawMode = true;
  console.showCursor();
  try {
    while (true) {
      final token = _readRichInputToken(_stdinReadByteForRichInputSync);
      switch (token.kind) {
        case RichInputTokenKind.eof:
          return _RichInputEvent.eof();
        case RichInputTokenKind.paste:
        case RichInputTokenKind.text:
          final text = token.text ?? '';
          if (text.isEmpty) {
            continue;
          }
          if (draft.insert(text)) {
            onEditChange();
          }
          continue;
        case RichInputTokenKind.control:
          utf8Decoder.reset();
          switch (token.controlChar ?? ControlCharacter.unknown) {
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
                onDraftChanged(displayDraft(), draft.cursor);
              }
              continue;
            case ControlCharacter.arrowRight:
            case ControlCharacter.ctrlF:
              if (draft.moveRight()) {
                onDraftChanged(displayDraft(), draft.cursor);
              }
              continue;
            case ControlCharacter.home:
            case ControlCharacter.ctrlA:
              if (draft.moveLineStart()) {
                onDraftChanged(displayDraft(), draft.cursor);
              }
              continue;
            case ControlCharacter.end:
            case ControlCharacter.ctrlE:
              if (draft.moveLineEnd()) {
                onDraftChanged(displayDraft(), draft.cursor);
              }
              continue;
            case ControlCharacter.arrowUp:
              if (draft.moveUp()) {
                onDraftChanged(displayDraft(), draft.cursor);
              } else {
                moveHistoryUp();
              }
              continue;
            case ControlCharacter.arrowDown:
              if (draft.moveDown()) {
                onDraftChanged(displayDraft(), draft.cursor);
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
    }
  } finally {
    console.rawMode = false;
    if (stdout.hasTerminal) {
      stdout.write(_disableBracketedPasteMode);
    }
    console.hideCursor();
  }
}

int _stdinReadByteForRichInputSync() {
  return readRichInputByteSyncForTest(
    stdin.readByteSync,
    stdinHasTerminal: stdin.hasTerminal,
  );
}

int readRichInputByteSyncForTest(
  int Function() readByte, {
  required bool stdinHasTerminal,
  void Function()? onTransientEof,
}) {
  while (true) {
    final value = readByte();
    if (value != -1 || !stdinHasTerminal) {
      return value;
    }
    if (onTransientEof != null) {
      onTransientEof();
      continue;
    }
    sleep(const Duration(milliseconds: 10));
  }
}

RichInputToken _readRichInputToken(int Function() readByte) {
  final codeUnit = _readNextNonZeroByte(readByte);
  if (codeUnit == -1) {
    return const RichInputToken.eof();
  }
  if (codeUnit >= 0x01 && codeUnit <= 0x1A) {
    return RichInputToken.control(ControlCharacter.values[codeUnit]);
  }
  if (codeUnit == 0x1B) {
    return _readRichEscapeSequence(readByte);
  }
  if (codeUnit == 0x7F) {
    return const RichInputToken.control(ControlCharacter.backspace);
  }
  if (codeUnit == 0x00 || (codeUnit >= 0x1C && codeUnit <= 0x1F)) {
    return const RichInputToken.control(ControlCharacter.unknown);
  }
  return RichInputToken.text(_decodeRichUtf8Scalar(codeUnit, readByte));
}

int _readNextNonZeroByte(int Function() readByte) {
  while (true) {
    final value = readByte();
    if (value == -1 || value > 0) {
      return value;
    }
  }
}

RichInputToken _readRichEscapeSequence(int Function() readByte) {
  final next = readByte();
  if (next == -1) {
    return const RichInputToken.control(ControlCharacter.escape);
  }
  if (next == 0x7F) {
    return const RichInputToken.control(ControlCharacter.wordBackspace);
  }
  if (next == 0x5B) {
    return _readRichCsiSequence(readByte);
  }
  if (next == 0x4F) {
    final third = readByte();
    return switch (third) {
      0x48 => const RichInputToken.control(ControlCharacter.home),
      0x46 => const RichInputToken.control(ControlCharacter.end),
      0x50 => const RichInputToken.control(ControlCharacter.F1),
      0x51 => const RichInputToken.control(ControlCharacter.F2),
      0x52 => const RichInputToken.control(ControlCharacter.F3),
      0x53 => const RichInputToken.control(ControlCharacter.F4),
      _ => const RichInputToken.control(ControlCharacter.unknown),
    };
  }
  if (next == 0x62) {
    return const RichInputToken.control(ControlCharacter.wordLeft);
  }
  if (next == 0x66) {
    return const RichInputToken.control(ControlCharacter.wordRight);
  }
  return const RichInputToken.control(ControlCharacter.unknown);
}

RichInputToken _readRichCsiSequence(int Function() readByte) {
  final bytes = <int>[];
  while (true) {
    final value = readByte();
    if (value == -1) {
      break;
    }
    bytes.add(value);
    if ((value >= 0x40 && value <= 0x7E) || bytes.length >= 16) {
      break;
    }
  }

  final sequence = ascii.decode(bytes, allowInvalid: true);
  if (sequence == 'A' || sequence.endsWith('A')) {
    return const RichInputToken.control(ControlCharacter.arrowUp);
  }
  if (sequence == 'B' || sequence.endsWith('B')) {
    return const RichInputToken.control(ControlCharacter.arrowDown);
  }
  if (sequence == 'C' || sequence.endsWith('C')) {
    return const RichInputToken.control(ControlCharacter.arrowRight);
  }
  if (sequence == 'D' || sequence.endsWith('D')) {
    return const RichInputToken.control(ControlCharacter.arrowLeft);
  }
  if (sequence == 'H' || sequence.endsWith('H')) {
    return const RichInputToken.control(ControlCharacter.home);
  }
  if (sequence == 'F' || sequence.endsWith('F')) {
    return const RichInputToken.control(ControlCharacter.end);
  }
  if (sequence == '1~' || sequence == '7~') {
    return const RichInputToken.control(ControlCharacter.home);
  }
  if (sequence == '3~') {
    return const RichInputToken.control(ControlCharacter.delete);
  }
  if (sequence == '4~' || sequence == '8~') {
    return const RichInputToken.control(ControlCharacter.end);
  }
  if (sequence == '5~') {
    return const RichInputToken.control(ControlCharacter.pageUp);
  }
  if (sequence == '6~') {
    return const RichInputToken.control(ControlCharacter.pageDown);
  }
  if (sequence == '200~') {
    return RichInputToken.paste(_readBracketedPaste(readByte));
  }
  return const RichInputToken.control(ControlCharacter.unknown);
}

String _readBracketedPaste(int Function() readByte) {
  final bytes = <int>[];
  while (true) {
    final value = readByte();
    if (value == -1) {
      break;
    }
    bytes.add(value);
    if (_endsWithBytes(bytes, _bracketedPasteEndBytes)) {
      bytes.removeRange(
        bytes.length - _bracketedPasteEndBytes.length,
        bytes.length,
      );
      break;
    }
  }

  final text = utf8.decode(bytes, allowMalformed: true);
  return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

String _decodeRichUtf8Scalar(int firstByte, int Function() readByte) {
  final bytes = <int>[firstByte];
  final expectedLength = _expectedUtf8Length(firstByte);
  for (var i = 1; i < expectedLength; i++) {
    final next = readByte();
    if (next == -1) {
      break;
    }
    bytes.add(next);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

int _expectedUtf8Length(int firstByte) {
  if ((firstByte & 0x80) == 0) {
    return 1;
  }
  if ((firstByte & 0xE0) == 0xC0) {
    return 2;
  }
  if ((firstByte & 0xF0) == 0xE0) {
    return 3;
  }
  if ((firstByte & 0xF8) == 0xF0) {
    return 4;
  }
  return 1;
}

bool _endsWithBytes(List<int> bytes, List<int> suffix) {
  if (bytes.length < suffix.length) {
    return false;
  }
  for (var i = 0; i < suffix.length; i++) {
    if (bytes[bytes.length - suffix.length + i] != suffix[i]) {
      return false;
    }
  }
  return true;
}

const String _enableBracketedPasteMode = '\x1b[?2004h';
const String _disableBracketedPasteMode = '\x1b[?2004l';
const List<int> _bracketedPasteEndBytes = <int>[
  0x1B,
  0x5B,
  0x32,
  0x30,
  0x31,
  0x7E,
];

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

String _centerHeaderLine(String value, int width) {
  final valueWidth = _displayWidth(value);
  if (valueWidth >= width) {
    return _fitRow(value, width);
  }
  final leftPadding = max(0, (width - valueWidth) ~/ 2);
  return _fitRow('${' ' * leftPadding}$value', width);
}

String _truncateDisplayPath(String value, int width) {
  if (_displayWidth(value) <= width || width <= 0) {
    return value;
  }
  if (width <= 1) {
    return _takeDisplayWidth(value, width);
  }
  final suffixLength = min(value.length, max(1, width - 1));
  final suffix = value.substring(value.length - suffixLength);
  return '…$suffix';
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

Stream<void>? _watchSigintInterrupts() {
  if (!stdin.hasTerminal) {
    return null;
  }
  try {
    return ProcessSignal.sigint.watch().map<void>((_) {});
  } catch (_) {
    return null;
  }
}

Future<TurnExecutionResult> _runReplTurnCollectStream(
  QueryEngine engine,
  QueryRequest request, {
  bool allowInterrupt = false,
  void Function()? onInterrupt,
  void Function(QueryEvent event)? onEvent,
  void Function(String delta, String? modelUsed)? onDelta,
}) async {
  return TurnExecutor(engine).execute(
    request: request,
    turn: 1,
    onEvent: onEvent,
    onDelta: onDelta,
    interruptSignals: allowInterrupt ? _watchSigintInterrupts() : null,
    onInterrupt: onInterrupt,
  );
}

Future<TurnExecutionResult> _runReplTurnJson(
  QueryEngine engine,
  QueryRequest request,
) async {
  final result = await _runReplTurnCollectStream(
    engine,
    request,
    allowInterrupt: stdin.hasTerminal,
    onEvent: (event) {
      print(jsonEncode(event.toJson()));
    },
  );

  print(
    jsonEncode(
      QueryEvent(
        type: QueryEventType.done,
        turns: 1,
        output: result.output,
        model: result.modelUsed ?? request.model,
        status: result.failed ? 'error' : 'ok',
      ).toJson(),
    ),
  );
  return result;
}

Future<TurnExecutionResult> _runReplTurnStreamText(
  QueryEngine engine,
  QueryRequest request,
) async {
  var printedAnyDelta = false;
  final result = await _runReplTurnCollectStream(
    engine,
    request,
    allowInterrupt: stdin.hasTerminal,
    onDelta: (delta, modelUsed) {
      printedAnyDelta = true;
      stdout.write(delta);
    },
  );
  if (result.success) {
    if (!printedAnyDelta && result.output.isNotEmpty) {
      stdout.write(result.output);
    }
    stdout.writeln('');
    return result;
  }
  if (result.interrupted) {
    if (!printedAnyDelta && result.rawOutput.isNotEmpty) {
      stdout.write(result.rawOutput);
      stdout.writeln('');
    } else if (printedAnyDelta) {
      stdout.writeln('');
    }
    print('[interrupted] response cancelled');
    return result;
  }
  if (printedAnyDelta) {
    stdout.writeln('');
  }
  print(result.output);
  return result;
}

Future<int> _runDoctorCommand(CommandContext context) async {
  final gitState = await readGitWorkspaceState();
  for (final line in buildDoctorReportLines(
    context.config,
    gitState: gitState,
  )) {
    print(line);
  }
  return 0;
}

Future<int> _runMemoryCommand(CommandContext context) async {
  if (context.args.isEmpty || context.args.first == 'show') {
    final memory = readWorkspaceMemory();
    print(memory.isEmpty ? '[empty-memory]' : memory);
    return 0;
  }

  final subcommand = context.args.first;
  switch (subcommand) {
    case 'set':
      final text = context.args.skip(1).join(' ');
      if (text.trim().isEmpty) {
        print('error: memory set requires text');
        return 2;
      }
      writeWorkspaceMemory(text);
      print('memory saved to ${workspaceMemoryPath()}');
      return 0;
    case 'append':
      final text = context.args.skip(1).join(' ');
      if (text.trim().isEmpty) {
        print('error: memory append requires text');
        return 2;
      }
      final current = readWorkspaceMemory();
      final next = current.trim().isEmpty ? text : '$current\n$text';
      writeWorkspaceMemory(next);
      print('memory appended to ${workspaceMemoryPath()}');
      return 0;
    case 'clear':
      writeWorkspaceMemory('');
      print('memory cleared');
      return 0;
    default:
      print(
          'error: memory usage: memory [show|set <text>|append <text>|clear]');
      return 2;
  }
}

Future<int> _runTasksCommand(CommandContext context) async {
  if (context.args.isEmpty || context.args.first == 'list') {
    final tasks = readWorkspaceTasks();
    if (tasks.isEmpty) {
      print('[no-tasks]');
      return 0;
    }
    for (final task in tasks) {
      final marker = task.done ? 'x' : ' ';
      print('[$marker] #${task.id} ${task.text}');
    }
    return 0;
  }

  final subcommand = context.args.first;
  switch (subcommand) {
    case 'add':
      final text = context.args.skip(1).join(' ');
      if (text.trim().isEmpty) {
        print('error: tasks add requires text');
        return 2;
      }
      final task = addWorkspaceTask(text);
      print('task added: #${task.id} ${task.text}');
      return 0;
    case 'done':
      if (context.args.length < 2) {
        print('error: tasks done requires an id');
        return 2;
      }
      final id = int.tryParse(context.args[1]);
      if (id == null || id < 1) {
        print('error: task id must be a positive integer');
        return 2;
      }
      final updated = completeWorkspaceTask(id);
      if (updated == null) {
        print('error: task #$id not found');
        return 1;
      }
      print('task completed: #${updated.id} ${updated.text}');
      return 0;
    case 'clear':
      clearWorkspaceTasks();
      print('tasks cleared');
      return 0;
    default:
      print('error: tasks usage: tasks [list|add <text>|done <id>|clear]');
      return 2;
  }
}

Future<int> _runPermissionsCommand(CommandContext context) async {
  if (context.args.isEmpty || context.args.first == 'show') {
    final mode = readDefaultToolPermissionMode();
    print('defaultToolPermission=${mode.name}');
    print('config=${workspacePermissionsPath()}');
    return 0;
  }

  if (context.args.first != 'set' || context.args.length < 2) {
    print('error: permissions usage: permissions [show|set allow|deny]');
    return 2;
  }

  final mode = _parseToolPermissionMode(context.args[1]);
  if (mode == null) {
    print('error: permissions set requires allow|deny');
    return 2;
  }
  writeDefaultToolPermissionMode(mode);
  print('default tool permission saved: ${mode.name}');
  return 0;
}

Future<int> _runExportCommand(CommandContext context) async {
  String? outputPath;
  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--out') {
      if (i + 1 >= context.args.length) {
        print('error: --out requires a path');
        return 2;
      }
      outputPath = context.args[i + 1];
      i += 2;
      continue;
    }
    if (token.startsWith('--')) {
      print('error: unknown option for export: $token');
      return 2;
    }
    outputPath ??= token;
    i += 1;
  }

  final gitState = await readGitWorkspaceState();

  final snapshot = {
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'workspace': Directory.current.path,
    'config': {
      'provider': context.config.provider.name,
      'model': context.config.model,
      'configPath': context.config.configPath,
    },
    'providerHint': buildProviderSetupHint(context.config),
    'memory': readWorkspaceMemory(),
    'tasks': readWorkspaceTasks().map((task) => task.toJson()).toList(),
    'defaultToolPermission': readDefaultToolPermissionMode().name,
    'mcpServers':
        readWorkspaceMcpServers().map((server) => server.toJson()).toList(),
    'git': {
      'isGitRepository': gitState.isGitRepository,
      'rootPath': gitState.rootPath,
      'baseRef': gitState.baseRef,
      'hasChanges': gitState.hasChanges,
      'filesChanged': gitState.filesChanged,
      'untrackedFiles': gitState.untrackedFiles,
      'linesAdded': gitState.linesAdded,
      'linesRemoved': gitState.linesRemoved,
      'files': gitState.files.map((file) => file.toJson()).toList(),
    },
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(snapshot);

  if (outputPath == null || outputPath.trim().isEmpty) {
    print(encoded);
    return 0;
  }

  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(encoded);
  print('workspace snapshot exported to ${file.path}');
  return 0;
}

Future<int> _runDiffCommand(CommandContext context) async {
  var asJson = false;
  var statOnly = false;
  var namesOnly = false;

  for (final token in context.args) {
    switch (token) {
      case '--json':
        asJson = true;
        break;
      case '--stat':
        statOnly = true;
        break;
      case '--name-only':
        namesOnly = true;
        break;
      default:
        print('error: diff usage: diff [--json|--stat|--name-only]');
        return 2;
    }
  }

  final modeCount =
      [asJson, statOnly, namesOnly].where((enabled) => enabled).length;
  if (modeCount > 1) {
    print('error: diff options are mutually exclusive');
    return 2;
  }

  final state = await readGitWorkspaceState();
  if (!state.isGitRepository) {
    print('error: current workspace is not a git repository');
    return 1;
  }

  if (asJson) {
    print(const JsonEncoder.withIndent('  ').convert(state.toJson()));
    return 0;
  }

  if (namesOnly) {
    if (!state.hasChanges) {
      print('[clean-worktree]');
      return 0;
    }
    for (final file in state.files) {
      print(file.path);
    }
    return 0;
  }

  print(
    renderGitWorkspaceSummary(
      state,
      includePatch: !statOnly,
      includeUntrackedPreview: !statOnly,
    ),
  );
  return 0;
}

Future<int> _runReviewCommand(CommandContext context) async {
  var promptOnly = false;
  final extraInstructionTokens = <String>[];

  for (final token in context.args) {
    if (token == '--prompt-only') {
      promptOnly = true;
      continue;
    }
    extraInstructionTokens.add(token);
  }

  final state = await readGitWorkspaceState();
  if (!state.isGitRepository) {
    print('error: current workspace is not a git repository');
    return 1;
  }
  if (!state.hasChanges) {
    print('[clean-worktree]');
    return 0;
  }

  final reviewPrompt = buildReviewPrompt(
    state,
    extraInstructions: extraInstructionTokens.join(' ').trim(),
  );
  if (promptOnly) {
    print(reviewPrompt);
    return 0;
  }

  final submission = PromptSubmitter().submit(
    reviewPrompt,
    model: context.config.model,
  );
  final processed = const UserInputProcessor().process(submission);
  if (!processed.isQuery) {
    print('error: review prompt could not be constructed');
    return 2;
  }

  final result = await TurnExecutor(context.engine).execute(
    request: processed.request!,
    turn: 1,
    emitTurnStart: false,
  );
  final transcript = [
    ...processed.transcriptMessages,
    ...result.transcriptMessages,
  ];
  final history = result.success || result.interrupted
      ? processed.request!.messages.followedBy([
          if (result.displayOutput.isNotEmpty)
            ChatMessage(
              role: MessageRole.assistant,
              text: result.displayOutput,
            ),
        ]).toList()
      : processed.request!.messages;
  writeWorkspaceSession(
    buildWorkspaceSessionSnapshot(
      id: createWorkspaceSessionId(),
      provider: context.config.provider.name,
      model: context.config.model,
      history: history,
      transcript: transcript,
    ),
  );
  print(result.output);
  return result.success ? 0 : 1;
}

WorkspaceSessionSnapshot? _resolveRequestedSession(
  String? requestedId,
) {
  final effectiveId = requestedId?.trim().isNotEmpty == true
      ? requestedId!.trim()
      : readActiveWorkspaceSessionId();
  if (effectiveId == null || effectiveId.isEmpty) {
    return null;
  }
  return readWorkspaceSession(effectiveId);
}

Future<int> _runSessionCommand(CommandContext context) async {
  if (context.args.isEmpty || context.args.first == 'list') {
    final sessions = listWorkspaceSessions();
    if (sessions.isEmpty) {
      print('[no-sessions]');
      return 0;
    }
    final activeId = readActiveWorkspaceSessionId();
    for (final session in sessions) {
      final activeMarker = session.id == activeId ? '*' : ' ';
      print(
        '$activeMarker ${session.id}\t${session.provider}\t${session.model ?? 'default'}\t${session.title}',
      );
    }
    return 0;
  }

  final subcommand = context.args.first;
  if (subcommand == 'show' || subcommand == 'current') {
    String? id;
    var asJson = false;
    for (final token in context.args.skip(1)) {
      if (token == '--json') {
        asJson = true;
      } else {
        id ??= token;
      }
    }
    final snapshot =
        _resolveRequestedSession(subcommand == 'current' ? null : id);
    if (snapshot == null) {
      print('error: session not found');
      return 1;
    }
    if (asJson) {
      print(const JsonEncoder.withIndent('  ').convert(snapshot.toJson()));
      return 0;
    }
    print('id=${snapshot.id}');
    print('title=${snapshot.title}');
    print('provider=${snapshot.provider}');
    print('model=${snapshot.model ?? 'default'}');
    print('createdAt=${snapshot.createdAt}');
    print('updatedAt=${snapshot.updatedAt}');
    print('history.messages=${snapshot.history.length}');
    print('transcript.messages=${snapshot.transcript.length}');
    return 0;
  }

  print(
      'error: session usage: session [list|show <id> [--json]|current [--json]]');
  return 2;
}

Future<int> _runResumeCommand(CommandContext context) async {
  if (context.args.isEmpty) {
    print('error: resume usage: resume [--last|<id>] <prompt>');
    return 2;
  }

  String? requestedId;
  final promptTokens = <String>[];
  for (final token in context.args) {
    if (token == '--last' && requestedId == null) {
      requestedId = readActiveWorkspaceSessionId();
      continue;
    }
    if (requestedId == null && promptTokens.isEmpty) {
      final direct = readWorkspaceSession(token);
      if (direct != null) {
        requestedId = direct.id;
        continue;
      }
    }
    promptTokens.add(token);
  }

  final prompt = promptTokens.join(' ').trim();
  if (prompt.isEmpty) {
    print('error: resume requires prompt text');
    return 2;
  }

  final snapshot = _resolveRequestedSession(requestedId);
  if (snapshot == null) {
    print('error: session not found');
    return 1;
  }

  final resumedConfig = context.config.copyWith(
    provider: parseProviderKind(snapshot.provider) ?? context.config.provider,
    model: snapshot.model ?? context.config.model,
  );
  final conversation = ConversationSession(
    initialMessages: snapshot.history,
    initialTranscript: snapshot.transcript,
  );
  final submission = PromptSubmitter(conversation: conversation).submit(
    prompt,
    model: resumedConfig.model,
  );
  final processed = const UserInputProcessor().process(submission);
  if (!processed.isQuery) {
    print('error: resume only accepts plain prompt text');
    return 2;
  }

  final engine = _buildRuntimeEngine(context, resumedConfig);
  final result = await TurnExecutor(engine).execute(
    request: processed.request!,
    turn: 1,
  );
  conversation.appendTranscriptMessages([
    ...processed.transcriptMessages,
    ...result.transcriptMessages,
  ]);
  if (result.success || result.interrupted) {
    conversation.recordHistoryTurn(
      prompt: processed.submission.raw,
      output: result.displayOutput,
    );
  }
  final existing = readWorkspaceSession(snapshot.id);
  writeWorkspaceSession(
    buildWorkspaceSessionSnapshot(
      id: snapshot.id,
      provider: resumedConfig.provider.name,
      model: resumedConfig.model,
      history: conversation.history,
      transcript: conversation.transcript,
      createdAt: existing?.createdAt ?? snapshot.createdAt,
    ),
  );
  print(result.output);
  return result.success ? 0 : 1;
}

Future<int> _runShareCommand(CommandContext context) async {
  String? requestedId;
  String? outputPath;
  var format = 'md';

  var i = 0;
  while (i < context.args.length) {
    final token = context.args[i];
    if (token == '--format') {
      if (i + 1 >= context.args.length) {
        print('error: --format requires md|json');
        return 2;
      }
      format = context.args[i + 1].trim();
      i += 2;
      continue;
    }
    if (token == '--out') {
      if (i + 1 >= context.args.length) {
        print('error: --out requires a path');
        return 2;
      }
      outputPath = context.args[i + 1];
      i += 2;
      continue;
    }
    if (requestedId == null) {
      requestedId = token;
      i += 1;
      continue;
    }
    print('error: share usage: share [<id>] [--format md|json] [--out PATH]');
    return 2;
  }

  if (format != 'md' && format != 'json') {
    print('error: share --format must be md|json');
    return 2;
  }

  final snapshot = _resolveRequestedSession(requestedId);
  if (snapshot == null) {
    print('error: session not found');
    return 1;
  }

  final content = format == 'json'
      ? const JsonEncoder.withIndent('  ').convert(snapshot.toJson())
      : renderWorkspaceSessionMarkdown(snapshot);

  if (outputPath == null || outputPath.trim().isEmpty) {
    print(content);
    return 0;
  }

  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  print('session shared to ${file.path}');
  return 0;
}

Future<int> _runMcpCommand(CommandContext context) async {
  if (context.args.isEmpty || context.args.first == 'list') {
    final servers = readWorkspaceMcpServers();
    if (servers.isEmpty) {
      print('[no-mcp-servers]');
      return 0;
    }
    for (final server in servers) {
      print('${server.name}\t${server.transport}\t${server.target}');
    }
    return 0;
  }

  final subcommand = context.args.first;
  switch (subcommand) {
    case 'add':
      if (context.args.length < 4) {
        print(
            'error: mcp add usage: mcp add <name> <stdio|sse|http|ws> <target>');
        return 2;
      }
      final name = context.args[1].trim();
      final transport = context.args[2].trim();
      final target = context.args.sublist(3).join(' ').trim();
      if (name.isEmpty || target.isEmpty) {
        print('error: mcp add requires non-empty name and target');
        return 2;
      }
      if (!_isSupportedMcpTransport(transport)) {
        print('error: mcp transport must be stdio|sse|http|ws');
        return 2;
      }
      upsertWorkspaceMcpServer(
        WorkspaceMcpServer(
          name: name,
          transport: transport,
          target: target,
        ),
      );
      print('mcp server saved: $name');
      return 0;
    case 'remove':
      if (context.args.length < 2) {
        print('error: mcp remove requires a name');
        return 2;
      }
      final removed = removeWorkspaceMcpServer(context.args[1].trim());
      if (!removed) {
        print('error: mcp server not found: ${context.args[1].trim()}');
        return 1;
      }
      print('mcp server removed: ${context.args[1].trim()}');
      return 0;
    case 'clear':
      writeWorkspaceMcpServers(const []);
      print('mcp servers cleared');
      return 0;
    default:
      print(
          'error: mcp usage: mcp [list|add <name> <transport> <target>|remove <name>|clear]');
      return 2;
  }
}

bool _isSupportedMcpTransport(String raw) {
  switch (raw) {
    case 'stdio':
    case 'sse':
    case 'http':
    case 'ws':
      return true;
    default:
      return false;
  }
}

Future<int> _runToolCommand(CommandContext context) async {
  var permissionMode = readDefaultToolPermissionMode();
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
    permissionPolicy: ToolPermissionPolicy(defaultMode: permissionMode),
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
  doctor               Show workspace/config diagnostics
  diff [opts]          Show current git workspace diff
  features             Show implemented migration features
  init [opts]          Initialize provider config (provider/key/host/model)
  chat <prompt>        One-shot prompt
  print <prompt>       Alias of chat
  loop [opts] <prompt> Multi-turn loop
  review [opts]        Review current git workspace changes
  auth [opts]          Save provider auth config (provider + key + host)
  memory [...]         Manage workspace memory file
  tasks [...]          Manage simple local task list
  permissions [...]    Show/set default tool permission mode
  export [opts]        Export workspace snapshot as JSON
  session [...]        Inspect saved local sessions
  resume [...]         Resume a saved session with a new prompt
  share [opts]         Export a saved session as JSON/Markdown
  mcp [...]            Manage simple local MCP registry
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
  --ui MODE            plain|rich (default rich)

Auth opts:
  --provider NAME      claude|openai (required unless current provider is set)
  --api-key KEY        Provider API key
  --base-url URL       Provider host/base URL
  --config PATH        Output config path (default: ./.clart/config.json)
  --show               Show current auth summary only

Diff opts:
  --json               Print structured git workspace snapshot
  --stat               Print summary without patch body
  --name-only          Print changed file paths only

Review opts:
  --prompt-only        Print generated review prompt without executing model

Init opts:
  --provider NAME      claude|openai (prompted if missing in terminal)
  --api-key KEY        Provider API key (prompted if missing in terminal)
  --base-url URL       Provider host/base URL (optional)
  --model NAME         Model name (optional)
  --config PATH        Output config path (default: ./.clart/config.json)

Tool opts:
  --permission MODE    allow|deny (default: persisted mode or allow)

Memory usage:
  memory [show|set <text>|append <text>|clear]

Tasks usage:
  tasks [list|add <text>|done <id>|clear]

Permissions usage:
  permissions [show|set allow|deny]

Export opts:
  --out PATH           Write workspace snapshot to file instead of stdout

Session usage:
  session [list|show <id> [--json]|current [--json]]

Resume usage:
  resume [--last|<id>] <prompt>

Share opts:
  --format FORMAT      md|json (default md)
  --out PATH           Write exported session to file instead of stdout

MCP usage:
  mcp [list|add <name> <transport> <target>|remove <name>|clear]

Tool usage:
  tool read <path>
  tool write <path> <content>
  tool shell <command...>

Start opts:
  --yes                Trust current folder and proceed
  --no                 Exit immediately
  --no-repl            Render welcome only, skip REPL
  --ui MODE            plain|rich (default rich)
  --trust-file PATH    Override trust storage path (for tests/CI)

Notes:
  - Telemetry/reporting is intentionally no-op.
  - Claude/OpenAI providers are wired in minimal migration mode.
  - Missing capabilities are kept as placeholders to preserve runnability.
''');
}
