import 'clart_code_agent.dart';
import 'sdk_models.dart';
import '../core/models.dart';

Stream<ClartCodeSdkMessage> query({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  QueryCancellationSignal? cancellationSignal,
}) async* {
  final agent = ClartCodeAgent(options);
  try {
    yield* agent.query(
      prompt,
      model: model,
      cancellationSignal: cancellationSignal,
    );
  } finally {
    await agent.close();
  }
}

Future<ClartCodePromptResult> prompt({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  QueryCancellationSignal? cancellationSignal,
}) async {
  final agent = ClartCodeAgent(options);
  try {
    return await agent.prompt(
      prompt,
      model: model,
      cancellationSignal: cancellationSignal,
    );
  } finally {
    await agent.close();
  }
}
