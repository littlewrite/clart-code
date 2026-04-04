import '../core/app_config.dart';
import '../core/process_user_input.dart';
import '../core/transcript.dart';
import 'git_workspace.dart';
import 'local_reports.dart';
import 'provider_setup.dart';
import 'workspace_store.dart';

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
        TranscriptMessage.localCommandStdout('Available REPL commands:'),
        TranscriptMessage.localCommandStdout('/help     Show this help'),
        TranscriptMessage.localCommandStdout(
            '/init     Configure real LLM provider/api key'),
        TranscriptMessage.localCommandStdout(
            '/model    Show or switch current model'),
        TranscriptMessage.localCommandStdout(
            '/provider Show or switch current provider'),
        TranscriptMessage.localCommandStdout(
            '/status   Show current provider/model'),
        TranscriptMessage.localCommandStdout(
            '/doctor   Show workspace/provider diagnostics'),
        TranscriptMessage.localCommandStdout(
            '/diff     Show current git workspace summary'),
        TranscriptMessage.localCommandStdout('/memory   Show workspace memory'),
        TranscriptMessage.localCommandStdout('/tasks    Show workspace tasks'),
        TranscriptMessage.localCommandStdout(
            '/permissions Show default tool permission mode'),
        TranscriptMessage.localCommandStdout(
            '/mcp      Show local MCP server registry'),
        TranscriptMessage.localCommandStdout(
            '/session  Show current active session snapshot'),
        TranscriptMessage.localCommandStdout(
            '/clear    Clear terminal screen / transcript'),
        TranscriptMessage.localCommandStdout('/exit     Exit REPL'),
        TranscriptMessage.localCommandStdout(''),
        TranscriptMessage.localCommandStdout('Input tips:'),
        TranscriptMessage.localCommandStdout(
            '- Plain UI: end line with \\ then Enter for newline'),
        TranscriptMessage.localCommandStdout(
            '- Rich UI: Ctrl+J inserts newline (true multiline composer)'),
        TranscriptMessage.localCommandStdout(
            '- Rich UI: paste keeps embedded newlines'),
        TranscriptMessage.localCommandStdout(
            '- Rich UI: Ctrl+P / Ctrl+N browse input history'),
        TranscriptMessage.localCommandStdout(
            '- Ctrl+C interrupts current streaming response'),
        TranscriptMessage.localCommandStdout(
            '- At prompt, press Ctrl+C twice to exit'),
      ],
    );
  }
  if (input == '/init') {
    return const LocalCommandResult(
      status: 'Displayed /init usage.',
      messages: [
        TranscriptMessage.localCommandStdout(
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
          TranscriptMessage.localCommandStderr(parsed.error!),
        ],
      );
    }
    final applied = applyProviderSetup(
      current: session.config,
      provider: parsed.provider!,
      apiKey: parsed.apiKey!,
      baseUrl: parsed.baseUrl,
      model: parsed.model,
    );
    session.config = applied.config;
    return LocalCommandResult(
      status: applied.status,
      messages:
          applied.lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/model') {
    return LocalCommandResult(
      status: 'Displayed model.',
      messages: [
        TranscriptMessage.localCommandStdout(
            'provider=${session.config.provider.name}'),
        TranscriptMessage.localCommandStdout(
            'model=${session.config.model ?? 'default'}'),
      ],
    );
  }
  if (input.startsWith('/model ')) {
    final requested = input.substring('/model '.length).trim();
    if (requested.isEmpty) {
      return const LocalCommandResult(
        status: 'usage: /model <name>',
        messages: [
          TranscriptMessage.localCommandStderr('usage: /model <name>'),
        ],
      );
    }
    session.config = session.config.copyWith(model: requested);
    return LocalCommandResult(
      status: 'Model switched.',
      messages: [
        TranscriptMessage.localCommandStdout('model switched to $requested'),
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
      messages: lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input.startsWith('/provider ')) {
    final requested = input.substring('/provider '.length).trim();
    final parsed = parseProviderKind(requested);
    if (parsed == null) {
      return const LocalCommandResult(
        status: 'usage: /provider local|claude|openai',
        messages: [
          TranscriptMessage.localCommandStderr(
              'usage: /provider local|claude|openai'),
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
      messages: lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/status') {
    return LocalCommandResult(
      status: 'Displayed status.',
      messages: [
        TranscriptMessage.localCommandStdout(
            'provider=${session.config.provider.name}'),
        TranscriptMessage.localCommandStdout(
            'model=${session.config.model ?? 'default'}'),
      ],
    );
  }
  if (input == '/doctor') {
    return LocalCommandResult(
      status: 'Displayed doctor report.',
      messages: buildDoctorReportLines(session.config)
          .map(TranscriptMessage.localCommandStdout)
          .toList(),
    );
  }
  if (input == '/diff') {
    final gitState = readGitWorkspaceStateSync();
    return LocalCommandResult(
      status: 'Displayed diff summary.',
      messages: renderGitWorkspaceSummary(
        gitState,
        includePatch: false,
        includeUntrackedPreview: true,
      ).split('\n').map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/memory') {
    final memory = readWorkspaceMemory();
    return LocalCommandResult(
      status: 'Displayed workspace memory.',
      messages: [
        TranscriptMessage.localCommandStdout(
          memory.isEmpty ? '[empty-memory]' : memory,
        ),
      ],
    );
  }
  if (input == '/tasks') {
    final tasks = readWorkspaceTasks();
    final lines = tasks.isEmpty
        ? const ['[no-tasks]']
        : tasks
            .map(
                (task) => '[${task.done ? 'x' : ' '}] #${task.id} ${task.text}')
            .toList();
    return LocalCommandResult(
      status: 'Displayed workspace tasks.',
      messages: lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/permissions') {
    final mode = readDefaultToolPermissionMode();
    return LocalCommandResult(
      status: 'Displayed permissions.',
      messages: [
        TranscriptMessage.localCommandStdout(
            'permissions.default=${mode.name}'),
      ],
    );
  }
  if (input == '/mcp') {
    final servers = readWorkspaceMcpServers();
    final lines = servers.isEmpty
        ? const ['[no-mcp-servers]']
        : servers
            .map(
              (server) =>
                  '${server.name}\t${server.transport}\t${server.target}',
            )
            .toList();
    return LocalCommandResult(
      status: 'Displayed MCP servers.',
      messages: lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/session') {
    final sessionId = readActiveWorkspaceSessionId();
    final snapshot = sessionId == null ? null : readWorkspaceSession(sessionId);
    final lines = snapshot == null
        ? const ['[no-active-session]']
        : [
            'id=${snapshot.id}',
            'title=${snapshot.title}',
            'provider=${snapshot.provider}',
            'model=${snapshot.model ?? 'default'}',
            'history.messages=${snapshot.history.length}',
            'transcript.messages=${snapshot.transcript.length}',
          ];
    return LocalCommandResult(
      status: 'Displayed session.',
      messages: lines.map(TranscriptMessage.localCommandStdout).toList(),
    );
  }
  if (input == '/clear') {
    session.clearConversation();
    return const LocalCommandResult(
      status: 'Transcript cleared.',
      clearScreen: true,
      clearTranscript: true,
      recordCommandInput: false,
    );
  }
  return null;
}
