import 'dart:io';

import '../core/app_config.dart';
import '../core/process_user_input.dart';
import 'provider_setup.dart';

abstract interface class ReplCommandSession {
  AppConfig get config;
  set config(AppConfig value);

  void clearConversation();
}

LocalCommandResult? executeReplSlashCommand(
  String raw,
  ReplCommandSession session,
) {
  final input = raw.trim();
  if (input == '/help') {
    return const LocalCommandResult(
      status: 'Displayed help.',
      messages: [
        TranscriptMessage.system('Available REPL commands:'),
        TranscriptMessage.system('/help     Show this help'),
        TranscriptMessage.system(
            '/init     Configure real LLM provider/api key'),
        TranscriptMessage.system('/model    Show or switch current model'),
        TranscriptMessage.system('/provider Show or switch current provider'),
        TranscriptMessage.system('/status   Show current provider/model'),
        TranscriptMessage.system(
            '/clear    Clear terminal screen / transcript'),
        TranscriptMessage.system('/exit     Exit REPL'),
        TranscriptMessage.system(''),
        TranscriptMessage.system('Input tips:'),
        TranscriptMessage.system(
            '- Plain UI: end line with \\ then Enter for newline'),
        TranscriptMessage.system(
            '- Rich UI: Ctrl+J inserts newline (true multiline composer)'),
        TranscriptMessage.system(
            '- Rich UI: Ctrl+P / Ctrl+N browse input history'),
        TranscriptMessage.system(
            '- Ctrl+C interrupts current streaming response'),
        TranscriptMessage.system('- At prompt, press Ctrl+C twice to exit'),
      ],
    );
  }
  if (input == '/init') {
    return const LocalCommandResult(
      status: 'Displayed /init usage.',
      messages: [
        TranscriptMessage.system(
          'usage: /init <claude|openai> <apiKey> [baseUrl] [model]  (or run: clart_code init)',
        ),
      ],
    );
  }
  if (input.startsWith('/init ')) {
    final parsed = parseInlineInitCommand(input);
    if (parsed.error != null) {
      return LocalCommandResult(
        status: parsed.error!,
        messages: [
          TranscriptMessage.system(parsed.error!),
        ],
      );
    }
    final nextConfig = saveProviderSetup(
      current: session.config,
      provider: parsed.provider!,
      apiKey: parsed.apiKey!,
      baseUrl: parsed.baseUrl,
      model: parsed.model,
    );
    session.config = nextConfig;
    final hint = buildProviderSetupHint(session.config);
    final lines = <String>[
      'configured ${parsed.provider!.name} -> ${nextConfig.configPath ?? defaultConfigPath(cwd: Directory.current.path)}',
    ];
    if (parsed.model != null && parsed.model!.trim().isNotEmpty) {
      lines.add('model switched to ${session.config.model}');
    }
    lines.add(hint == null ? 'init complete.' : 'hint: $hint');
    return LocalCommandResult(
      status: hint ?? 'Initialized provider config.',
      messages: lines.map(TranscriptMessage.system).toList(),
    );
  }
  if (input == '/model') {
    return LocalCommandResult(
      status: 'Displayed model.',
      messages: [
        TranscriptMessage.system('provider=${session.config.provider.name}'),
        TranscriptMessage.system('model=${session.config.model ?? 'default'}'),
      ],
    );
  }
  if (input.startsWith('/model ')) {
    final requested = input.substring('/model '.length).trim();
    if (requested.isEmpty) {
      return const LocalCommandResult(
        status: 'usage: /model <name>',
        messages: [
          TranscriptMessage.system('usage: /model <name>'),
        ],
      );
    }
    session.config = session.config.copyWith(model: requested);
    return LocalCommandResult(
      status: 'Model switched.',
      messages: [
        TranscriptMessage.system('model switched to $requested'),
      ],
    );
  }
  if (input == '/provider') {
    final hint = buildProviderSetupHint(session.config);
    final lines = <String>[
      'provider=${session.config.provider.name}',
      ...providerConfigSummaryLines(session.config),
    ];
    if (hint != null) {
      lines.add('hint: $hint');
    }
    return LocalCommandResult(
      status: 'Displayed provider.',
      messages: lines.map(TranscriptMessage.system).toList(),
    );
  }
  if (input.startsWith('/provider ')) {
    final requested = input.substring('/provider '.length).trim();
    final parsed = parseProviderKind(requested);
    if (parsed == null) {
      return const LocalCommandResult(
        status: 'usage: /provider local|claude|openai',
        messages: [
          TranscriptMessage.system('usage: /provider local|claude|openai'),
        ],
      );
    }
    session.config = session.config.copyWith(provider: parsed);
    final hint = buildProviderSetupHint(session.config);
    final lines = <String>[
      'provider switched to ${parsed.name}',
      ...providerConfigSummaryLines(session.config),
    ];
    if (hint != null) {
      lines.add('hint: $hint');
    }
    return LocalCommandResult(
      status: hint ?? 'Provider switched.',
      messages: lines.map(TranscriptMessage.system).toList(),
    );
  }
  if (input == '/status') {
    return LocalCommandResult(
      status: 'Displayed status.',
      messages: [
        TranscriptMessage.system('provider=${session.config.provider.name}'),
        TranscriptMessage.system('model=${session.config.model ?? 'default'}'),
      ],
    );
  }
  if (input == '/clear') {
    session.clearConversation();
    return const LocalCommandResult(
      status: 'Transcript cleared.',
      clearScreen: true,
      clearTranscript: true,
    );
  }
  return null;
}
