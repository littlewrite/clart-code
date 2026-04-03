import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
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
    this.error,
  });

  final String command;
  final List<String> commandArgs;
  final String? provider;
  final String? model;
  final String? configPath;
  final String? error;

  bool get isOk => error == null;
}

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
      description: 'Interactive startup (trust gate + welcome screen)',
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
      description: 'Run minimal interactive chat loop',
      handler: _runReplCommand,
    ),
    RegisteredCommand(
      name: 'loop',
      description: 'Run minimal multi-turn loop (Iteration 3 baseline)',
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
        return 0;
      },
    ),
    RegisteredCommand(
      name: 'features',
      description: 'Show currently implemented migration features',
      handler: (_) async {
        print('Implemented now:');
        print('- command registry + dispatcher');
        print('- config loading (env + JSON file)');
        print('- provider switching (local/claude/openai)');
        print('- one-shot chat/print');
        print('- startup trust gate + welcome screen');
        print('- minimal REPL command');
        print('- minimal multi-turn loop with optional stream-json');
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
  print('Entering minimal REPL. Type /exit to quit.');

  while (true) {
    stdout.write('> ');
    final line = stdin.readLineSync();
    if (line == null) {
      break;
    }

    final input = line.trim();
    if (input.isEmpty) {
      continue;
    }
    if (input == '/exit' || input == 'exit' || input == 'quit') {
      break;
    }

    final code = await runChatLikeCommand(
      CommandContext(
        command: 'chat',
        args: [input],
        config: context.config,
        engine: context.engine,
      ),
    );
    if (code != 0) {
      return code;
    }
  }

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
  );

  if (!streamJson) {
    print(result.lastOutput);
    print('[loop_done] turns=${result.turns}');
  }

  return result.success ? 0 : 1;
}

Future<int> _runStartCommand(CommandContext context) async {
  var assumeTrusted = false;
  var denyTrust = false;
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
  return 0;
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
  );
}

void _printHelp() {
  print('''
  clart_code - runnable migration baseline

Usage:
  clart_code [--config path.json] [--provider local|claude|openai] [--model name] <command>

Commands:
  help                 Show help
  version              Show version
  start [opts]         Trust gate + welcome screen
  status               Show current runtime config
  features             Show implemented migration features
  chat <prompt>        One-shot prompt
  print <prompt>       Alias of chat
  loop [opts] <prompt> Multi-turn loop
  tool [opts] ...      Run minimal tool executor
  repl                 Minimal interactive mode

Loop opts:
  --max-turns N        Number of turns (default 1)
  --stream-json        Print event stream as json lines

Tool opts:
  --permission MODE    allow|deny (default allow)

Tool usage:
  tool read <path>
  tool write <path> <content>
  tool shell <command...>

Start opts:
  --yes                Trust current folder and proceed
  --no                 Exit immediately
  --trust-file PATH    Override trust storage path (for tests/CI)

Notes:
  - Telemetry/reporting is intentionally no-op.
  - Claude/OpenAI providers are wired in minimal migration mode.
  - Missing capabilities are kept as placeholders to preserve runnability.
''');
}
