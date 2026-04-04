import '../core/app_config.dart';
import '../core/models.dart';
import '../core/process_user_input.dart';
import '../core/query_engine.dart';
import '../core/prompt_submitter.dart';
import '../core/turn_executor.dart';
import 'workspace_store.dart';

typedef CommandHandler = Future<int> Function(CommandContext context);

class CommandContext {
  CommandContext({
    required this.command,
    required this.args,
    required this.config,
    required this.engine,
  });

  final String command;
  final List<String> args;
  final AppConfig config;
  final QueryEngine engine;
}

class RegisteredCommand {
  const RegisteredCommand({
    required this.name,
    required this.description,
    required this.handler,
    this.aliases = const [],
  });

  final String name;
  final String description;
  final List<String> aliases;
  final CommandHandler handler;

  bool matches(String input) => input == name || aliases.contains(input);
}

List<RegisteredCommand> buildCommands({required List<RegisteredCommand> all}) =>
    all;

Future<int> runChatLikeCommand(CommandContext context) async {
  final input = context.args.join(' ').trim();
  if (input.isEmpty) {
    print('error: missing prompt text');
    return 2;
  }

  final submission = PromptSubmitter().submit(
    input,
    model: context.config.model,
  );
  final processed = const UserInputProcessor().process(submission);
  if (!processed.isQuery) {
    print('error: chat only accepts plain prompt text');
    return 2;
  }

  final result = await TurnExecutor(context.engine).execute(
    request: processed.request!,
    turn: 1,
  );
  final sessionId = createWorkspaceSessionId();
  final transcript = [
    ...processed.transcriptMessages,
    ...result.transcriptMessages,
  ];
  final history = result.success || result.interrupted
      ? processed.request!.messages.followedBy([
          if (result.displayOutput.isNotEmpty)
            ChatMessage(
                role: MessageRole.assistant, text: result.displayOutput),
        ]).toList()
      : processed.request!.messages;
  writeWorkspaceSession(
    buildWorkspaceSessionSnapshot(
      id: sessionId,
      provider: context.config.provider.name,
      model: context.config.model,
      history: history,
      transcript: transcript,
    ),
  );
  print(result.output);
  return result.success ? 0 : 1;
}
