import '../core/app_config.dart';
import '../core/models.dart';
import '../core/query_engine.dart';

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

  final response = await context.engine.run(
    QueryRequest(messages: [ChatMessage(role: MessageRole.user, text: input)]),
  );
  print(response.output);
  return response.isOk ? 0 : 1;
}
